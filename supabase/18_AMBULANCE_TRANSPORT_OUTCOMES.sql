-- CommCenter Pro v0.7.6
-- Ambulance transport outcome confirmation.
--
-- When an ambulance has an active EMS transport and is returned to AVAILABLE,
-- CommCenter Pro requires one of two outcomes:
--   DELIVERED = patient delivered to the destination facility
--   REFUSAL   = transport unit obtained a patient refusal
--
-- Either outcome:
-- * closes the EMS patient-flow encounter
-- * clears the ambulance from the CAD incident
-- * returns the ambulance to AVAILABLE
-- * clears its live transport destination
-- * records the disposition and CAD audit history
--
-- The CAD incident itself remains open for Dispatch to close separately.

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
  eid uuid;
  unit_status_value text;
  destination_value text;
  outcome_value text;
  disposition_value text;
  actor_kind_value text;
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

  destination_value:=coalesce(nullif(trim(e.transport_destination),''),nullif(trim(destination_value),''));

  if outcome_value='DELIVERED' and destination_value is null then
    raise exception 'Destination facility is required before recording hospital delivery';
  end if;

  disposition_value:=case
    when outcome_value='DELIVERED' then 'TRANSPORTED'
    else 'REFUSAL'
  end;

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

  if unit_status_value is distinct from 'AVAILABLE' then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,
      unit_status_value,'AVAILABLE',
      auth.uid(),actor_kind_value,
      destination_value,null
    );
  end if;

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
      'automatic_unit_release',true
    ),
    auth.uid(),actor_kind_value
  );

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',
    jsonb_build_object(
      'from',unit_status_value,
      'to','AVAILABLE',
      'reason',case
        when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED'
        else 'TRANSPORT_REFUSAL'
      end
    ),
    auth.uid(),actor_kind_value
  );

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_UNASSIGNED',
    jsonb_build_object(
      'new_status','AVAILABLE',
      'reason',case
        when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED'
        else 'TRANSPORT_REFUSAL'
      end,
      'automatic',true
    ),
    auth.uid(),actor_kind_value
  );

  return outcome_value;
end;
$$;

revoke all on function public.ems_finish_ambulance_transport(uuid,uuid,text) from public;
grant execute on function public.ems_finish_ambulance_transport(uuid,uuid,text) to authenticated;

-- Keep the older "complete transport" RPC behavior synchronized with CAD.
create or replace function public.ems_complete_transport(
  p_encounter_id uuid,
  p_destination text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if nullif(trim(p_destination),'') is not null then
    update public.ems_encounters
    set transport_destination=trim(p_destination)
    where id=e.id;

    update public.units
    set current_transport_destination_text=trim(p_destination)
    where id=e.current_unit_id;
  end if;

  perform public.ems_finish_ambulance_transport(
    e.current_unit_id,
    e.incident_id,
    'DELIVERED'
  );
end;
$$;

revoke all on function public.ems_complete_transport(uuid,text) from public;
grant execute on function public.ems_complete_transport(uuid,text) to authenticated;

-- Prevent normal status-change APIs from bypassing the disposition prompt.
create or replace function public.staff_set_unit_status_v2(
  p_unit_id uuid,
  p_status text,
  p_incident_id uuid default null,
  p_transport_destination_text text default null,
  p_transport_treatment_area_id uuid default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  old_s text;
  dep_statuses jsonb;
  is_ambulance boolean:=false;
  old_destination_text text;
  old_destination_area uuid;
  normalized_text text;
  normalized_area uuid;
  encounter_id_value uuid;
begin
  select
    u.event_id,
    u.status,
    d.status_profile,
    u.current_transport_destination_text,
    u.current_transport_treatment_area_id
  into
    eid,
    old_s,
    dep_statuses,
    old_destination_text,
    old_destination_area
  from public.units u
  join public.event_departments d on d.id=u.department_id
  where u.id=p_unit_id and u.active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  if p_incident_id is not null and not exists(
    select 1 from public.incidents
    where id=p_incident_id and event_id=eid and status='OPEN'
  ) then
    raise exception 'Active incident is not part of this event';
  end if;

  if p_status<>'ASSIGNED' and not (dep_statuses ? p_status) then
    raise exception 'Status % is not allowed for this department',p_status;
  end if;

  select exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) into is_ambulance;

  -- A transport ambulance with an unresolved EMS transport cannot simply be
  -- made available. The user must record whether the patient was delivered
  -- or the transport ended in a refusal.
  if is_ambulance
     and p_status in ('AVAILABLE','CLEAR','COMPLETE')
     and exists(
       select 1
       from public.ems_encounters e
       where e.event_id=eid
         and e.current_unit_id=p_unit_id
         and e.current_status='TRANSPORTING'
         and (p_incident_id is null or e.incident_id=p_incident_id)
     )
  then
    raise exception 'Transport outcome confirmation is required before this ambulance can be made available';
  end if;

  if p_status='TRANSPORTING' then
    if is_ambulance then
      normalized_text:=nullif(trim(p_transport_destination_text),'');
      normalized_area:=null;
      if normalized_text is null then
        raise exception 'Destination facility is required for an ambulance transport';
      end if;
    else
      normalized_text:=null;
      normalized_area:=p_transport_treatment_area_id;

      if normalized_area is null then
        raise exception 'Treatment-area destination is required when this unit is transporting';
      end if;

      if not exists(
        select 1
        from public.ems_treatment_areas a
        where a.id=normalized_area
          and a.event_id=eid
          and a.active=true
          and a.status<>'CLOSED'
      ) then
        raise exception 'Selected treatment area is not available for this event';
      end if;
    end if;
  else
    normalized_text:=null;
    normalized_area:=null;
  end if;

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
      auth.uid(),'staff',
      normalized_text,normalized_area
    );

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',
      jsonb_build_object(
        'from',old_s,
        'to',p_status,
        'transport_destination_text',normalized_text,
        'transport_treatment_area_id',normalized_area
      ),
      auth.uid(),'staff'
    );
  elsif
    old_destination_text is distinct from normalized_text
    or old_destination_area is distinct from normalized_area
  then
    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,'UNIT_TRANSPORT_DESTINATION_UPDATED',
      jsonb_build_object(
        'transport_destination_text',normalized_text,
        'transport_treatment_area_id',normalized_area
      ),
      auth.uid(),'staff'
    );
  end if;

  -- If this is the ambulance currently holding an EMS patient, starting
  -- TRANSPORTING from the normal unit controls also starts EMS transport.
  if is_ambulance and p_status='TRANSPORTING' then
    select e.id
    into encounter_id_value
    from public.ems_encounters e
    where e.event_id=eid
      and e.current_unit_id=p_unit_id
      and e.current_status<>'CLOSED'
      and (p_incident_id is null or e.incident_id=p_incident_id)
    order by e.created_at
    limit 1;

    if encounter_id_value is not null then
      update public.ems_encounters
      set
        current_status='TRANSPORTING',
        transport_destination=normalized_text,
        transport_started_at=coalesce(transport_started_at,now())
      where id=encounter_id_value;
    end if;
  end if;
