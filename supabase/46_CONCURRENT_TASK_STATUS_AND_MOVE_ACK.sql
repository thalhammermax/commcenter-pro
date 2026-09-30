-- CommCenter Pro v0.15.1
-- Independent concurrent CAD + Guest Logistics task status and MOVE acknowledgement UX.

-- CAD assignment status belongs to the incident assignment, not to the unit as a whole.
alter table public.incident_units
  add column if not exists cad_status text,
  add column if not exists cad_status_updated_at timestamptz;

update public.incident_units
set cad_status=coalesce(cad_status,'ASSIGNED'),
    cad_status_updated_at=coalesce(cad_status_updated_at,assigned_at)
where cleared_at is null;

-- New/reactivated CAD assignments start as ASSIGNED and require a fresh acknowledgement.
create or replace function private.reset_incident_unit_acknowledgement()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op='INSERT' then
    new.acknowledged_at:=null;
    new.acknowledged_by:=null;
    new.cad_status:=coalesce(new.cad_status,'ASSIGNED');
    new.cad_status_updated_at:=coalesce(new.cad_status_updated_at,now());
  elsif new.cleared_at is null
    and (
      old.cleared_at is not null
      or new.assigned_at is distinct from old.assigned_at
    )
  then
    new.acknowledged_at:=null;
    new.acknowledged_by:=null;
    new.cad_status:='ASSIGNED';
    new.cad_status_updated_at:=now();
  end if;

  return new;
end;
$$;

-- Reassigning a MOVE to a driver always creates a fresh acknowledgement obligation.
create or replace function private.reset_guest_logistics_driver_acknowledgement()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if new.assigned_unit_id is not null
     and (
       tg_op='INSERT'
       or new.assigned_unit_id is distinct from old.assigned_unit_id
       or new.assigned_at is distinct from old.assigned_at
     )
  then
    new.driver_acknowledged_at:=null;
  end if;
  return new;
end;
$$;

drop trigger if exists reset_guest_logistics_driver_acknowledgement on public.guest_logistics_movements;
create trigger reset_guest_logistics_driver_acknowledgement
before insert or update of assigned_unit_id,assigned_at
on public.guest_logistics_movements
for each row
execute function private.reset_guest_logistics_driver_acknowledgement();

-- The shared unit status is now only a summary of the PRIMARY task. Any assigned
-- MOVE wins. When no MOVE remains, the active CAD assignment's own status is used.
create or replace function private.guest_logistics_primary_unit_status(
  p_unit_id uuid,
  p_fallback text
)
returns text
language sql
volatile
security definer
set search_path=public
as $$
  select coalesce(
    (
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
    ),
    (
      select 'ASSIGNED'::text
      from public.guest_logistics_movements m
      where m.assigned_unit_id=p_unit_id
        and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
      order by m.scheduled_at,m.assigned_at
      limit 1
    ),
    (
      select coalesce(iu.cad_status,'ASSIGNED')
      from public.incident_units iu
      join public.incidents i on i.id=iu.incident_id
      where iu.unit_id=p_unit_id
        and iu.cleared_at is null
        and i.status='OPEN'
      order by iu.assigned_at desc
      limit 1
    ),
    p_fallback
  );
$$;

revoke all on function private.guest_logistics_primary_unit_status(uuid,text) from public;

-- As soon as a MOVE is assigned it becomes the unit's primary task. If a MOVE is
-- removed/reassigned, restore the old unit to its remaining MOVE or CAD status.
create or replace function private.sync_guest_logistics_primary_status_on_assignment()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  unit_id_value uuid;
  old_status text;
  new_status text;
