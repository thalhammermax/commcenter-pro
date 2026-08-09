-- CommCenter Pro v0.6.0
-- Dispatcher quick POIs.
--
-- New incident modal, dispatcher department scope, and Command Center Display
-- are frontend/workstation features and do not require database tables.
--
-- This migration permits a dispatcher to create EVENT-ONLY POIs without
-- granting direct INSERT permission on the map-builder tables.

create or replace function public.dispatcher_create_poi(
  p_event_id uuid,
  p_name text,
  p_category text,
  p_map_layer_id uuid,
  p_zone_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text default null,
  p_notes text default null,
  p_aliases text[] default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_id_value uuid;
  square_id_value bigint;
  alias_value text;
begin
  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatch access required';
  end if;

  if trim(coalesce(p_name,''))='' then
    raise exception 'POI name is required';
  end if;

  if p_latitude is null or p_latitude not between -90 and 90
     or p_longitude is null or p_longitude not between -180 and 180 then
    raise exception 'Valid latitude/longitude are required';
  end if;

  if p_map_x is null or p_map_y is null then
    raise exception 'Map coordinates are required';
  end if;

  if p_map_layer_id is null or not exists(
    select 1
    from public.event_map_layers
    where id=p_map_layer_id
      and event_id=p_event_id
      and active=true
  ) then
    raise exception 'A valid event map layer is required';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones
    where id=p_zone_id
      and event_id=p_event_id
      and map_layer_id=p_map_layer_id
      and active=true
  ) then
    raise exception 'Zone is not valid for the selected map layer';
  end if;

  if nullif(trim(p_w3w),'') is not null then
    select id
    into square_id_value
    from public.event_w3w_squares
    where event_id=p_event_id
      and words=regexp_replace(trim(p_w3w),'^/+', '')
    limit 1;
  end if;

  insert into public.event_pois(
    event_id,
    map_layer_id,
    zone_id,
    name,
    category,
    w3w_square_id,
    w3w,
    latitude,
    longitude,
    map_x,
    map_y,
    notes,
    active,
    poi_scope
  ) values(
    p_event_id,
    p_map_layer_id,
    p_zone_id,
    trim(p_name),
    nullif(trim(p_category),''),
    square_id_value,
    nullif(regexp_replace(trim(coalesce(p_w3w,'')),'^/+', ''),''),
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    nullif(trim(p_notes),''),
    true,
    'event'
  )
  returning id into poi_id_value;

  foreach alias_value in array coalesce(p_aliases,array[]::text[]) loop
    alias_value:=trim(alias_value);
    if alias_value<>'' then
      insert into public.poi_aliases(poi_id,alias)
      values(poi_id_value,alias_value)
      on conflict(poi_id,alias) do nothing;
    end if;
  end loop;

  insert into public.cad_activity(
    event_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    p_event_id,
    'POI_CREATED',
    jsonb_build_object(
      'poi_id',poi_id_value,
      'name',trim(p_name),
      'category',nullif(trim(p_category),''),
      'map_layer_id',p_map_layer_id,
      'zone_id',p_zone_id,
      'w3w',nullif(regexp_replace(trim(coalesce(p_w3w,'')),'^/+', ''),''),
      'source','dispatcher'
    ),
    auth.uid(),
    'staff'
  );

  return poi_id_value;
end;
$$;

revoke all on function public.dispatcher_create_poi(
  uuid,text,text,uuid,uuid,double precision,double precision,
  double precision,double precision,text,text,text[]
) from public;

grant execute on function public.dispatcher_create_poi(
  uuid,text,text,uuid,uuid,double precision,double precision,
  double precision,double precision,text,text,text[]
) to authenticated;

-- Make newly created POIs visible to other live CAD clients without requiring
-- a page refresh. Clients that do not subscribe are unaffected.
do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='event_pois'
  ) then
    alter publication supabase_realtime add table public.event_pois;
  end if;
end $$;
