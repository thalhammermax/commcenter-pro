-- CommCenter Pro v0.17.0
-- Dispatcher-controlled task priority for Guest Logistics units.
--
-- Default rule (unchanged): a unit with an active MOVE treats the MOVE as its
-- primary task and any CAD ticket as secondary.
--
-- New: Dispatch may prioritize a CAD ticket over the unit's MOVE(s). The
-- override lives on the active incident_units link row, so it ends
-- automatically when the ticket closes or the unit is cleared. Dispatch
-- chooses, each time, whether the unit's MOVE(s) are placed on HOLD or keep
-- their running status. HELD MOVEs resume their previous status automatically
-- when the override ends.
--
-- Run against an existing v0.16.0 database. Do not rerun 01_FULL_SCHEMA.sql.

-- ------------------------------------------------------------
-- 1. incident_units: priority override + driver acknowledgement
-- ------------------------------------------------------------
alter table public.incident_units
  add column if not exists cad_priority_override boolean not null default false,
  add column if not exists cad_priority_set_at timestamptz,
  add column if not exists cad_priority_set_by uuid references auth.users(id) on delete set null,
  add column if not exists cad_priority_acknowledged_at timestamptz,
  add column if not exists cad_priority_acknowledged_by uuid references auth.users(id) on delete set null;

create index if not exists incident_units_priority_pending_ack_idx
  on public.incident_units(unit_id)
  where cleared_at is null and cad_priority_override=true and cad_priority_acknowledged_at is null;

-- ------------------------------------------------------------
-- 2. guest_logistics_movements: HELD status + hold bookkeeping
-- ------------------------------------------------------------
alter table public.guest_logistics_movements
  add column if not exists held_from_status text,
  add column if not exists held_at timestamptz,
  add column if not exists held_by_incident_id uuid references public.incidents(id) on delete set null,
  add column if not exists held_by uuid references auth.users(id) on delete set null;

alter table public.guest_logistics_movements
  drop constraint if exists guest_logistics_movements_status_check;

alter table public.guest_logistics_movements
  add constraint guest_logistics_movements_status_check
  check(status in (
    'SCHEDULED',
    'READY',
    'ASSIGNED',
    'EN_ROUTE_PICKUP',
    'AT_PICKUP',
    'PASSENGER_ONBOARD',
    'EN_ROUTE_DESTINATION',
    'HELD',
    'COMPLETE',
    'NO_SHOW',
    'CANCELLED'
  ));

