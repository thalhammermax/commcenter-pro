-- CommCenter Pro v0.9.5
-- Dispatch close must terminate EMS treatment-center custody as part of the
-- same database transaction.
--
-- When Dispatch closes a CAD incident, any patient still assigned to a
-- Treatment Area is removed from that treatment area's active census,
-- the EMS encounter is closed with the selected EMS disposition, pending
-- handoffs are cancelled, and the action is written to CAD activity.

-- ============================================================
-- STRUCTURED INCIDENT CLOSE + TREATMENT-CENTER RELEASE
-- ============================================================

create or replace function public.close_incident_v2(
  p_incident_id uuid,
  p_disposition text,
  p_ems_disposition text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  unit_rec record;
  encounter_rec record;
  released_count integer:=0;
  treatment_released_count integer:=0;
  ems_context boolean:=false;
  general_code text;
  ems_code text;
  treatment_name text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id
    and status='OPEN'
  for update;

  if i.id is null then
    raise exception 'Open incident not found';
  end if;

  if not public.can_dispatch_event(i.event_id) then
    raise exception 'Dispatch access required';
  end if;

  general_code:=upper(trim(coalesce(p_disposition,'')));
  ems_code:=nullif(upper(trim(coalesce(p_ems_disposition,''))),'');

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=i.event_id
      and d.scope='GENERAL'
      and d.code=general_code
      and d.active=true
  ) then
    raise exception 'Choose a valid general disposition';
  end if;

  select (
    exists(
      select 1
      from public.incident_departments idept
      join public.event_departments dept on dept.id=idept.department_id
      where idept.incident_id=i.id
        and dept.active=true
        and dept.ems_enabled=true
    )
    or exists(
      select 1
      from public.ems_encounters e
      where e.incident_id=i.id
        and e.event_id=i.event_id
    )
  )
  into ems_context;

  if ems_context and ems_code is null then
    raise exception 'Choose an EMS patient disposition';
  end if;

  if ems_code is not null and not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=i.event_id
      and d.scope='EMS'
      and d.code=ems_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  -- Do not allow generic Dispatch close to bypass the event-ambulance
  -- Delivered / Refusal workflow.
  if exists(
    select 1
    from public.ems_encounters e
    join public.ems_unit_config c on c.unit_id=e.current_unit_id
    where e.incident_id=i.id
      and e.event_id=i.event_id
      and e.current_status='TRANSPORTING'
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'An event ambulance is actively transporting this patient. Complete the Delivered / Refusal transport outcome before closing the call.';
  end if;

  -- Log every patient that Dispatch is removing from an active Treatment Area
  -- before custody fields are cleared. This gives the detailed dispatch log an
  -- explicit treatment-center release record.
  for encounter_rec in
    select
      e.id,
      e.current_treatment_area_id,
      e.current_status,
      ta.name as treatment_area_name
    from public.ems_encounters e
    left join public.ems_treatment_areas ta
      on ta.id=e.current_treatment_area_id
    where e.incident_id=i.id
      and e.event_id=i.event_id
      and e.current_treatment_area_id is not null
      and e.current_status<>'CLOSED'
    for update of e
  loop
    treatment_name:=coalesce(encounter_rec.treatment_area_name,'Treatment Area');

    insert into public.cad_activity(
      event_id,
      incident_id,
      action,
      detail,
      actor_user_id,
      actor_kind
    ) values(
      i.event_id,
      i.id,
      'EMS_TREATMENT_CLEARED_BY_DISPATCH',
      jsonb_build_object(
        'encounter_id',encounter_rec.id,
        'treatment_area_id',encounter_rec.current_treatment_area_id,
        'treatment_area_name',treatment_name,
        'previous_ems_status',encounter_rec.current_status,
        'ems_disposition',ems_code,
        'reason','INCIDENT_CLOSED_BY_DISPATCH'
      ),
      auth.uid(),
      'staff'
    );

    treatment_released_count:=treatment_released_count+1;
  end loop;

  -- Any outstanding EMS handoff request for this patient is no longer valid
  -- once Dispatch closes the incident.
  update public.ems_handoffs h
  set
    status='CANCELLED',
    responded_at=coalesce(h.responded_at,now())
  where h.event_id=i.event_id
    and h.status='PENDING'
    and exists(
      select 1
      from public.ems_encounters e
      where e.id=h.encounter_id
        and e.incident_id=i.id
    );

  -- Apply the final EMS disposition to every EMS encounter attached to the
  -- incident and explicitly clear current custody. Clearing
  -- current_treatment_area_id is what removes the patient from treatment-area
  -- census/state, while current_status='CLOSED' makes the release unambiguous.
  if ems_code is not null then
    update public.ems_encounters
    set
      current_status='CLOSED',
      current_unit_id=null,
      current_treatment_area_id=null,
      final_disposition=ems_code,
      transport_completed_at=case
        when ems_code='TRANSPORTED'
          and transport_started_at is not null
          then coalesce(transport_completed_at,now())
        else transport_completed_at
      end,
      closed_at=coalesce(closed_at,now())
    where incident_id=i.id
      and event_id=i.event_id;
  end if;

  -- Release every operational unit still committed to the incident.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=i.id
      and iu.cleared_at is null
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
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','INCIDENT_CLOSED',
        'automatic',true
      ),
      auth.uid(),'staff'
    );

    released_count:=released_count+1;
  end loop;

  update public.incidents
  set
    status='CLOSED',
    closed_at=now(),
    disposition=general_code
  where id=i.id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_code,
      'general_disposition',general_code,
      'ems_disposition',ems_code,
      'released_units',released_count,
      'treatment_patients_released',treatment_released_count
    ),
    auth.uid(),'staff'
  );
