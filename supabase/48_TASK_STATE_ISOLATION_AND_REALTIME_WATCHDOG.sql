-- CommCenter Pro v0.15.5
-- Hard separation of CAD/general unit status from Guest Logistics MOVE status,
-- plus an authoritative task-state snapshot for Dispatch reconciliation.

-- Compatibility helper retained because assignment/EMS functions already call it.
-- IMPORTANT: MOVEs no longer participate in the value returned here. units.status
-- is a CAD/general-unit status only; guest_logistics_movements.status is independent.
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

-- MOVE assignment itself must never change the CAD/general unit status.
drop trigger if exists sync_guest_logistics_primary_status_on_assignment on public.guest_logistics_movements;

-- MOVE status changes update the MOVE only. They must never rewrite units.status
-- or incident_units.cad_status.
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
  actor_kind_value text;
  is_staff boolean:=false;
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

  update public.guest_logistics_movements
  set
    status=target_status,
    en_route_pickup_at=case when target_status='EN_ROUTE_PICKUP' then coalesce(en_route_pickup_at,now()) else en_route_pickup_at end,
    at_pickup_at=case when target_status='AT_PICKUP' then coalesce(at_pickup_at,now()) else at_pickup_at end,
    passenger_onboard_at=case when target_status='PASSENGER_ONBOARD' then coalesce(passenger_onboard_at,now()) else passenger_onboard_at end,
    en_route_destination_at=case when target_status='EN_ROUTE_DESTINATION' then coalesce(en_route_destination_at,now()) else en_route_destination_at end,
    completed_at=case when target_status='COMPLETE' then coalesce(completed_at,now()) else completed_at end,
    no_show_at=case when target_status='NO_SHOW' then coalesce(no_show_at,now()) else no_show_at end,
    cancelled_at=case when target_status='CANCELLED' then coalesce(cancelled_at,now()) else cancelled_at end,
    updated_at=now()
  where id=m.id;

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

revoke all on function public.guest_logistics_set_status(uuid,text) from public;
grant execute on function public.guest_logistics_set_status(uuid,text) to authenticated;

-- Repair only statuses that can be positively identified as MOVE-derived.
-- If a CAD assignment exists, its cad_status is authoritative. Otherwise a
-- MOVE-mapped ASSIGNED/RESPONDING/ON_SCENE/TRANSPORTING value is returned to
-- AVAILABLE. OUT_OF_SERVICE and unrelated custom/general statuses are preserved.
with move_units as (
  select distinct m.assigned_unit_id as unit_id
  from public.guest_logistics_movements m
  where m.assigned_unit_id is not null
    and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
), repaired as (
  select
    u.id,
    coalesce(
      (
        select coalesce(iu.cad_status,'ASSIGNED')
        from public.incident_units iu
        join public.incidents i on i.id=iu.incident_id
        where iu.unit_id=u.id
          and iu.cleared_at is null
          and i.status='OPEN'
        order by iu.assigned_at desc
        limit 1
      ),
      case
        when u.status='ASSIGNED' and exists(
          select 1 from public.guest_logistics_movements m
          where m.assigned_unit_id=u.id and m.status in ('ASSIGNED','READY','SCHEDULED')
        ) then 'AVAILABLE'
        when u.status='RESPONDING' and exists(
          select 1 from public.guest_logistics_movements m
          where m.assigned_unit_id=u.id and m.status='EN_ROUTE_PICKUP'
        ) then 'AVAILABLE'
        when u.status='ON_SCENE' and exists(
          select 1 from public.guest_logistics_movements m
          where m.assigned_unit_id=u.id and m.status='AT_PICKUP'
        ) then 'AVAILABLE'
        when u.status='TRANSPORTING' and exists(
          select 1 from public.guest_logistics_movements m
          where m.assigned_unit_id=u.id and m.status in ('PASSENGER_ONBOARD','EN_ROUTE_DESTINATION')
        ) then 'AVAILABLE'
        else u.status
      end
    ) as corrected_status
  from public.units u
  join move_units mu on mu.unit_id=u.id
)
update public.units u
set status=r.corrected_status
from repaired r
where u.id=r.id
  and u.status is distinct from r.corrected_status;

-- One compact authoritative snapshot for all task-specific status fields.
-- Realtime remains the fast path; Dispatch polls this as a self-healing watchdog.
create or replace function public.dispatch_task_status_snapshot(
  p_event_id uuid
)
returns table(
  task_kind text,
  incident_id uuid,
  movement_id uuid,
  unit_id uuid,
  status text,
  assigned_at timestamptz,
  acknowledged_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_event_id is null then
    raise exception 'Event is required';
  end if;

  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatcher access required';
  end if;

  return query
  select
    'CAD'::text,
    iu.incident_id,
    null::uuid,
    iu.unit_id,
    coalesce(iu.cad_status,'ASSIGNED')::text,
    iu.assigned_at,
    iu.acknowledged_at,
    coalesce(iu.cad_status_updated_at,iu.assigned_at)
  from public.incident_units iu
  join public.incidents i on i.id=iu.incident_id
  where i.event_id=p_event_id
    and i.status='OPEN'
    and iu.cleared_at is null

  union all

  select
    'MOVE'::text,
    null::uuid,
    m.id,
    m.assigned_unit_id,
    m.status::text,
    m.assigned_at,
    m.driver_acknowledged_at,
    m.updated_at
  from public.guest_logistics_movements m
  where m.event_id=p_event_id
    and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')

  order by 1,2,3,4;
end;
$$;

revoke all on function public.dispatch_task_status_snapshot(uuid) from public;
grant execute on function public.dispatch_task_status_snapshot(uuid) to authenticated;
