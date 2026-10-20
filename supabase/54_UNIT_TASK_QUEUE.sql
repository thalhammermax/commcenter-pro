-- CommCenter Pro v0.19.0
-- Per-unit task queue. A unit may hold any number of tickets (CAD or MOVE).
-- Position 1 is the CURRENT task and drives units.status; the rest wait in
-- order. New assignments append to the end. Only Dispatch reorders. When the
-- current ticket closes or is cleared, the next one becomes current and the
-- driver must acknowledge it.
--
-- Replaces the CAD-vs-MOVE primary/secondary rule from v0.18.0. Run against a
-- v0.18.0 database. Do not rerun 01_FULL_SCHEMA.sql.

alter table public.incident_units
  add column if not exists queue_position integer;

create index if not exists incident_units_unit_queue_idx
  on public.incident_units(unit_id,queue_position) where cleared_at is null;

-- ------------------------------------------------------------
-- 1. Queue normalization: active tickets first (by position), then scheduled
--    MOVEs by pickup time. is_primary is derived (position 1).
-- ------------------------------------------------------------
create or replace function private.normalize_unit_queue(p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  pos integer:=0;
  previous_current uuid;
begin
  -- Includes a link that was just cleared (it still carries the flag), so a
  -- close/clear correctly promotes and re-alerts the next ticket.
  select iu.id into previous_current
  from public.incident_units iu
  where iu.unit_id=p_unit_id and iu.is_primary
  order by iu.cleared_at nulls first limit 1;

  update public.incident_units set is_primary=false,queue_position=null
  where unit_id=p_unit_id and cleared_at is not null and (is_primary or queue_position is not null);

  for r in
    select iu.id,iu.acknowledged_at
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.unit_id=p_unit_id and iu.cleared_at is null and i.status in ('OPEN','SCHEDULED')
    order by (i.status='OPEN') desc,
             coalesce(iu.queue_position,999999),
             i.scheduled_at nulls last,
             iu.assigned_at
  loop
    pos:=pos+1;
    update public.incident_units
    set queue_position=pos,
        is_primary=(pos=1)
    where id=r.id and (queue_position is distinct from pos or is_primary is distinct from (pos=1));

    -- A ticket that just became current needs a fresh acknowledgement so the
    -- driver is alerted that it is now their active task.
    if pos=1 and (previous_current is null or previous_current<>r.id) and previous_current is not null then
      update public.incident_units
      set primary_set_at=now(),primary_acknowledged_at=null,acknowledged_at=null,acknowledged_by=null
      where id=r.id;
    end if;
  end loop;
end;
$$;
revoke all on function private.normalize_unit_queue(uuid) from public;

-- Backfill: current (is_primary) first, then by assignment time.
do $$
declare u record;
begin
  update public.incident_units iu
  set queue_position=sub.rn
  from (
    select id,row_number() over (partition by unit_id order by is_primary desc,assigned_at) as rn
    from public.incident_units where cleared_at is null
  ) sub
  where iu.id=sub.id and iu.queue_position is null;
  for u in select distinct unit_id from public.incident_units where cleared_at is null loop
    perform private.normalize_unit_queue(u.unit_id);
  end loop;
end $$;

-- Replaces the v0.18 promote trigger: any clear renormalizes the queue.
drop trigger if exists promote_remaining_primary_assignment on public.incident_units;
drop function if exists private.promote_remaining_primary_assignment();

create or replace function private.renormalize_queue_on_clear()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.cleared_at is not null and old.cleared_at is null then
    perform private.normalize_unit_queue(new.unit_id);
  end if;
  return null;
end;
$$;
drop trigger if exists renormalize_queue_on_clear on public.incident_units;
create trigger renormalize_queue_on_clear
after update of cleared_at on public.incident_units
for each row execute function private.renormalize_queue_on_clear();

-- ------------------------------------------------------------
-- 2. units.status mirrors the CURRENT task (position 1, OPEN incident)
-- ------------------------------------------------------------
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
      where iu.unit_id=p_unit_id and iu.cleared_at is null and i.status='OPEN'
      order by coalesce(iu.queue_position,999999),iu.assigned_at desc
      limit 1
    ),
    p_fallback
  );
$$;