begin
  if tg_op='UPDATE' and old.assigned_unit_id is not null
     and old.assigned_unit_id is distinct from new.assigned_unit_id
  then
    unit_id_value:=old.assigned_unit_id;
    select status into old_status from public.units where id=unit_id_value for update;
    if found then
      new_status:=private.guest_logistics_primary_unit_status(unit_id_value,'AVAILABLE');
      update public.units set status=new_status where id=unit_id_value;
      if old_status is distinct from new_status then
        insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
        values(old.event_id,null,unit_id_value,old_status,new_status,auth.uid(),'staff');
      end if;
    end if;
  end if;

  if new.assigned_unit_id is not null
     and (tg_op='INSERT' or new.assigned_unit_id is distinct from old.assigned_unit_id)
  then
    unit_id_value:=new.assigned_unit_id;
    select status into old_status from public.units where id=unit_id_value for update;
    if found then
      new_status:=private.guest_logistics_primary_unit_status(unit_id_value,'AVAILABLE');
      update public.units set status=new_status where id=unit_id_value;
      if old_status is distinct from new_status then
        insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
        values(new.event_id,null,unit_id_value,old_status,new_status,auth.uid(),'staff');
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists sync_guest_logistics_primary_status_on_assignment on public.guest_logistics_movements;
create trigger sync_guest_logistics_primary_status_on_assignment
after insert or update of assigned_unit_id
on public.guest_logistics_movements
for each row
execute function private.sync_guest_logistics_primary_status_on_assignment();

