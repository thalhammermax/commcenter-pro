-- CommCenter Pro v0.15.0
-- Multi-task Guest Logistics priority model + Command Board MOVE visibility.
--
-- Guest Logistics-enabled units may hold multiple assigned MOVEs and one CAD
-- incident simultaneously. MOVEs are the primary task; CAD remains secondary.
-- Only one MOVE may be physically underway at a time.

-- Command Board sessions may read assigned guest movements for their event.
drop policy if exists guest_logistics_movements_read on public.guest_logistics_movements;
create policy guest_logistics_movements_read
on public.guest_logistics_movements
for select
to authenticated
using(
  private.staff_can_access_department(event_id,department_id)
  or assigned_unit_id=private.current_field_unit()
  or private.command_has_event_access(event_id)
);

-- Resolve the unit status owned by the currently-underway MOVE. The unique
-- partial index from v0.12 permits multiple queued/assigned MOVEs but still
-- guarantees that only one can be underway for a unit.
create or replace function private.guest_logistics_primary_unit_status(
  p_unit_id uuid,
  p_fallback text
)
returns text
language sql
stable
security definer
set search_path=public
as $$
  select coalesce((
    select case m.status
      when 'EN_ROUTE_PICKUP' then 'RESPONDING'
      when 'AT_PICKUP' then 'ON_SCENE'
      when 'PASSENGER_ONBOARD' then 'TRANSPORTING'
      when 'EN_ROUTE_DESTINATION' then 'TRANSPORTING'
      else null
    end
    from public.guest_logistics_movements m
    where m.assigned_unit_id=p_unit_id
      and m.status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION')
    order by m.scheduled_at,m.assigned_at
    limit 1
  ),p_fallback);
$$;

revoke all on function private.guest_logistics_primary_unit_status(uuid,text) from public;

create or replace function public.assign_unit(p_incident_id uuid,p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  old_s text;
  other_incident text;
  effective_status text;
begin
  select event_id into eid
  from public.incidents
  where id=p_incident_id and status='OPEN';

  if eid is null then
    raise exception 'Incident not found or is already closed';
  end if;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  if not exists(
    select 1 from public.units
    where id=p_unit_id and event_id=eid and active=true
  ) then
    raise exception 'Unit is not an active unit in this event';
  end if;

  select i.incident_number
  into other_incident
  from public.incident_units iu
  join public.incidents i on i.id=iu.incident_id
  where iu.unit_id=p_unit_id
    and iu.cleared_at is null
    and i.status='OPEN'
    and i.id<>p_incident_id
  order by iu.assigned_at desc
  limit 1;

  if other_incident is not null then
    raise exception 'Unit is already assigned to %',other_incident;
  end if;

  select status into old_s
  from public.units
  where id=p_unit_id;

  insert into public.incident_units(incident_id,unit_id)
  values(p_incident_id,p_unit_id)
  on conflict(incident_id,unit_id)
  do update set assigned_at=now(),cleared_at=null;

  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,'ASSIGNED');

  update public.units
  set status=effective_status
  where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,old_s,effective_status,auth.uid(),'staff'
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_ASSIGNED',auth.uid(),'staff'
  );
end;
$$;

