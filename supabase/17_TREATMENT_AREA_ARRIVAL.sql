-- CommCenter Pro v0.7.5
-- Arrive transporting units at their selected treatment-area destination.
--
-- This is another entry point into the same incident-level EMS patient flow:
--
-- TRANSPORTING unit
--   -> Arrived at Treatment Area
--   -> treatment area becomes current EMS custody
--   -> transporting unit is cleared from the CAD incident
--   -> transporting unit becomes AVAILABLE
--   -> treatment-area census updates through the existing EMS encounter flow
--
-- The destination comes from units.current_transport_treatment_area_id so the
-- arrival action cannot accidentally hand the patient to a different area.

create or replace function public.unit_arrive_treatment_area(
  p_unit_id uuid,
  p_incident_id uuid
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  unit_status_value text;
  treatment_area_id_value uuid;
  treatment_area_name_value text;
  encounter_id_value uuid;
  actor_kind_value text;
  still_assigned boolean;
  old_status_value text;
begin
  select
    u.event_id,
    u.status,
    u.current_transport_treatment_area_id
  into
    eid,
    unit_status_value,
    treatment_area_id_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this unit';
  end if;

  if unit_status_value<>'TRANSPORTING' then
    raise exception 'Unit must be TRANSPORTING before it can arrive at a treatment area';
  end if;

  if treatment_area_id_value is null then
    raise exception 'This unit does not have a treatment-area transport destination';
  end if;

  if not exists(
    select 1
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.incident_id=p_incident_id
      and iu.unit_id=p_unit_id
      and iu.cleared_at is null
      and i.event_id=eid
      and i.status='OPEN'
  ) then
    raise exception 'Unit is not actively committed to that incident';
  end if;

  select a.name
  into treatment_area_name_value
  from public.ems_treatment_areas a
  where a.id=treatment_area_id_value
    and a.event_id=eid
    and a.active=true;

  if treatment_area_name_value is null then
    raise exception 'Treatment-area destination is no longer active';
  end if;

  -- If the incident has no EMS custody row yet, establish this transporting
  -- unit as the current patient custodian first. ems_create_encounter() returns
  -- the existing open encounter when one already exists.
  select public.ems_create_encounter(
    eid,
    p_incident_id,
    p_unit_id,
    null,
    null
  )
  into encounter_id_value;

  -- Use the same direct-custody transfer primitive as the incident-level
  -- Handoff / Custody workflow. This updates EMS custody, the transfer ledger,
  -- treatment-area census, CAD assignment, and unit status atomically.
  perform private.ems_direct_transfer(
    encounter_id_value,
    null,
    treatment_area_id_value,
    'Arrived at treatment area',
    actor_kind_value
  );

  -- In the normal path, ems_direct_transfer clears p_unit_id because it was the
  -- current EMS custodian. If an older/reconciled encounter had a different
  -- current custodian, make sure the transporting unit is still cleared too.
  select exists(
    select 1
    from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null
  )
  into still_assigned;

  if still_assigned then
    select status
    into old_status_value
    from public.units
    where id=p_unit_id;

    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=p_unit_id;

    if old_status_value is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,p_unit_id,
        old_status_value,'AVAILABLE',
        auth.uid(),actor_kind_value,
        null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,
      'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','ARRIVED_TREATMENT_AREA',
        'treatment_area_id',treatment_area_id_value,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );
  end if;

  -- The helper normally clears these fields along with the unit assignment;
  -- explicitly clear them here as a final state guarantee.
  update public.units
  set
    status='AVAILABLE',
    current_transport_destination_text=null,
    current_transport_treatment_area_id=null
  where id=p_unit_id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    'UNIT_ARRIVED_TREATMENT_AREA',
    jsonb_build_object(
      'treatment_area_id',treatment_area_id_value,
      'treatment_area_name',treatment_area_name_value,
      'encounter_id',encounter_id_value,
      'patient_custody_transferred',true
    ),
    auth.uid(),actor_kind_value
  );

  return treatment_area_name_value;
end;
$$;

revoke all on function public.unit_arrive_treatment_area(uuid,uuid) from public;
grant execute on function public.unit_arrive_treatment_area(uuid,uuid) to authenticated;