-- Allow a driver to explicitly acknowledge any still-open MOVE, even if Dispatch
-- already advanced the MOVE before the driver saw it.
create or replace function public.guest_logistics_acknowledge_movement(
  p_movement_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
begin
  select * into m
  from public.guest_logistics_movements
  where id=p_movement_id
  for update;

  if m.id is null then
    raise exception 'Movement not found';
  end if;

  if m.assigned_unit_id is null
     or m.assigned_unit_id<>private.current_field_unit() then
    raise exception 'Only the assigned driver unit can acknowledge this movement';
  end if;

  if m.status in ('COMPLETE','NO_SHOW','CANCELLED') then
    raise exception 'Movement is already closed';
  end if;

  update public.guest_logistics_movements
  set
    driver_acknowledged_at=coalesce(driver_acknowledged_at,now()),
    updated_at=now()
  where id=m.id;

  if m.driver_acknowledged_at is null then
    insert into public.guest_logistics_activity(
      event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind
    ) values(
      m.event_id,m.id,m.assigned_unit_id,
      'DRIVER_ACKNOWLEDGED',
      '{}'::jsonb,
      auth.uid(),'field'
    );

    insert into public.cad_activity(
      event_id,unit_id,action,detail,actor_user_id,actor_kind
    ) values(
      m.event_id,m.assigned_unit_id,
      'LOGISTICS_DRIVER_ACKNOWLEDGED',
      jsonb_build_object(
        'movement_id',m.id,
        'movement_number',m.movement_number,
        'guest_name',m.guest_name
      ),
      auth.uid(),'field'
    );
  end if;
end;
$$;

revoke all on function public.guest_logistics_acknowledge_movement(uuid) from public;
grant execute on function public.guest_logistics_acknowledge_movement(uuid) to authenticated;

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

  if actor_kind_value='field'
     and target_status='EN_ROUTE_PICKUP'
     and m.driver_acknowledged_at is null
  then
    raise exception 'Acknowledge this MOVE before going en route';
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
    driver_acknowledged_at=driver_acknowledged_at,
    en_route_pickup_at=case when target_status='EN_ROUTE_PICKUP' then coalesce(en_route_pickup_at,now()) else en_route_pickup_at end,
    at_pickup_at=case when target_status='AT_PICKUP' then coalesce(at_pickup_at,now()) else at_pickup_at end,
    passenger_onboard_at=case when target_status='PASSENGER_ONBOARD' then coalesce(passenger_onboard_at,now()) else passenger_onboard_at end,
    en_route_destination_at=case when target_status='EN_ROUTE_DESTINATION' then coalesce(en_route_destination_at,now()) else en_route_destination_at end,
    completed_at=case when target_status='COMPLETE' then coalesce(completed_at,now()) else completed_at end,
    no_show_at=case when target_status='NO_SHOW' then coalesce(no_show_at,now()) else no_show_at end,
    cancelled_at=case when target_status='CANCELLED' then coalesce(cancelled_at,now()) else cancelled_at end,
    updated_at=now()
  where id=m.id;

  -- Recompute the shared primary-task summary after every MOVE status change.
  -- This also restores the next MOVE or the CAD task status after cancellation/completion.
  if m.assigned_unit_id is not null then
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
    set status=effective_unit_status
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

  -- CAD status and MOVE status are independent. The shared units.status field
  -- mirrors the primary task only: a MOVE wins while assigned; otherwise the
  -- active CAD assignment status becomes the unit's operational status.
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

  -- CAD status and MOVE status are independent. The shared units.status field
  -- mirrors the primary task only: a MOVE wins while assigned; otherwise the
  -- active CAD assignment status becomes the unit's operational status.
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


-- ============================================================
-- v0.15.1 — EMS HANDOFF / CAD ASSIGNMENT SYNCHRONIZATION
-- ============================================================
-- EMS custody and CAD assignment are one operational transaction:
--   * the handing-off field unit is removed from the incident;
--   * the receiving transport unit is committed to the same incident;
--   * treatment-area handoff releases the sending field unit;
--   * units.status remains only the primary-task summary, so an assigned MOVE
--     may continue to take precedence over the secondary CAD task.

create or replace function private.ems_sync_incident_units(
  p_incident_id uuid,
  p_old_unit_id uuid,
  p_to_unit_id uuid,
  p_actor_kind text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  other_incident text;
  clear_rec record;
  old_status_value text;
  effective_old_status text;
  destination_old_status text;
  destination_effective_status text;
  old_assignment_active boolean:=false;
  destination_assignment_active boolean:=false;
begin
  select event_id
  into eid
  from public.incidents
  where id=p_incident_id
    and status='OPEN';

  if eid is null then
    raise exception 'Active incident not found';
  end if;

  if p_to_unit_id is not null then
    if not exists(
      select 1
      from public.units u
      join public.ems_unit_config c on c.unit_id=u.id
      where u.id=p_to_unit_id
        and u.event_id=eid
        and u.active=true
        and c.active=true
        and (c.ems_role='ambulance' or c.transport_capable=true)
    ) then
      raise exception 'Destination unit is not an active ambulance for this event';
    end if;

    select i.incident_number
    into other_incident
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.unit_id=p_to_unit_id
      and iu.cleared_at is null
      and i.status='OPEN'
      and i.id<>p_incident_id
    order by iu.assigned_at desc
    limit 1;

    if other_incident is not null then
      raise exception 'Ambulance is already committed to %',other_incident;
    end if;
  end if;

  if p_old_unit_id is not null then
    select exists(
      select 1
      from public.incident_units
      where incident_id=p_incident_id
        and unit_id=p_old_unit_id
        and cleared_at is null
    ) into old_assignment_active;
  end if;

  -- Normal handoff: remove the actual sending unit. Reconciliation path: if
  -- EMS custody had not yet been established, remove only EMS field-team units
  -- from this incident, never unrelated Security/Facilities/etc. resources.
  for clear_rec in
    select distinct u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    left join public.ems_unit_config c on c.unit_id=u.id and c.active=true
    where iu.incident_id=p_incident_id
      and iu.cleared_at is null
      and u.id is distinct from p_to_unit_id
      and (
        (p_old_unit_id is not null and old_assignment_active and u.id=p_old_unit_id)
        or
        (
          (p_old_unit_id is null or not old_assignment_active)
          and c.ems_role='field_team'
        )
      )
  loop
    old_status_value:=clear_rec.status;

    update public.incident_units
    set
      cleared_at=now(),
      cad_status='AVAILABLE',
      cad_status_updated_at=now()
    where incident_id=p_incident_id
      and unit_id=clear_rec.unit_id
      and cleared_at is null;

    effective_old_status:=private.guest_logistics_primary_unit_status(
      clear_rec.unit_id,
      'AVAILABLE'
    );

    update public.units
    set
      status=effective_old_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=clear_rec.unit_id;

    if old_status_value is distinct from effective_old_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,clear_rec.unit_id,
        old_status_value,effective_old_status,
        auth.uid(),p_actor_kind,null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,clear_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status',effective_old_status,
        'requested_status','AVAILABLE',
        'reason','EMS_HANDOFF',
        'automatic',true,
        'guest_logistics_primary',effective_old_status is distinct from 'AVAILABLE'
      ),
      auth.uid(),p_actor_kind
    );
  end loop;

  -- A receiving ambulance becomes the CAD unit committed to this same call.
  if p_to_unit_id is not null then
    select status
    into destination_old_status
    from public.units
    where id=p_to_unit_id
    for update;

    if destination_old_status is null then
      raise exception 'Destination unit was not found';
    end if;

    select exists(
      select 1
      from public.incident_units
      where incident_id=p_incident_id
        and unit_id=p_to_unit_id
        and cleared_at is null
    ) into destination_assignment_active;

    if not destination_assignment_active then
      insert into public.incident_units(
        incident_id,unit_id,assigned_at,cleared_at,cad_status,cad_status_updated_at
      ) values(
        p_incident_id,p_to_unit_id,now(),null,'ASSIGNED',now()
      )
      on conflict(incident_id,unit_id)
      do update set
        assigned_at=now(),
        cleared_at=null,
        cad_status='ASSIGNED',
        cad_status_updated_at=now();
    end if;

    destination_effective_status:=private.guest_logistics_primary_unit_status(
      p_to_unit_id,
      'ASSIGNED'
    );

    update public.units
    set
      status=destination_effective_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=p_to_unit_id;

    if destination_old_status is distinct from destination_effective_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,p_to_unit_id,
        destination_old_status,destination_effective_status,
        auth.uid(),p_actor_kind,null,null
      );
    end if;

    if not destination_assignment_active then
      insert into public.cad_activity(
        event_id,incident_id,unit_id,action,detail,
        actor_user_id,actor_kind
      ) values(
        eid,p_incident_id,p_to_unit_id,'UNIT_ASSIGNED',
        jsonb_build_object(
          'reason','EMS_HANDOFF',
          'automatic',true,
          'cad_status','ASSIGNED',
          'primary_summary_status',destination_effective_status
        ),
        auth.uid(),p_actor_kind
      );
    end if;
  end if;
