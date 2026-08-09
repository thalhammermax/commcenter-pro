-- CommCenter Pro v0.8.2
-- Atomic incident creation with optional event POI creation.
--
-- Dispatcher "on the fly" POIs now originate inside the New Incident workflow.
-- If the dispatcher selected a raw map point and chooses "Add This Location as
-- a POI", the POI and incident are created in the same PostgreSQL transaction.
--
-- If incident creation fails, the new POI is rolled back too.

create or replace function public.create_incident_v4(
  p_event_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_create_poi boolean default false,
  p_poi_category text default null,
  p_poi_aliases text[] default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_id_value uuid:=p_poi_id;
  incident_id_value uuid;
begin
  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatch access required';
  end if;

  -- A raw map point can be promoted to an event-only POI as part of the same
  -- action that creates the call. Existing POI selections are never duplicated.
  if coalesce(p_create_poi,false) and poi_id_value is null then
    if nullif(trim(coalesce(p_landmark,'')),'') is null then
      raise exception 'Location Description is required when adding the call location as a POI';
    end if;

    poi_id_value:=public.dispatcher_create_poi_v2(
      p_event_id,
      trim(p_landmark),
      coalesce(nullif(trim(coalesce(p_poi_category,'')),''),'Other'),
      p_map_layer_id,
      p_zone_id,
      p_latitude,
      p_longitude,
      p_map_x,
      p_map_y,
      null,
      coalesce(p_poi_aliases,array[]::text[])
    );
  end if;

  incident_id_value:=public.create_incident_v3(
    p_event_id,
    p_department_ids,
    p_call_type,
    p_priority,
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    p_landmark,
    p_notes,
    poi_id_value,
    p_map_layer_id,
    p_zone_id
  );

  return incident_id_value;
end;
$$;

revoke all on function public.create_incident_v4(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[]
) from public;

grant execute on function public.create_incident_v4(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[]
) to authenticated;