-- ------------------------------------------------------------
-- 3. assign_unit: append to the unit's queue (any number of tickets)
-- ------------------------------------------------------------
create or replace function public.assign_unit(p_incident_id uuid,p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  old_s text;
  effective_status text;
  next_pos integer;
begin
  select * into inc from public.incidents where id=p_incident_id and status in ('OPEN','SCHEDULED');
  if inc.id is null then raise exception 'Incident not found or is already closed'; end if;
  if not public.can_dispatch_event(inc.event_id) then raise exception 'Dispatch access required'; end if;
  if not exists(select 1 from public.units where id=p_unit_id and event_id=inc.event_id and active=true) then
    raise exception 'Unit is not an active unit in this event';
  end if;

  select coalesce(max(queue_position),0)+1 into next_pos
  from public.incident_units where unit_id=p_unit_id and cleared_at is null;

  select status into old_s from public.units where id=p_unit_id;

  insert into public.incident_units(incident_id,unit_id,queue_position,is_primary,primary_set_at)
  values(p_incident_id,p_unit_id,next_pos,next_pos=1,case when next_pos=1 then now() end)
  on conflict(incident_id,unit_id)
  do update set assigned_at=now(),cleared_at=null,queue_position=excluded.queue_position,is_primary=excluded.is_primary,primary_set_at=excluded.primary_set_at,primary_acknowledged_at=null;

  perform private.normalize_unit_queue(p_unit_id);

  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,case when inc.status='OPEN' then 'ASSIGNED' else coalesce(old_s,'AVAILABLE') end);
  update public.units set status=effective_status where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,old_s,effective_status,auth.uid(),'staff');
  end if;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,p_incident_id,p_unit_id,'UNIT_ASSIGNED',
    jsonb_build_object('incident_kind',inc.incident_kind,'queue_position',(select queue_position from public.incident_units where incident_id=p_incident_id and unit_id=p_unit_id),'scheduled',inc.status='SCHEDULED'),
    auth.uid(),'staff');
end;
$$;

-- ------------------------------------------------------------
-- 4. Reordering (Dispatch only)
-- ------------------------------------------------------------
create or replace function public.dispatch_set_unit_queue_position(
  p_incident_id uuid,
  p_unit_id uuid,
  p_position integer
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  link public.incident_units;
  old_s text;
  effective_status text;
  target integer;
  r record;
  pos integer:=0;
  was_current uuid;
begin
  select * into inc from public.incidents where id=p_incident_id;
  if inc.id is null then raise exception 'Incident not found'; end if;
  if not public.can_dispatch_event(inc.event_id) then raise exception 'Dispatcher access required'; end if;
  select * into link from public.incident_units where incident_id=p_incident_id and unit_id=p_unit_id and cleared_at is null for update;
  if link.id is null then raise exception 'Unit is not currently assigned to this incident'; end if;
  if inc.status='SCHEDULED' and coalesce(p_position,1)=1 then
    raise exception 'Activate the scheduled MOVE before making it the current task';
  end if;

  target:=greatest(1,coalesce(p_position,1));
  select id into was_current from public.incident_units where unit_id=p_unit_id and cleared_at is null and is_primary limit 1;

  -- Rebuild positions with the target link inserted at the requested slot.
  for r in
    select iu.id from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.unit_id=p_unit_id and iu.cleared_at is null and iu.id<>link.id
    order by (i.status='OPEN') desc,coalesce(iu.queue_position,999999),i.scheduled_at nulls last,iu.assigned_at
  loop
    pos:=pos+1;
    if pos=target then
      update public.incident_units set queue_position=pos where id=link.id;
      pos:=pos+1;
    end if;
    update public.incident_units set queue_position=pos where id=r.id;
  end loop;
  if pos<target then
    update public.incident_units set queue_position=pos+1 where id=link.id;
  end if;

  perform private.normalize_unit_queue(p_unit_id);

  if target=1 and (was_current is null or was_current<>link.id) then
    update public.incident_units set primary_set_by=auth.uid(),primary_set_at=now(),primary_acknowledged_at=null,acknowledged_at=null,acknowledged_by=null where id=link.id;
  end if;

  select status into old_s from public.units where id=p_unit_id;
  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,coalesce(old_s,'AVAILABLE'));
  update public.units set status=effective_status where id=p_unit_id;
  if old_s is distinct from effective_status then
    insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,old_s,effective_status,auth.uid(),'staff');
  end if;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,p_incident_id,p_unit_id,'UNIT_QUEUE_REORDERED',
    jsonb_build_object('incident_number',inc.incident_number,'queue_position',(select queue_position from public.incident_units where id=link.id),'made_current',target=1),
    auth.uid(),'staff');
