-- CommCenter Pro v0.8.1
-- Ambulance transport outcome now closes the CAD incident.
--
-- When a transport ambulance changes from TRANSPORTING to AVAILABLE and the
-- user confirms DELIVERED or REFUSAL, CommCenter Pro now:
--   1. closes the EMS encounter with TRANSPORTED or REFUSAL disposition
--   2. releases EVERY unit still committed to the CAD incident
--   3. returns every released unit to AVAILABLE
--   4. clears live transport destinations
--   5. closes the CAD incident
--   6. records the incident disposition and audit trail
--
-- This is allowed from either Dispatch or the current field ambulance.

create or replace function public.ems_finish_ambulance_transport(
  p_unit_id uuid,
  p_incident_id uuid,
  p_outcome text
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  i public.incidents;
  eid uuid;
  unit_status_value text;
  destination_value text;
  outcome_value text;
  disposition_value text;
  actor_kind_value text;
  unit_rec record;
  released_count integer:=0;
begin
  outcome_value:=upper(trim(coalesce(p_outcome,'')));

  if outcome_value not in ('DELIVERED','REFUSAL') then
    raise exception 'Transport outcome must be DELIVERED or REFUSAL';
  end if;

  select u.event_id,u.status,u.current_transport_destination_text
  into eid,unit_status_value,destination_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active ambulance not found';
  end if;

  if not exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'Unit is not configured as a transport ambulance';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this ambulance';
  end if;

  select *
  into i
  from public.incidents
  where id=p_incident_id
    and event_id=eid
    and status='OPEN';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select *
  into e
  from public.ems_encounters x
  where x.event_id=eid
    and x.incident_id=p_incident_id
    and x.current_unit_id=p_unit_id
    and x.current_status='TRANSPORTING'
  order by x.created_at desc
  limit 1;

  if e.id is null then
    raise exception 'No active ambulance transport was found for this incident';
  end if;

  destination_value:=coalesce(
    nullif(trim(e.transport_destination),''),
    nullif(trim(destination_value),'')
  );

  if outcome_value='DELIVERED' and destination_value is null then
    raise exception 'Destination facility is required before recording hospital delivery';
  end if;

  disposition_value:=case
    when outcome_value='DELIVERED' then 'TRANSPORTED'
    else 'REFUSAL'
  end;

  -- Close the EMS patient-flow encounter first.
  update public.ems_encounters
  set
    current_status='CLOSED',
    transport_destination=destination_value,
    transport_completed_at=case
      when outcome_value='DELIVERED' then now()
      else transport_completed_at
    end,
    final_disposition=disposition_value,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    case
      when outcome_value='DELIVERED' then 'EMS_TRANSPORT_COMPLETED'
      else 'EMS_TRANSPORT_REFUSAL'
    end,
    jsonb_build_object(
      'encounter_id',e.id,
      'outcome',outcome_value,
      'disposition',disposition_value,
      'destination',destination_value,
      'incident_will_close',true
    ),
    auth.uid(),actor_kind_value
  );

  -- Closing the call after a completed/refused ambulance transport must release
  -- every resource still committed to the incident, not just the ambulance.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=p_incident_id
      and iu.cleared_at is null
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=unit_rec.unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=unit_rec.unit_id;

    if unit_rec.status is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),actor_kind_value,
        case when unit_rec.unit_id=p_unit_id then destination_value else null end,
        null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason',case
          when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED_CALL_CLOSED'
          else 'TRANSPORT_REFUSAL_CALL_CLOSED'
        end,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );

    released_count:=released_count+1;
  end loop;

  -- Close the CAD incident using the transport outcome as the incident
  -- disposition. This is done inside this security-definer workflow because a
  -- field ambulance may be the actor that finishes the transport.
  update public.incidents
  set
    status='CLOSED',
    closed_at=now(),
    disposition=disposition_value
  where id=p_incident_id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',disposition_value,
      'transport_outcome',outcome_value,
      'destination',destination_value,
      'released_units',released_count,
      'automatic',true,
      'reason','AMBULANCE_TRANSPORT_OUTCOME'
    ),
    auth.uid(),actor_kind_value
  );

  return outcome_value;
end;
$$;

revoke all on function public.ems_finish_ambulance_transport(uuid,uuid,text) from public;
grant execute on function public.ems_finish_ambulance_transport(uuid,uuid,text) to authenticated;
