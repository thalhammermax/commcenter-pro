-- CommCenter Pro v0.13.6
-- Treatment Area patient release closes the associated CAD incident.
--
-- Problem:
-- The Treatment Area UI's "Release / Close Patient" button called
-- ems_release_encounter(). That closed EMS custody and removed the patient from
-- Treatment Area census, but intentionally left the CAD incident OPEN. The call
-- therefore remained on Dispatch / Command after the patient had completed care.
--
-- Fix:
-- When the CURRENT Treatment Area Station is the actor releasing the patient,
-- ems_release_encounter() now also closes the associated open CAD incident and
-- releases any remaining unit assignments atomically. Field-unit and Dispatch
-- uses of ems_release_encounter() retain their previous behavior.

create or replace function public.ems_release_encounter(
  p_encounter_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  i public.incidents;
  unit_rec record;
  disposition_code text;
  general_code text;
  actor_kind_value text;
  released_count integer:=0;
  other_open_ems boolean:=false;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED'
  for update;

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if public.can_dispatch_event(e.event_id) then
    actor_kind_value:='staff';
  elsif e.current_unit_id is not null
        and e.current_unit_id=private.current_field_unit() then
    actor_kind_value:='field';
  elsif e.current_treatment_area_id is not null
        and e.current_treatment_area_id=private.current_treatment_area() then
    actor_kind_value:='treatment';
  else
    raise exception 'Only the current holder can close this encounter';
  end if;

  disposition_code:=upper(trim(coalesce(p_disposition,'')));

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=e.event_id
      and d.scope='EMS'
      and d.code=disposition_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  -- Cancel any stale/pending handoff before final patient disposition.
  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now())
  where encounter_id=e.id
    and status='PENDING';

  -- Close the patient-flow record and remove it from live custody/census.
  update public.ems_encounters
  set
    current_status='CLOSED',
    current_unit_id=null,
    current_treatment_area_id=null,
    final_disposition=disposition_code,
    transport_completed_at=case
      when disposition_code='TRANSPORTED'
        and transport_started_at is not null
        then coalesce(transport_completed_at,now())
      else transport_completed_at
    end,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,
    e.incident_id,
    e.current_unit_id,
    'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object(
      'encounter_id',e.id,
      'ems_disposition',disposition_code,
      'released_from_unit_id',e.current_unit_id,
      'released_from_treatment_area_id',e.current_treatment_area_id
    ),
    auth.uid(),
    actor_kind_value
  );

  -- A field-side EMS release remains an EMS-only workflow; Dispatch can still
  -- decide how/when to close the CAD call. The Treatment Area button, however,
  -- is explicitly "Release / Close Patient", and completion of care there is
  -- the terminal event for the one-patient-per-incident treatment workflow.
  if actor_kind_value<>'treatment' or e.incident_id is null then
    return;
  end if;

  select *
  into i
  from public.incidents
  where id=e.incident_id
    and event_id=e.event_id
  for update;

  -- If Dispatch already closed the incident there is nothing further to do.
  if i.id is null or i.status='CLOSED' then
    return;
  end if;

  -- CommCenter's normal EMS model is one patient per CAD incident. Do not
  -- silently close a call if legacy/corrupt data contains a second active EMS
  -- encounter attached to the same incident.
  select exists(
    select 1
    from public.ems_encounters x
    where x.event_id=e.event_id
      and x.incident_id=e.incident_id
      and x.id<>e.id
      and x.current_status<>'CLOSED'
  ) into other_open_ems;

  if other_open_ems then
    insert into public.cad_activity(
      event_id,incident_id,action,detail,actor_user_id,actor_kind
    ) values(
      e.event_id,e.incident_id,'EMS_TREATMENT_RELEASE_CALL_LEFT_OPEN',
      jsonb_build_object(
        'encounter_id',e.id,
        'reason','ANOTHER_ACTIVE_EMS_ENCOUNTER_EXISTS'
      ),
      auth.uid(),'treatment'
    );
    return;
  end if;

  -- Prefer the standard Completed / Resolved general disposition. If an event
  -- admin disabled it, use the first remaining active GENERAL disposition so
  -- the incident can still close cleanly.
  select d.code
  into general_code
  from public.event_dispositions d
  where d.event_id=e.event_id
    and d.scope='GENERAL'
    and d.active=true
  order by
    case when d.code='COMPLETED' then 0 else 1 end,
    d.sort_order,
    d.code
  limit 1;

  general_code:=coalesce(general_code,'COMPLETED');

  -- Release any unit that somehow remains committed to the call. Normally the
  -- transporting field unit was already cleared at Treatment Area handoff, but
  -- this keeps the terminal close path safe for multi-unit incidents.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=i.id
      and iu.cleared_at is null
    for update of iu,u
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=i.id
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
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'treatment',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','PATIENT_RELEASED_FROM_TREATMENT',
        'automatic',true
      ),
      auth.uid(),'treatment'
    );

    released_count:=released_count+1;
  end loop;

  update public.incidents
  set
    status='CLOSED',
    closed_at=coalesce(closed_at,now()),
    disposition=general_code
  where id=i.id
    and status<>'CLOSED';

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_code,
      'general_disposition',general_code,
      'ems_disposition',disposition_code,
      'released_units',released_count,
      'reason','PATIENT_RELEASED_FROM_TREATMENT',
      'source','TREATMENT_AREA_RELEASE'
    ),
    auth.uid(),'treatment'
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;