end;
$$;
revoke all on function public.dispatch_set_unit_queue_position(uuid,uuid,integer) from public;
grant execute on function public.dispatch_set_unit_queue_position(uuid,uuid,integer) to authenticated;

-- v0.18 entry point kept as a wrapper.
create or replace function public.dispatch_set_primary_assignment(p_incident_id uuid,p_unit_id uuid)
returns void language sql security definer set search_path=public as $$
  select public.dispatch_set_unit_queue_position(p_incident_id,p_unit_id,1);
$$;

-- ------------------------------------------------------------
-- 5. Activation keeps the queue consistent (active tickets ahead of scheduled)
-- ------------------------------------------------------------
create or replace function private.activate_incident(p_incident_id uuid,p_actor_kind text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  active_op uuid;
  unit_rec record;
  effective_status text;
begin
  select * into inc from public.incidents where id=p_incident_id and status='SCHEDULED' for update;
  if inc.id is null then return false; end if;
  select id into active_op from public.operational_periods where event_id=inc.event_id and status='ACTIVE' limit 1;

  update public.incidents
  set status='OPEN',activated_at=now(),operational_period_id=coalesce(active_op,operational_period_id)
  where id=inc.id;

  for unit_rec in
    select u.id as unit_id,u.status from public.incident_units iu join public.units u on u.id=iu.unit_id
    where iu.incident_id=inc.id and iu.cleared_at is null
  loop
    -- The MOVE joins the end of the unit's active queue; it only becomes
    -- current if the unit had nothing else active.
    update public.incident_units iu
    set queue_position=(select coalesce(max(o.queue_position),0)+1 from public.incident_units o join public.incidents oi on oi.id=o.incident_id where o.unit_id=unit_rec.unit_id and o.cleared_at is null and oi.status='OPEN' and o.id<>iu.id)
    where iu.incident_id=inc.id and iu.unit_id=unit_rec.unit_id and iu.cleared_at is null;
    perform private.normalize_unit_queue(unit_rec.unit_id);

    effective_status:=private.guest_logistics_primary_unit_status(unit_rec.unit_id,'ASSIGNED');
    update public.units set status=effective_status where id=unit_rec.unit_id;
    if unit_rec.status is distinct from effective_status then
      insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
      values(inc.event_id,inc.id,unit_rec.unit_id,unit_rec.status,effective_status,auth.uid(),case when p_actor_kind='field' then 'field' else 'staff' end);
    end if;
  end loop;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,inc.id,'MOVE_ACTIVATED',jsonb_build_object('scheduled_at',inc.scheduled_at,'automatic',p_actor_kind='system'),auth.uid(),p_actor_kind);
  return true;
end;
$$;

-- ------------------------------------------------------------
-- 6. Snapshot carries the queue position
-- ------------------------------------------------------------
drop function if exists public.dispatch_task_status_snapshot(uuid);
create function public.dispatch_task_status_snapshot(p_event_id uuid)
returns table(
  task_kind text,incident_id uuid,movement_id uuid,unit_id uuid,status text,
  assigned_at timestamptz,acknowledged_at timestamptz,updated_at timestamptz,
  is_primary boolean,primary_acknowledged_at timestamptz,incident_status text,queue_position integer
)
language plpgsql security definer set search_path=public as $$
begin
  if p_event_id is null then raise exception 'Event is required'; end if;
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatcher access required'; end if;
  return query
  select i.incident_kind::text,iu.incident_id,null::uuid,iu.unit_id,coalesce(iu.cad_status,'ASSIGNED')::text,
    iu.assigned_at,iu.acknowledged_at,coalesce(iu.cad_status_updated_at,iu.assigned_at),
    iu.is_primary,iu.primary_acknowledged_at,i.status::text,iu.queue_position
  from public.incident_units iu join public.incidents i on i.id=iu.incident_id
  where i.event_id=p_event_id and i.status in ('OPEN','SCHEDULED') and iu.cleared_at is null
  order by 4,12;
end;
$$;
revoke all on function public.dispatch_task_status_snapshot(uuid) from public;
grant execute on function public.dispatch_task_status_snapshot(uuid) to authenticated;