create or replace function public.unassign_unit(
  p_incident_id uuid,
  p_unit_id uuid,
  p_new_status text default 'AVAILABLE'
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
  effective_status text;
begin
  select event_id into eid
  from public.incidents
  where id=p_incident_id;

  if eid is null then
    raise exception 'Incident not found';
  end if;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  if not exists(
    select 1 from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null
  ) then
    raise exception 'Unit is not currently assigned to this incident';
  end if;

  select u.status,d.status_profile
  into old_s,dep_statuses
  from public.units u
  join public.event_departments d on d.id=u.department_id
  where u.id=p_unit_id and u.event_id=eid;

  if old_s is null then
    raise exception 'Unit not found in this event';
  end if;

  if p_new_status is null or trim(p_new_status)='' then
    p_new_status:='AVAILABLE';
  end if;

  -- AVAILABLE is always valid as the default post-assignment state.
  -- Otherwise require the department's configured status list.
  if p_new_status<>'AVAILABLE' and not (dep_statuses ? p_new_status) then
    raise exception 'Status % is not allowed for this department', p_new_status;
  end if;

  update public.incident_units
  set cleared_at=now()
  where incident_id=p_incident_id
    and unit_id=p_unit_id
    and cleared_at is null;

  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,p_new_status);

  update public.units
  set status=effective_status
  where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind
    )
    values(
      eid,p_incident_id,p_unit_id,old_s,effective_status,
      auth.uid(),'staff'
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  )
  values(
    eid,p_incident_id,p_unit_id,'UNIT_UNASSIGNED',
    jsonb_build_object('new_status',effective_status,'requested_status',p_new_status,'guest_logistics_primary',effective_status is distinct from p_new_status),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.guest_logistics_set_status(
  p_movement_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
  target_status text;
  old_unit_status text;
  effective_unit_status text;
  actor_kind_value text;
  is_staff boolean:=false;
  old_was_underway boolean:=false;
  target_is_underway boolean:=false;
begin
  select * into m
  from public.guest_logistics_movements
  where id=p_movement_id
  for update;

  if m.id is null then
    raise exception 'Movement not found';
  end if;

  is_staff:=private.guest_logistics_staff_access(m.event_id,m.department_id);

  if is_staff then
    actor_kind_value:='staff';
  elsif m.assigned_unit_id is not null
    and m.assigned_unit_id=private.current_field_unit()
  then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this guest movement';
  end if;

  target_status:=upper(trim(coalesce(p_status,'')));

  if target_status not in (
    'READY',
    'EN_ROUTE_PICKUP',
    'AT_PICKUP',
    'PASSENGER_ONBOARD',
    'EN_ROUTE_DESTINATION',
    'COMPLETE',
    'NO_SHOW',
    'CANCELLED'
  ) then
    raise exception 'Invalid movement status';
  end if;

  if m.status in ('COMPLETE','NO_SHOW','CANCELLED') then
    raise exception 'Movement is already closed';
  end if;

  if target_status='READY' and m.status<>'SCHEDULED' then
    raise exception 'Only a scheduled movement can be marked Ready';
  end if;

  if target_status='EN_ROUTE_PICKUP' and m.status not in ('ASSIGNED','READY') then
    raise exception 'Movement must be assigned / ready before the driver can start';
  end if;

  if target_status='AT_PICKUP' and m.status<>'EN_ROUTE_PICKUP' then
    raise exception 'Driver must be en route to pickup first';
  end if;

  if target_status in ('PASSENGER_ONBOARD','NO_SHOW') and m.status<>'AT_PICKUP' then
    raise exception 'Driver must be at pickup first';
  end if;

  if target_status='EN_ROUTE_DESTINATION' and m.status<>'PASSENGER_ONBOARD' then
    raise exception 'Guest must be on board first';
  end if;

  if target_status='COMPLETE' and m.status<>'EN_ROUTE_DESTINATION' then
    raise exception 'Movement must be en route to destination before completion';
  end if;

  if target_status not in ('READY','CANCELLED')
     and m.assigned_unit_id is null then
    raise exception 'Assign a driver unit before starting this movement';
  end if;

  old_was_underway:=m.status in (
    'EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION'
  );
  target_is_underway:=target_status in (
    'EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION'
  );

  -- Beginning a trip is the point at which the driver becomes operationally
  -- committed. Future preassignments do not block CAD work.
  if target_status='EN_ROUTE_PICKUP' then
    if not exists(
      select 1
      from public.units u
      where u.id=m.assigned_unit_id
        and u.event_id=m.event_id
        and u.active=true
        and u.status<>'OUT_OF_SERVICE'
    ) then
      raise exception 'Driver unit is not available to begin this movement';
    end if;

    if exists(
      select 1
      from public.ems_encounters e
      where e.current_unit_id=m.assigned_unit_id
        and e.current_status<>'CLOSED'
    ) then
      raise exception 'Driver unit currently has active EMS patient custody';
    end if;

    if exists(
      select 1
      from public.guest_logistics_movements other
      where other.assigned_unit_id=m.assigned_unit_id
        and other.id<>m.id
        and other.status in (
          'EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION'
        )
    ) then
      raise exception 'Driver unit is already underway on another guest movement';
    end if;
  end if;

  -- Update the MOVE first so status restoration can see whether another MOVE
  -- is still underway. CAD remains assigned as secondary work throughout.
  update public.guest_logistics_movements
  set
    status=target_status,
    driver_acknowledged_at=case
      when target_status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION','COMPLETE')
        then coalesce(driver_acknowledged_at,now())
      else driver_acknowledged_at
    end,
    en_route_pickup_at=case when target_status='EN_ROUTE_PICKUP' then coalesce(en_route_pickup_at,now()) else en_route_pickup_at end,
    at_pickup_at=case when target_status='AT_PICKUP' then coalesce(at_pickup_at,now()) else at_pickup_at end,
    passenger_onboard_at=case when target_status='PASSENGER_ONBOARD' then coalesce(passenger_onboard_at,now()) else passenger_onboard_at end,
    en_route_destination_at=case when target_status='EN_ROUTE_DESTINATION' then coalesce(en_route_destination_at,now()) else en_route_destination_at end,
    completed_at=case when target_status='COMPLETE' then coalesce(completed_at,now()) else completed_at end,
    no_show_at=case when target_status='NO_SHOW' then coalesce(no_show_at,now()) else no_show_at end,
    cancelled_at=case when target_status='CANCELLED' then coalesce(cancelled_at,now()) else cancelled_at end,
    updated_at=now()
  where id=m.id;

  -- Once a MOVE is underway it owns the shared unit status. When that MOVE
  -- terminates, a still-open CAD assignment is promoted back to ASSIGNED.
  if m.assigned_unit_id is not null and (old_was_underway or target_is_underway) then
    select status into old_unit_status
    from public.units
    where id=m.assigned_unit_id
    for update;

    effective_unit_status:=private.guest_logistics_primary_unit_status(
      m.assigned_unit_id,
      case
        when exists(
          select 1
          from public.incident_units iu
          join public.incidents i on i.id=iu.incident_id
          where iu.unit_id=m.assigned_unit_id
            and iu.cleared_at is null
            and i.status='OPEN'
        ) then 'ASSIGNED'
        else 'AVAILABLE'
      end
    );

    update public.units
    set
      status=effective_unit_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=m.assigned_unit_id;

    if old_unit_status is distinct from effective_unit_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind
      ) values(
        m.event_id,null,m.assigned_unit_id,
        old_unit_status,effective_unit_status,
        auth.uid(),actor_kind_value
      );
    end if;
  end if;

  insert into public.guest_logistics_activity(
    event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,
    m.id,
    m.assigned_unit_id,
    'MOVEMENT_STATUS_CHANGED',
    jsonb_build_object('from',m.status,'to',target_status),
    auth.uid(),
    actor_kind_value
  );

  insert into public.cad_activity(
    event_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,
    m.assigned_unit_id,
    'LOGISTICS_MOVEMENT_STATUS_CHANGED',
    jsonb_build_object(
      'movement_id',m.id,
      'movement_number',m.movement_number,
      'guest_name',m.guest_name,
      'from',m.status,
      'to',target_status
    ),
    auth.uid(),
    actor_kind_value
  );
end;
$$;

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
  effective_status text;
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

    effective_status:=private.guest_logistics_primary_unit_status(unit_rec.unit_id,'AVAILABLE');

    update public.units
    set
      status=effective_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=unit_rec.unit_id;

    if unit_rec.status is distinct from effective_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,effective_status,
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status',effective_status,
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

revoke all on function public.assign_unit(uuid,uuid) from public;
grant execute on function public.assign_unit(uuid,uuid) to authenticated;
revoke all on function public.unassign_unit(uuid,uuid,text) from public;
grant execute on function public.unassign_unit(uuid,uuid,text) to authenticated;
revoke all on function public.guest_logistics_set_status(uuid,text) from public;
grant execute on function public.guest_logistics_set_status(uuid,text) to authenticated;
revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;
