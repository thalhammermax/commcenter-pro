-- CommCenter Pro v0.8.3
-- Dispatcher + Treatment Area walk-in patient creation.
--
-- A walk-in is a normal CAD incident whose patient is already physically
-- present at a treatment area. The incident number remains the patient
-- reference and an EMS encounter is created immediately with IN_TREATMENT
-- custody at the selected area.

create or replace function public.create_treatment_walkin_incident_v2(
  p_treatment_area_id uuid,
  p_call_type text default 'Walk-In Medical',
  p_priority text default 'Standard',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  ta public.ems_treatment_areas;
  poi public.event_pois;
  incident_id_value uuid;
  encounter_id_value uuid;
  n integer;
  prefix text;
  incident_number_value text;
  actor_kind_value text;
begin
  select *
  into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and active=true;

  if ta.id is null then
    raise exception 'Treatment area not found';
  end if;

  if ta.status='CLOSED' then
    raise exception 'Treatment area is closed';
  end if;

  if public.can_dispatch_event(ta.event_id) then
    actor_kind_value:='staff';
  elsif private.current_treatment_area()=ta.id then
    actor_kind_value:='treatment';
  else
    raise exception 'Not authorized for this treatment area';
  end if;

  if ta.department_id is null then
    raise exception 'Treatment area must have a department configured';
  end if;

  if ta.poi_id is null then
    raise exception 'Treatment area must be linked to a POI before creating walk-in patients';
  end if;

  select *
  into poi
  from public.event_pois
  where id=ta.poi_id
    and event_id=ta.event_id
    and active=true;

  if poi.id is null then
    raise exception 'The treatment-area POI could not be found';
  end if;

  update public.events
  set next_incident_number=next_incident_number+1
  where id=ta.event_id
  returning next_incident_number-1,incident_prefix
  into n,prefix;

  incident_number_value:=prefix||'-'||lpad(n::text,3,'0');

  insert into public.incidents(
    event_id,
    incident_number,
    call_type,
    priority,
    status,
    poi_id,
    latitude,
    longitude,
    map_x,
    map_y,
    w3w,
    landmark,
    notes,
    created_by,
    map_layer_id,
    zone_id
  ) values(
    ta.event_id,
    incident_number_value,
    coalesce(nullif(trim(p_call_type),''),'Walk-In Medical'),
    coalesce(nullif(trim(p_priority),''),'Standard'),
    'OPEN',
    poi.id,
    poi.latitude,
    poi.longitude,
    poi.map_x,
    poi.map_y,
    null,
    ta.name,
    nullif(trim(p_notes),''),
    auth.uid(),
    poi.map_layer_id,
    poi.zone_id
  )
  returning id into incident_id_value;

  insert into public.incident_departments(incident_id,department_id)
  values(incident_id_value,ta.department_id)
  on conflict do nothing;

  encounter_id_value:=public.ems_create_encounter(
    ta.event_id,
    incident_id_value,
    null,
    ta.id,
    p_notes
  );

  insert into public.cad_activity(
    event_id,
    incident_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    ta.event_id,
    incident_id_value,
    'TREATMENT_WALKIN_INCIDENT_CREATED',
    jsonb_build_object(
      'incident_number',incident_number_value,
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'encounter_id',encounter_id_value,
      'source',case when actor_kind_value='staff' then 'dispatch' else 'treatment_area_station' end
    ),
    auth.uid(),
    actor_kind_value
  );

  return incident_id_value;
end;
$$;

revoke all on function public.create_treatment_walkin_incident_v2(uuid,text,text,text) from public;
grant execute on function public.create_treatment_walkin_incident_v2(uuid,text,text,text) to authenticated;

-- Preserve the existing Treatment Area Station RPC name and return type.
create or replace function public.treatment_create_walkin_incident(
  p_treatment_area_id uuid,
  p_call_type text default 'Walk-In Medical',
  p_priority text default 'Standard',
  p_notes text default null
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  incident_id_value uuid;
  incident_number_value text;
begin
  incident_id_value:=public.create_treatment_walkin_incident_v2(
    p_treatment_area_id,
    p_call_type,
    p_priority,
    p_notes
  );

  select incident_number
  into incident_number_value
  from public.incidents
  where id=incident_id_value;

  return incident_number_value;
end;
$$;

revoke all on function public.treatment_create_walkin_incident(uuid,text,text,text) from public;
grant execute on function public.treatment_create_walkin_incident(uuid,text,text,text) to authenticated;