end;
$$;

create or replace function public.field_set_unit_status_v2(
  p_unit_id uuid,
  p_status text,
  p_incident_id uuid default null,
  p_client_time timestamptz default null,
  p_transport_destination_text text default null,
  p_transport_treatment_area_id uuid default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  old_s text;
  allowed jsonb;
  is_ambulance boolean:=false;
  old_destination_text text;
  old_destination_area uuid;
  normalized_text text;
  normalized_area uuid;
  encounter_id_value uuid;
begin
  if not public.field_has_unit_access(p_unit_id) then
    raise exception 'Not authorized for this unit';
  end if;

  select
    u.event_id,
    u.status,
    d.status_profile,
    u.current_transport_destination_text,
    u.current_transport_treatment_area_id
  into
    eid,
    old_s,
    allowed,
    old_destination_text,
    old_destination_area
  from public.units u
  join public.event_departments d on d.id=u.department_id
  where u.id=p_unit_id and u.active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if not (allowed ? p_status) then
    raise exception 'Status not allowed for this department';
  end if;

  if p_incident_id is not null and not exists(
    select 1 from public.incidents
    where id=p_incident_id and event_id=eid and status='OPEN'
  ) then
    raise exception 'Active incident is not part of this event';
  end if;

  select exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) into is_ambulance;

  -- A transport ambulance with an unresolved EMS transport cannot simply be
  -- made available. The user must record whether the patient was delivered
  -- or the transport ended in a refusal.
  if is_ambulance
     and p_status in ('AVAILABLE','CLEAR','COMPLETE')
     and exists(
       select 1
       from public.ems_encounters e
       where e.event_id=eid
         and e.current_unit_id=p_unit_id
         and e.current_status='TRANSPORTING'
         and (p_incident_id is null or e.incident_id=p_incident_id)
     )
  then
    raise exception 'Transport outcome confirmation is required before this ambulance can be made available';
  end if;

  if p_status='TRANSPORTING' then
    if is_ambulance then
      normalized_text:=nullif(trim(p_transport_destination_text),'');
      normalized_area:=null;
      if normalized_text is null then
        raise exception 'Destination facility is required for an ambulance transport';
      end if;
    else
      normalized_text:=null;
      normalized_area:=p_transport_treatment_area_id;

      if normalized_area is null then
        raise exception 'Treatment-area destination is required when this unit is transporting';
      end if;

      if not exists(
        select 1
        from public.ems_treatment_areas a
        where a.id=normalized_area
          and a.event_id=eid
          and a.active=true
          and a.status<>'CLOSED'
      ) then
        raise exception 'Selected treatment area is not available for this event';
      end if;
    end if;
  else
    normalized_text:=null;
    normalized_area:=null;
  end if;

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,client_time,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
      auth.uid(),'field',p_client_time,
      normalized_text,normalized_area
    );

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',
      jsonb_build_object(
        'from',old_s,
        'to',p_status,
        'transport_destination_text',normalized_text,
        'transport_treatment_area_id',normalized_area
      ),
      auth.uid(),'field'
    );
  elsif
    old_destination_text is distinct from normalized_text
    or old_destination_area is distinct from normalized_area
  then
    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,'UNIT_TRANSPORT_DESTINATION_UPDATED',
      jsonb_build_object(
        'transport_destination_text',normalized_text,
        'transport_treatment_area_id',normalized_area
      ),
      auth.uid(),'field'
    );
  end if;

  if p_incident_id is not null and p_status in ('AVAILABLE','CLEAR','COMPLETE') then
    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;
  end if;

  if is_ambulance and p_status='TRANSPORTING' then
    select e.id
    into encounter_id_value
    from public.ems_encounters e
    where e.event_id=eid
      and e.current_unit_id=p_unit_id
      and e.current_status<>'CLOSED'
      and (p_incident_id is null or e.incident_id=p_incident_id)
    order by e.created_at
    limit 1;

    if encounter_id_value is not null then
      update public.ems_encounters
      set
        current_status='TRANSPORTING',
        transport_destination=normalized_text,
        transport_started_at=coalesce(transport_started_at,now())
      where id=encounter_id_value;
    end if;
  end if;
end;
$$;