-- ------------------------------------------------------------
-- 3. Resume helper (used by the priority RPC and the clear trigger)
-- ------------------------------------------------------------
create or replace function private.guest_logistics_resume_held_for_incident(
  p_incident_id uuid,
  p_unit_id uuid,
  p_actor_kind text default 'system'
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
  resumed integer:=0;
  target text;
begin
  for m in
    select *
    from public.guest_logistics_movements
    where status='HELD'
      and held_by_incident_id=p_incident_id
      and (p_unit_id is null or assigned_unit_id=p_unit_id)
    for update
  loop
    target:=coalesce(m.held_from_status,'ASSIGNED');
    if target in ('HELD','COMPLETE','NO_SHOW','CANCELLED') then target:='ASSIGNED'; end if;
    -- A driver who was dispatched elsewhere mid-run must restart the leg; a
    -- guest who was already on board stays on board.
    if target in ('EN_ROUTE_PICKUP','AT_PICKUP') then target:='ASSIGNED'; end if;

    update public.guest_logistics_movements
    set status=target,
        held_from_status=null,
        held_at=null,
        held_by_incident_id=null,
        held_by=null,
        updated_at=now()
    where id=m.id;

    insert into public.guest_logistics_activity(event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(m.event_id,m.id,m.assigned_unit_id,'MOVEMENT_RESUMED',
      jsonb_build_object('from','HELD','to',target,'incident_id',p_incident_id),auth.uid(),p_actor_kind);

    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(m.event_id,p_incident_id,m.assigned_unit_id,'LOGISTICS_MOVEMENT_RESUMED',
      jsonb_build_object('movement_id',m.id,'movement_number',m.movement_number,'guest_name',m.guest_name,'to',target),
      auth.uid(),p_actor_kind);

    resumed:=resumed+1;
  end loop;
  return resumed;
end;
$$;

revoke all on function private.guest_logistics_resume_held_for_incident(uuid,uuid,text) from public;

-- When the assignment ends (close, unassign, clear) any MOVE held for it
-- resumes. close_incident_v2 and unassign_unit both set cleared_at, so this
-- trigger covers every existing path without touching those functions.
create or replace function private.release_cad_priority_on_clear()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.cleared_at is not null and old.cleared_at is null then
    if old.cad_priority_override then
      perform private.guest_logistics_resume_held_for_incident(new.incident_id,new.unit_id,'system');
      update public.incident_units
      set cad_priority_override=false
      where id=new.id;
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists release_cad_priority_on_clear on public.incident_units;
create trigger release_cad_priority_on_clear
after update of cleared_at
on public.incident_units
for each row
execute function private.release_cad_priority_on_clear();

-- ------------------------------------------------------------
-- 4. Dispatcher RPC: set / clear the priority override
-- ------------------------------------------------------------
create or replace function public.dispatch_set_cad_priority(
  p_incident_id uuid,
  p_unit_id uuid,
  p_enabled boolean,
  p_hold_movements boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  link public.incident_units;
  inc public.incidents;
  m public.guest_logistics_movements;
  held integer:=0;
  resumed integer:=0;
begin
  select * into inc from public.incidents where id=p_incident_id;
  if inc.id is null then raise exception 'Incident not found'; end if;
  if not public.can_dispatch_event(inc.event_id) then
    raise exception 'Dispatcher access required';
  end if;
  if inc.status<>'OPEN' then raise exception 'Incident is not open'; end if;

  select * into link
  from public.incident_units
  where incident_id=p_incident_id and unit_id=p_unit_id and cleared_at is null
  for update;
  if link.id is null then
    raise exception 'Unit is not currently assigned to this incident';
  end if;

  if p_enabled then
    -- Only one CAD ticket can hold priority for a unit at a time.
    update public.incident_units
    set cad_priority_override=false
    where unit_id=p_unit_id and cleared_at is null and id<>link.id and cad_priority_override=true;

    update public.incident_units
    set cad_priority_override=true,
        cad_priority_set_at=now(),
        cad_priority_set_by=auth.uid(),
        cad_priority_acknowledged_at=null,
        cad_priority_acknowledged_by=null
    where id=link.id;

    if p_hold_movements then
      for m in
        select * from public.guest_logistics_movements
        where assigned_unit_id=p_unit_id
          and status not in ('HELD','COMPLETE','NO_SHOW','CANCELLED')
        for update
      loop
        update public.guest_logistics_movements
        set held_from_status=m.status,
            held_at=now(),
            held_by_incident_id=p_incident_id,
            held_by=auth.uid(),
            status='HELD',
            updated_at=now()
        where id=m.id;

        insert into public.guest_logistics_activity(event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind)
        values(m.event_id,m.id,m.assigned_unit_id,'MOVEMENT_HELD',
          jsonb_build_object('from',m.status,'to','HELD','incident_id',p_incident_id,'incident_number',inc.incident_number),
          auth.uid(),'staff');
        held:=held+1;
      end loop;
    end if;

    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,'CAD_PRIORITY_SET',
      jsonb_build_object('movements_held',held,'hold_requested',p_hold_movements),auth.uid(),'staff');
  else
    resumed:=private.guest_logistics_resume_held_for_incident(p_incident_id,p_unit_id,'staff');

    update public.incident_units
    set cad_priority_override=false,
        cad_priority_acknowledged_at=null,
        cad_priority_acknowledged_by=null
    where id=link.id;

    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,'CAD_PRIORITY_CLEARED',
      jsonb_build_object('movements_resumed',resumed),auth.uid(),'staff');
  end if;

  return jsonb_build_object('enabled',p_enabled,'movements_held',held,'movements_resumed',resumed);
end;
$$;

revoke all on function public.dispatch_set_cad_priority(uuid,uuid,boolean,boolean) from public;
grant execute on function public.dispatch_set_cad_priority(uuid,uuid,boolean,boolean) to authenticated;

-- Manual resume of a single HELD MOVE (staff), e.g. after reassigning it.
create or replace function public.guest_logistics_resume_movement(p_movement_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
  target text;
begin
  select * into m from public.guest_logistics_movements where id=p_movement_id for update;
  if m.id is null then raise exception 'Movement not found'; end if;
  if not private.guest_logistics_staff_access(m.event_id,m.department_id) then
    raise exception 'Not authorized for this guest movement';
  end if;
  if m.status<>'HELD' then raise exception 'Movement is not on hold'; end if;

  target:=coalesce(m.held_from_status,'ASSIGNED');
  if target in ('HELD','COMPLETE','NO_SHOW','CANCELLED','EN_ROUTE_PICKUP','AT_PICKUP') then target:='ASSIGNED'; end if;
  if m.assigned_unit_id is null and target<>'SCHEDULED' and target<>'READY' then target:='SCHEDULED'; end if;

  update public.guest_logistics_movements
  set status=target,held_from_status=null,held_at=null,held_by_incident_id=null,held_by=null,updated_at=now()
  where id=m.id;

  insert into public.guest_logistics_activity(event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(m.event_id,m.id,m.assigned_unit_id,'MOVEMENT_RESUMED',
    jsonb_build_object('from','HELD','to',target,'incident_id',m.held_by_incident_id),auth.uid(),'staff');
end;
$$;

revoke all on function public.guest_logistics_resume_movement(uuid) from public;
grant execute on function public.guest_logistics_resume_movement(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5. Field RPC: driver acknowledges the priority change
-- ------------------------------------------------------------
create or replace function public.field_acknowledge_cad_priority(
  p_field_session_id uuid,
  p_incident_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions%rowtype;
  link public.incident_units%rowtype;
  ack_time timestamptz;
begin
  select * into fs
  from public.field_sessions
  where id=p_field_session_id and auth_user_id=auth.uid() and active=true
  for update;
  if fs.id is null or fs.unit_id is null then
    raise exception 'Active Field Unit session not found';
  end if;

  select * into link
  from public.incident_units
  where incident_id=p_incident_id and unit_id=fs.unit_id and cleared_at is null
  for update;
  if link.id is null then
    raise exception 'This unit is not currently assigned to that incident';
  end if;
  if not link.cad_priority_override then
    raise exception 'This assignment does not have a priority override';
  end if;

  if link.cad_priority_acknowledged_at is null then
    ack_time:=now();
    update public.incident_units
    set cad_priority_acknowledged_at=ack_time,cad_priority_acknowledged_by=auth.uid()
    where id=link.id;

    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(fs.event_id,p_incident_id,fs.unit_id,'CAD_PRIORITY_ACKNOWLEDGED',
      jsonb_build_object('field_session_id',fs.id),auth.uid(),'field');
  else
    ack_time:=link.cad_priority_acknowledged_at;
  end if;
  return ack_time;
end;
$$;

revoke all on function public.field_acknowledge_cad_priority(uuid,uuid) from public;
grant execute on function public.field_acknowledge_cad_priority(uuid,uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. MOVE status rules: HELD is entered only through the priority RPC;
--    from HELD a MOVE may only be cancelled (or resumed via the resume RPC).
-- ------------------------------------------------------------
create or replace function private.guest_logistics_block_held_transitions()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if old.status='HELD' and new.status<>'HELD'
     and new.status not in ('CANCELLED','COMPLETE','NO_SHOW')
     and new.held_by_incident_id is not null then
    raise exception 'Resume this MOVE before changing its status';
  end if;
  return new;
end;
$$;

drop trigger if exists guest_logistics_block_held_transitions on public.guest_logistics_movements;
create trigger guest_logistics_block_held_transitions
before update of status
on public.guest_logistics_movements
for each row
execute function private.guest_logistics_block_held_transitions();

-- ------------------------------------------------------------
-- 7. Authoritative task snapshot now carries priority state
-- ------------------------------------------------------------
drop function if exists public.dispatch_task_status_snapshot(uuid);

create function public.dispatch_task_status_snapshot(
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
  updated_at timestamptz,
  priority_override boolean,
  priority_acknowledged_at timestamptz,
  held_from_status text,
  held_by_incident_id uuid
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
    coalesce(iu.cad_status_updated_at,iu.assigned_at),
    iu.cad_priority_override,
    iu.cad_priority_acknowledged_at,
    null::text,
    null::uuid
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
    m.updated_at,
    false,
    null::timestamptz,
    m.held_from_status,
    m.held_by_incident_id
  from public.guest_logistics_movements m
  where m.event_id=p_event_id
    and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')

  order by 1,2,3,4;
end;
$$;

revoke all on function public.dispatch_task_status_snapshot(uuid) from public;
grant execute on function public.dispatch_task_status_snapshot(uuid) to authenticated;

alter table public.incident_units replica identity full;