end;
$$;

revoke all on function private.ems_sync_incident_units(uuid,uuid,uuid,text) from public;

-- Dispatch/Treatment can set custody before an EMS encounter exists. In older
-- builds that path created the encounter but skipped CAD assignment sync. Make
-- the assignment handoff part of that first custody transaction as well.
create or replace function private.ems_set_incident_custody(
  p_incident_id uuid,
  p_to_unit_id uuid,
  p_to_treatment_area_id uuid,
  p_note text,
  p_actor_kind text
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  e public.ems_encounters;
  ta public.ems_treatment_areas;
  occupancy integer;
  new_status text;
begin
  if ((p_to_unit_id is not null)::int + (p_to_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Choose exactly one custody destination';
  end if;

  select * into i
  from public.incidents
  where id=p_incident_id
    and status<>'CLOSED';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select * into e
  from public.ems_encounters
  where event_id=i.event_id
    and incident_id=i.id
    and current_status<>'CLOSED'
  order by created_at
  limit 1;

  if e.id is not null then
    return private.ems_direct_transfer(
      e.id,p_to_unit_id,p_to_treatment_area_id,p_note,p_actor_kind
    );
  end if;

  if p_to_unit_id is not null then
    if not exists(
      select 1 from public.units u
      where u.id=p_to_unit_id
        and u.event_id=i.event_id
        and u.active=true
    ) then
      raise exception 'Ambulance is not part of this event';
    end if;

    if not exists(
      select 1 from public.ems_unit_config c
      where c.unit_id=p_to_unit_id
        and c.active=true
        and (c.ems_role='ambulance' or c.transport_capable=true)
    ) then
      raise exception 'Destination unit is not configured as an ambulance';
    end if;

    new_status:='WITH_AMBULANCE';
  else
    select * into ta
    from public.ems_treatment_areas
    where id=p_to_treatment_area_id
      and event_id=i.event_id
      and active=true;

    if ta.id is null then
      raise exception 'Treatment area is not part of this event';
    end if;

    if not ta.accepting_patients or ta.status in ('FULL','CLOSED') then
      raise exception 'Treatment area is not accepting patients';
    end if;

    select count(*) into occupancy
    from public.ems_encounters x
    where x.current_treatment_area_id=ta.id
      and x.current_status<>'CLOSED';

    if occupancy>=ta.capacity then
      raise exception 'Treatment area is at capacity';
    end if;

    new_status:='IN_TREATMENT';
  end if;

  -- There is no existing custody row from which to identify an old unit. The
  -- helper's reconciliation mode clears only EMS field-team assignments and
  -- commits the destination ambulance when applicable.
  perform private.ems_sync_incident_units(
    i.id,
    null,
    p_to_unit_id,
    p_actor_kind
  );

  insert into public.ems_encounters(
    event_id,incident_id,tracking_number,current_status,
    current_unit_id,current_treatment_area_id,
    origin_unit_id,operational_note,created_by
  ) values(
    i.event_id,i.id,i.incident_number,new_status,
    p_to_unit_id,p_to_treatment_area_id,
    null,nullif(trim(p_note),''),auth.uid()
  )
  returning * into e;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,p_to_unit_id,'EMS_CUSTODY_SET',
    jsonb_build_object(
      'encounter_id',e.id,
      'incident_number',i.incident_number,
      'to_unit_id',p_to_unit_id,
      'to_treatment_area_id',p_to_treatment_area_id,
      'current_status',new_status,
      'cad_assignment_synced',true,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  return 'RECEIVED';
end;
$$;

revoke all on function private.ems_set_incident_custody(uuid,uuid,uuid,text,text) from public;

-- Keep the legacy request/accept path correct as well, even though the current
-- frontend primarily uses direct transfer RPCs.
create or replace function public.ems_accept_handoff(p_handoff_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  h public.ems_handoffs;
  e public.ems_encounters;
  new_status text;
  role_name text;
  actor_kind_value text;
begin
  select * into h
  from public.ems_handoffs
  where id=p_handoff_id
    and status='PENDING'
  for update;

  if h.id is null then
    raise exception 'Pending handoff not found';
  end if;

  if not (
    public.can_dispatch_event(h.event_id)
    or (h.to_unit_id is not null and private.current_field_unit()=h.to_unit_id)
    or (h.to_treatment_area_id is not null and private.current_treatment_area()=h.to_treatment_area_id)
  ) then
    raise exception 'Only the receiving resource can accept this handoff';
  end if;

  select * into e
  from public.ems_encounters
  where id=h.encounter_id
    and current_status<>'CLOSED'
  for update;

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  actor_kind_value:=case
    when public.can_dispatch_event(h.event_id) then 'staff'
    when h.to_treatment_area_id is not null then 'treatment'
    else 'field'
  end;

  if h.to_treatment_area_id is not null then
    new_status:='IN_TREATMENT';
  else
    select ems_role into role_name
    from public.ems_unit_config
    where unit_id=h.to_unit_id and active=true;
    if role_name='ambulance' then new_status:='WITH_AMBULANCE'; else new_status:='FIELD'; end if;
  end if;

  perform private.ems_sync_incident_units(
    e.incident_id,
    e.current_unit_id,
    h.to_unit_id,
    actor_kind_value
  );

  update public.ems_handoffs
  set status='COMPLETED',responded_by=auth.uid(),responded_at=now(),completed_at=now()
  where id=h.id;

  update public.ems_handoffs
  set status='CANCELLED',responded_at=now()
  where encounter_id=h.encounter_id
    and id<>h.id
    and status='PENDING';

  update public.ems_encounters
  set current_unit_id=h.to_unit_id,
      current_treatment_area_id=h.to_treatment_area_id,
      current_status=new_status
  where id=h.encounter_id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    h.event_id,e.incident_id,e.current_unit_id,'EMS_HANDOFF_COMPLETED',
    jsonb_build_object(
      'encounter_id',h.encounter_id,
      'handoff_id',h.id,
      'from_unit_id',e.current_unit_id,
      'to_unit_id',h.to_unit_id,
      'to_treatment_area_id',h.to_treatment_area_id,
      'cad_assignment_synced',true
    ),
    auth.uid(),actor_kind_value
  );
end;
$$;

revoke all on function public.ems_accept_handoff(uuid) from public;
grant execute on function public.ems_accept_handoff(uuid) to authenticated;
