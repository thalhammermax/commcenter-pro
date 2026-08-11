-- CommCenter Pro v0.14.4
-- Map Builder zone editing and safe deletion/archive.

-- The original table-level UNIQUE constraint also included archived rows.
-- Convert it to an active-only unique index so an archived zone name can be
-- reused later without destroying historical references.
alter table public.event_zones
  drop constraint if exists event_zones_event_id_map_layer_id_name_key;

create unique index if not exists event_zones_active_name_idx
  on public.event_zones(event_id,map_layer_id,name)
  where active=true;

create or replace function public.admin_update_event_zone(
  p_zone_id uuid,
  p_name text,
  p_short_name text default null,
  p_category text default null,
  p_notes text default null,
  p_sort_order integer default 100
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  zone_row public.event_zones%rowtype;
begin
  select * into zone_row
  from public.event_zones
  where id=p_zone_id
  for update;

  if not found then
    raise exception 'Zone not found';
  end if;

  if not public.can_admin_event(zone_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  if zone_row.active=false then
    raise exception 'Archived zones cannot be edited';
  end if;

  if nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'Zone name is required';
  end if;

  update public.event_zones
  set
    name=trim(p_name),
    short_name=nullif(trim(coalesce(p_short_name,'')),''),
    category=nullif(trim(coalesce(p_category,'')),''),
    notes=nullif(trim(coalesce(p_notes,'')),''),
    sort_order=coalesce(p_sort_order,100)
  where id=p_zone_id;
end;
$$;

create or replace function public.admin_archive_event_zone(
  p_zone_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  zone_row public.event_zones%rowtype;
  active_incident_count integer;
begin
  select * into zone_row
  from public.event_zones
  where id=p_zone_id
  for update;

  if not found then
    raise exception 'Zone not found';
  end if;

  if not public.can_admin_event(zone_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  if zone_row.active=false then
    return;
  end if;

  select count(*) into active_incident_count
  from public.incidents i
  where i.event_id=zone_row.event_id
    and i.zone_id=p_zone_id
    and i.status<>'CLOSED';

  if active_incident_count>0 then
    raise exception 'Zone is used by % active incident(s). Close or move those incidents before deleting the zone.',
      active_incident_count;
  end if;

  -- Active resources should not continue pointing at a zone that is no longer
  -- operationally selectable. Historical CLOSED incidents intentionally retain
  -- their zone_id reference.
  update public.event_pois
  set zone_id=null
  where event_id=zone_row.event_id
    and zone_id=p_zone_id
    and active=true;

  update public.units
  set current_zone_id=null
  where event_id=zone_row.event_id
    and current_zone_id=p_zone_id;

  update public.venue_access_point_nodes n
  set zone_id=null
  where zone_id=p_zone_id
    and exists(
      select 1
      from public.venue_access_points ap
      where ap.id=n.access_point_id
        and ap.event_id=zone_row.event_id
    );

  update public.event_zones
  set active=false
  where id=p_zone_id;
end;
$$;

revoke all on function public.admin_update_event_zone(uuid,text,text,text,text,integer) from public;
revoke all on function public.admin_archive_event_zone(uuid) from public;

grant execute on function public.admin_update_event_zone(uuid,text,text,text,text,integer) to authenticated;
grant execute on function public.admin_archive_event_zone(uuid) to authenticated;
