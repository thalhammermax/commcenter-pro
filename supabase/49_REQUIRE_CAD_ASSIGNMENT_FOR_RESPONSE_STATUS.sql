-- CommCenter Pro v0.15.6
-- Prevent CAD response statuses from existing without an active CAD assignment.
-- This is enforced for both Dispatch and Field Unit RPCs, not only hidden in UI.

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
  old_cad_status text;
  effective_status text;
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

  -- CAD response/progress statuses are task states, not free-standing unit states.
  -- An unassigned unit may only change its availability state.
  if p_incident_id is null and p_status not in ('AVAILABLE','OUT_OF_SERVICE') then
    raise exception 'Status % requires an active CAD assignment',p_status;
  end if;

  if p_incident_id is not null then
    select iu.cad_status
    into old_cad_status
    from public.incident_units iu
    where iu.incident_id=p_incident_id
      and iu.unit_id=p_unit_id
      and iu.cleared_at is null
    for update;

    if not found then
      raise exception 'Unit is not currently assigned to this incident';
    end if;

    update public.incident_units
    set cad_status=p_status, cad_status_updated_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;

    if old_cad_status is distinct from p_status then
      insert into public.cad_activity(
        event_id,incident_id,unit_id,action,detail,
        actor_user_id,actor_kind
      ) values(
        eid,p_incident_id,p_unit_id,'CAD_ASSIGNMENT_STATUS_CHANGED',
        jsonb_build_object('from',old_cad_status,'to',p_status),
        auth.uid(),'staff'
      );
    end if;
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

  -- units.status is CAD/general availability state only. Guest Logistics MOVE
  -- status is stored independently on guest_logistics_movements and never
  -- participates in this value.
  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,p_status);

  update public.units
  set
    status=effective_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,effective_status,
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
        'to',effective_status,
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

revoke all on function public.staff_set_unit_status_v2(uuid,text,uuid,text,uuid) from public;
grant execute on function public.staff_set_unit_status_v2(uuid,text,uuid,text,uuid) to authenticated;

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
  old_cad_status text;
  effective_status text;
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

  -- CAD response/progress statuses are task states, not free-standing unit states.
  -- An unassigned field unit may only change its availability state.
  if p_incident_id is null and p_status not in ('AVAILABLE','OUT_OF_SERVICE') then
    raise exception 'Status % requires an active CAD assignment',p_status;
  end if;

  if p_incident_id is not null then
    select iu.cad_status
    into old_cad_status
    from public.incident_units iu
    where iu.incident_id=p_incident_id
      and iu.unit_id=p_unit_id
      and iu.cleared_at is null
    for update;

    if not found then
      raise exception 'Unit is not currently assigned to this incident';
    end if;

    update public.incident_units
    set cad_status=p_status, cad_status_updated_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;

    if old_cad_status is distinct from p_status then
      insert into public.cad_activity(
        event_id,incident_id,unit_id,action,detail,
        actor_user_id,actor_kind
      ) values(
        eid,p_incident_id,p_unit_id,'CAD_ASSIGNMENT_STATUS_CHANGED',
        jsonb_build_object('from',old_cad_status,'to',p_status),
        auth.uid(),'field'
      );
    end if;
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

  -- units.status is CAD/general availability state only. Guest Logistics MOVE
  -- status is stored independently on guest_logistics_movements and never
  -- participates in this value.
  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,p_status);

  update public.units
  set
    status=effective_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,client_time,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,effective_status,
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
        'to',effective_status,
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

revoke all on function public.staff_set_unit_status_v2(uuid,text,uuid,text,uuid) from public;
grant execute on function public.staff_set_unit_status_v2(uuid,text,uuid,text,uuid) to authenticated;
revoke all on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) from public;
grant execute on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) to authenticated;
