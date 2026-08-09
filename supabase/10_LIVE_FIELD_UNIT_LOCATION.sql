-- CommCenter Pro v0.5.1
-- Live field unit location sharing.
--
-- Design:
-- * Browser/device permission is still required by the Geolocation API.
-- * Only the CURRENT unit location is stored. CommCenter Pro does not create
--   a breadcrumb/route history in this release.
-- * Field devices can publish only for the unit they currently hold.
-- * Event staff can read live locations for their event.
-- * Stopping sharing removes the current location row.
-- * Multi-level venues use units.current_map_layer_id to provide vertical context.

alter table public.events
  add column if not exists field_location_enabled boolean not null default false;

create table if not exists public.unit_locations (
  unit_id uuid primary key references public.units(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  field_session_id uuid references public.field_sessions(id) on delete set null,
  latitude double precision not null check(latitude between -90 and 90),
  longitude double precision not null check(longitude between -180 and 180),
  accuracy_m double precision,
  altitude_m double precision,
  heading_deg double precision,
  speed_mps double precision,
  client_time timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists unit_locations_event_updated_idx
  on public.unit_locations(event_id,updated_at desc);

alter table public.unit_locations enable row level security;

drop policy if exists "unit locations read" on public.unit_locations;

create policy "unit locations read"
on public.unit_locations
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_unit_access(unit_id)
);

grant select on public.unit_locations to authenticated;

create or replace function public.set_event_field_location_enabled(
  p_event_id uuid,
  p_enabled boolean
) returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  update public.events
  set field_location_enabled=coalesce(p_enabled,false)
  where id=p_event_id;

  if not coalesce(p_enabled,false) then
    delete from public.unit_locations
    where event_id=p_event_id;
  end if;
end;
$$;

create or replace function public.field_update_unit_location(
  p_unit_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision default null,
  p_altitude_m double precision default null,
  p_heading_deg double precision default null,
  p_speed_mps double precision default null,
  p_client_time timestamptz default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions;
  eid uuid;
begin
  if p_latitude not between -90 and 90
     or p_longitude not between -180 and 180 then
    raise exception 'Invalid geographic coordinates';
  end if;

  select *
  into fs
  from public.field_sessions
  where auth_user_id=auth.uid()
    and unit_id=p_unit_id
    and active=true
  order by started_at desc
  limit 1;

  if fs.id is null then
    raise exception 'No active field session for this unit';
  end if;

  eid:=fs.event_id;

  if not exists(
    select 1 from public.events
    where id=eid
      and field_location_enabled=true
      and active=true
  ) then
    raise exception 'Field location sharing is disabled for this event';
  end if;

  insert into public.unit_locations(
    unit_id,event_id,field_session_id,
    latitude,longitude,accuracy_m,altitude_m,heading_deg,speed_mps,
    client_time,updated_at
  ) values(
    p_unit_id,eid,fs.id,
    p_latitude,p_longitude,
    case when p_accuracy_m is null then null else greatest(p_accuracy_m,0) end,
    p_altitude_m,
    case
      when p_heading_deg is null or p_heading_deg<0 then null
      else mod(p_heading_deg::numeric,360)::double precision
    end,
    case when p_speed_mps is null or p_speed_mps<0 then null else p_speed_mps end,
    coalesce(p_client_time,now()),
    now()
  )
  on conflict(unit_id)
  do update set
    event_id=excluded.event_id,
    field_session_id=excluded.field_session_id,
    latitude=excluded.latitude,
    longitude=excluded.longitude,
    accuracy_m=excluded.accuracy_m,
    altitude_m=excluded.altitude_m,
    heading_deg=excluded.heading_deg,
    speed_mps=excluded.speed_mps,
    client_time=excluded.client_time,
    updated_at=now();

  update public.field_sessions
  set last_seen_at=now()
  where id=fs.id;
end;
$$;

create or replace function public.field_stop_unit_location(
  p_unit_id uuid
) returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.field_has_unit_access(p_unit_id) then
    raise exception 'Not authorized for this unit';
  end if;

  delete from public.unit_locations
  where unit_id=p_unit_id;
end;
$$;

create or replace function public.field_set_unit_venue_location(
  p_unit_id uuid,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
begin
  if not public.field_has_unit_access(p_unit_id) then
    raise exception 'Not authorized for this unit';
  end if;

  select event_id into eid
  from public.units
  where id=p_unit_id and active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if p_map_layer_id is not null and not exists(
    select 1
    from public.event_map_layers
    where id=p_map_layer_id
      and event_id=eid
      and active=true
      and status='published'
  ) then
    raise exception 'Map layer is not valid for this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones
    where id=p_zone_id
      and event_id=eid
      and active=true
      and (p_map_layer_id is null or map_layer_id=p_map_layer_id)
  ) then
    raise exception 'Zone is not valid for this map layer';
  end if;

  update public.units
  set current_map_layer_id=p_map_layer_id,
      current_zone_id=p_zone_id,
      current_poi_id=null
  where id=p_unit_id;
end;
$$;

-- Remove a unit's current GPS position when the field device intentionally
-- releases the unit or ends the field session.
create or replace function public.field_release_unit(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set unit_id=null,last_seen_at=now()
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

create or replace function public.field_end_session(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

grant execute on function public.set_event_field_location_enabled(uuid,boolean) to authenticated;
grant execute on function public.field_update_unit_location(uuid,double precision,double precision,double precision,double precision,double precision,double precision,timestamptz) to authenticated;
grant execute on function public.field_stop_unit_location(uuid) to authenticated;
grant execute on function public.field_set_unit_venue_location(uuid,uuid,uuid) to authenticated;

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='unit_locations'
  ) then
    alter publication supabase_realtime add table public.unit_locations;
  end if;
end $$;
