-- CommCenter Pro v0.4.4
-- Editable incident details for Dispatch.
-- Existing incidents are preserved.

create or replace function public.update_incident_v2(
  p_incident_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  d uuid;
  old_row public.incidents;
begin
  select *
  into old_row
  from public.incidents
  where id=p_incident_id;

  if old_row.id is null then
    raise exception 'Incident not found';
  end if;

  eid:=old_row.event_id;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  if old_row.status='CLOSED' then
    raise exception 'Closed incidents cannot be edited from the active CAD';
  end if;

  if trim(coalesce(p_call_type,''))='' then
    raise exception 'Call type is required';
  end if;

  if array_length(p_department_ids,1) is null then
    raise exception 'At least one department is required';
  end if;

  if p_map_layer_id is not null and not exists(
    select 1 from public.event_map_layers
    where id=p_map_layer_id and event_id=eid and active=true
  ) then
    raise exception 'Map layer is not part of this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1 from public.event_zones
    where id=p_zone_id and event_id=eid and active=true
      and (p_map_layer_id is null or map_layer_id=p_map_layer_id)
  ) then
    raise exception 'Zone is not valid for this event/map layer';
  end if;

  if p_poi_id is not null and not exists(
    select 1 from public.event_pois
    where id=p_poi_id and event_id=eid and active=true
  ) then
    raise exception 'POI is not part of this event';
  end if;

  -- Validate every requested department before changing the link table.
  foreach d in array p_department_ids loop
    if not exists(
      select 1 from public.event_departments
      where id=d and event_id=eid and active=true
    ) then
      raise exception 'One or more selected departments are invalid for this event';
    end if;
  end loop;

  update public.incidents
  set
    call_type=trim(p_call_type),
    priority=p_priority,
    poi_id=p_poi_id,
    map_layer_id=p_map_layer_id,
    zone_id=p_zone_id,
    latitude=p_latitude,
    longitude=p_longitude,
    map_x=p_map_x,
    map_y=p_map_y,
    w3w=nullif(trim(p_w3w),''),
    landmark=nullif(trim(p_landmark),''),
    notes=nullif(trim(p_notes),'')
  where id=p_incident_id;

  delete from public.incident_departments
  where incident_id=p_incident_id;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    values(p_incident_id,d)
    on conflict do nothing;
  end loop;

  insert into public.cad_activity(
    event_id,
    incident_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    eid,
    p_incident_id,
    'INCIDENT_UPDATED',
    jsonb_build_object(
      'incident_number',old_row.incident_number,
      'old_call_type',old_row.call_type,
      'new_call_type',trim(p_call_type),
      'old_priority',old_row.priority,
      'new_priority',p_priority,
      'old_landmark',old_row.landmark,
      'new_landmark',nullif(trim(p_landmark),''),
      'old_poi_id',old_row.poi_id,
      'new_poi_id',p_poi_id,
      'old_map_layer_id',old_row.map_layer_id,
      'new_map_layer_id',p_map_layer_id,
      'old_zone_id',old_row.zone_id,
      'new_zone_id',p_zone_id
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

grant execute on function public.update_incident_v2(
  uuid,uuid[],text,text,double precision,double precision,
  double precision,double precision,text,text,text,uuid,uuid,uuid
) to authenticated;
