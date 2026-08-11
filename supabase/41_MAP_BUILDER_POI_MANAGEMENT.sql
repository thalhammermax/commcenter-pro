-- CommCenter Pro v0.14.3
-- Map Builder POI editing, movement, and safe deletion/archive.

create or replace function public.admin_update_event_poi(
  p_poi_id uuid,
  p_name text,
  p_category text,
  p_zone_id uuid default null,
  p_notes text default null,
  p_aliases text[] default array[]::text[]
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_row public.event_pois%rowtype;
  alias_value text;
begin
  select * into poi_row
  from public.event_pois
  where id=p_poi_id
  for update;

  if not found then
    raise exception 'POI not found';
  end if;

  if not public.can_admin_event(poi_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  if nullif(trim(coalesce(p_name,'')),'') is null then
    raise exception 'POI name is required';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones z
    where z.id=p_zone_id
      and z.event_id=poi_row.event_id
      and z.active=true
      and (poi_row.map_layer_id is null or z.map_layer_id=poi_row.map_layer_id)
  ) then
    raise exception 'Zone is not valid for this POI/map layer';
  end if;

  update public.event_pois
  set
    name=trim(p_name),
    category=nullif(trim(coalesce(p_category,'')),''),
    zone_id=p_zone_id,
    notes=nullif(trim(coalesce(p_notes,'')),'')
  where id=p_poi_id;

  delete from public.poi_aliases
  where poi_id=p_poi_id;

  foreach alias_value in array coalesce(p_aliases,array[]::text[]) loop
    alias_value:=trim(alias_value);
    if alias_value<>'' then
      insert into public.poi_aliases(poi_id,alias)
      values(p_poi_id,alias_value)
      on conflict(poi_id,alias) do nothing;
    end if;
  end loop;
end;
$$;

create or replace function public.admin_move_event_poi(
  p_poi_id uuid,
  p_map_layer_id uuid,
  p_zone_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_row public.event_pois%rowtype;
begin
  select * into poi_row
  from public.event_pois
  where id=p_poi_id
  for update;

  if not found then
    raise exception 'POI not found';
  end if;

  if not public.can_admin_event(poi_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  if not exists(
    select 1
    from public.event_map_layers l
    where l.id=p_map_layer_id
      and l.event_id=poi_row.event_id
      and l.active=true
  ) then
    raise exception 'Map layer is not valid for this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones z
    where z.id=p_zone_id
      and z.event_id=poi_row.event_id
      and z.map_layer_id=p_map_layer_id
      and z.active=true
  ) then
    raise exception 'Zone is not valid for the destination map layer';
  end if;

  if p_latitude is null or p_longitude is null or p_map_x is null or p_map_y is null then
    raise exception 'Complete map coordinates are required';
  end if;

  update public.event_pois
  set
    map_layer_id=p_map_layer_id,
    zone_id=p_zone_id,
    latitude=p_latitude,
    longitude=p_longitude,
    map_x=p_map_x,
    map_y=p_map_y
  where id=p_poi_id;
end;
$$;

create or replace function public.admin_archive_event_poi(
  p_poi_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_row public.event_pois%rowtype;
begin
  select * into poi_row
  from public.event_pois
  where id=p_poi_id
  for update;

  if not found then
    raise exception 'POI not found';
  end if;

  if not public.can_admin_event(poi_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  update public.event_pois
  set active=false
  where id=p_poi_id;
end;
$$;

revoke all on function public.admin_update_event_poi(uuid,text,text,uuid,text,text[]) from public;
revoke all on function public.admin_move_event_poi(uuid,uuid,uuid,double precision,double precision,double precision,double precision) from public;
revoke all on function public.admin_archive_event_poi(uuid) from public;

grant execute on function public.admin_update_event_poi(uuid,text,text,uuid,text,text[]) to authenticated;
grant execute on function public.admin_move_event_poi(uuid,uuid,uuid,double precision,double precision,double precision,double precision) to authenticated;
grant execute on function public.admin_archive_event_poi(uuid) to authenticated;