end;
$$;

revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;

-- ============================================================
-- LEGACY CLOSE SAFETY
-- ============================================================
-- Older cached clients may still call close_incident(). Never let that legacy
-- path orphan a patient in EMS / Treatment. EMS calls are rejected and must be
-- closed with the current structured close workflow.

create or replace function public.close_incident(
  p_incident_id uuid,
  p_disposition text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  mapped_general_code text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id;

  if i.id is null then
    raise exception 'Incident not found';
  end if;

  if not public.can_dispatch_event(i.event_id) then
    raise exception 'Dispatch access required';
  end if;

  if exists(
    select 1
    from public.ems_encounters e
    where e.event_id=i.event_id
      and e.incident_id=i.id
  ) then
    raise exception 'This incident has EMS patient flow. Refresh CommCenter and use the current Close Incident workflow so treatment custody and EMS disposition are cleared safely.';
  end if;

  mapped_general_code:=case
    when upper(trim(coalesce(p_disposition,''))) in ('','COMPLETE','COMPLETED','RESOLVED')
      then 'COMPLETED'
    when upper(trim(coalesce(p_disposition,''))) in ('CANCELLED','CANCELED')
      then 'CANCELLED'
    when upper(trim(coalesce(p_disposition,'')))='NO ACTION REQUIRED'
      then 'NO_ACTION_REQUIRED'
    when upper(trim(coalesce(p_disposition,'')))='UNFOUNDED'
      then 'UNFOUNDED'
    else 'OTHER'
  end;

  perform public.close_incident_v2(
    p_incident_id,
    mapped_general_code,
    null
  );
end;
$$;

revoke all on function public.close_incident(uuid,text) from public;
grant execute on function public.close_incident(uuid,text) to authenticated;

-- ============================================================
-- CONSISTENT EMS ENCOUNTER RELEASE
-- ============================================================
-- Normal Field / Treatment closure now also clears current custody fields.
-- Historical custody remains available in EMS handoffs and CAD activity.

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
  disposition_code text;
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

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
    or e.current_treatment_area_id=private.current_treatment_area()
  ) then
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

  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now())
  where encounter_id=e.id
    and status='PENDING';

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
    case
      when public.can_dispatch_event(e.event_id) then 'staff'
      when e.current_treatment_area_id=private.current_treatment_area() then 'treatment'
      else 'field'
    end
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;
