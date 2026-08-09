-- CommCenter Pro v0.4.3
-- Incident-number EMS flow + treatment-area walk-in incidents
--
-- This does NOT delete existing EMS handoff records.
-- New EMS custody records are keyed operationally to the CAD incident number.

create or replace function public.ems_create_encounter(
  p_event_id uuid,
  p_incident_id uuid default null,
  p_source_unit_id uuid default null,
  p_source_treatment_area_id uuid default null,
  p_operational_note text default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  encounter_id uuid;
  initial_status text;
  incident_number_value text;
begin
  if p_incident_id is null then
    raise exception 'An EMS flow record must be tied to a CAD incident';
  end if;

  if ((p_source_unit_id is not null)::int + (p_source_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Exactly one source resource is required';
  end if;

  select i.incident_number
  into incident_number_value
  from public.incidents i
  where i.id=p_incident_id
    and i.event_id=p_event_id;

  if incident_number_value is null then
    raise exception 'Incident is not part of this event';
  end if;

  -- One operational EMS flow per CAD incident. Existing deployments may
  -- already have a PT-xxxx record; reuse it rather than creating a duplicate.
  select e.id
  into encounter_id
  from public.ems_encounters e
  where e.event_id=p_event_id
    and e.incident_id=p_incident_id
    and e.current_status<>'CLOSED'
  order by e.created_at
  limit 1;

  if encounter_id is not null then
    return encounter_id;
  end if;

  if p_source_unit_id is not null then
    if not exists(
      select 1 from public.units u
      where u.id=p_source_unit_id and u.event_id=p_event_id
    ) then
      raise exception 'Unit is not part of this event';
    end if;

    if not (
      public.can_dispatch_event(p_event_id)
      or public.field_has_unit_access(p_source_unit_id)
    ) then
      raise exception 'Not authorized for this unit';
    end if;

    initial_status:='FIELD';
  else
    if not exists(
      select 1 from public.ems_treatment_areas ta
      where ta.id=p_source_treatment_area_id
        and ta.event_id=p_event_id
        and ta.active=true
    ) then
      raise exception 'Treatment area is not part of this event';
    end if;

    if not (
      public.can_dispatch_event(p_event_id)
      or private.current_treatment_area()=p_source_treatment_area_id
    ) then
      raise exception 'Not authorized for this treatment area';
    end if;

    initial_status:='IN_TREATMENT';
  end if;

  insert into public.ems_encounters(
    event_id,
    incident_id,
    tracking_number,
    current_status,
    current_unit_id,
    current_treatment_area_id,
    origin_unit_id,
    operational_note,
    created_by
  ) values(
    p_event_id,
    p_incident_id,
    incident_number_value,
    initial_status,
    p_source_unit_id,
    p_source_treatment_area_id,
    p_source_unit_id,
    nullif(trim(p_operational_note),''),
    auth.uid()
  )
  returning id into encounter_id;

  insert into public.cad_activity(
    event_id,
    incident_id,
    unit_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    p_event_id,
    p_incident_id,
    p_source_unit_id,
    'EMS_FLOW_STARTED',
    jsonb_build_object(
      'encounter_id',encounter_id,
      'incident_number',incident_number_value,
      'treatment_area_id',p_source_treatment_area_id
    ),
    auth.uid(),
    case when public.can_dispatch_event(p_event_id) then 'staff' else 'field' end
  );

  return encounter_id;
end;
$$;


create or replace function public.treatment_create_walkin_incident(
  p_treatment_area_id uuid,
  p_call_type text default 'Walk-In Medical',
  p_priority text default 'Standard',
  p_notes text default null
) returns text
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
begin
  select *
  into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and active=true;

  if ta.id is null then
    raise exception 'Treatment area not found';
  end if;

  if not (
    public.can_dispatch_event(ta.event_id)
    or private.current_treatment_area()=ta.id
  ) then
    raise exception 'Not authorized for this treatment area';
  end if;

  if ta.department_id is null then
    raise exception 'Treatment area must have an EMS department configured';
  end if;

  if ta.poi_id is null then
    raise exception 'Treatment area must be linked to a POI before creating walk-in incidents';
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
  returning next_incident_number-1,incident_prefix into n,prefix;

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
    created_by
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
    poi.w3w,
    ta.name,
    nullif(trim(p_notes),''),
    auth.uid()
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
      'encounter_id',encounter_id_value
    ),
    auth.uid(),
    case when public.can_dispatch_event(ta.event_id) then 'staff' else 'field' end
  );

  return incident_number_value;
end;
$$;

grant execute on function public.ems_create_encounter(uuid,uuid,uuid,uuid,text) to authenticated;
grant execute on function public.treatment_create_walkin_incident(uuid,text,text,text) to authenticated;
