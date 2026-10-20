-- CommCenter Pro v0.18.0
-- Guest Logistics MOVEs become CAD incidents of kind 'MOVE'.
--
-- One status engine, one assignment path, one acknowledgement flow, one audit
-- log, one report pipeline. A unit may hold one CAD ticket and one MOVE ticket
-- at the same time; exactly one of them is the unit's PRIMARY task. The MOVE is
-- primary by default; Dispatch can promote the CAD ticket. When the primary
-- ticket closes or the unit is cleared, the remaining ticket becomes primary
-- automatically.
--
-- Run against a v0.16.0 database (migration 52 is NOT required and should not
-- be run). Do not rerun 01_FULL_SCHEMA.sql. The legacy guest_logistics_*
-- tables are kept for history; existing MOVEs are converted into incidents.

-- ------------------------------------------------------------
-- 1. incidents: kind, scheduling, status SCHEDULED
-- ------------------------------------------------------------
alter table public.incidents
  add column if not exists incident_kind text not null default 'CAD',
  add column if not exists scheduled_at timestamptz,
  add column if not exists activate_lead_minutes integer not null default 60,
  add column if not exists activated_at timestamptz,
  add column if not exists legacy_movement_id uuid;

alter table public.incidents drop constraint if exists incidents_incident_kind_check;
alter table public.incidents
  add constraint incidents_incident_kind_check check(incident_kind in ('CAD','MOVE'));

alter table public.incidents drop constraint if exists incidents_status_check;
alter table public.incidents
  add constraint incidents_status_check check(status in ('SCHEDULED','OPEN','CLOSED'));

create index if not exists incidents_event_kind_status_sched_idx
  on public.incidents(event_id,incident_kind,status,scheduled_at);

alter table public.events
  add column if not exists move_sequence integer not null default 1,
  add column if not exists move_prefix text not null default 'M';

-- ------------------------------------------------------------
-- 2. Guest details (1:1 with a MOVE incident)
-- ------------------------------------------------------------
create table if not exists public.incident_guest_details (
  incident_id uuid primary key references public.incidents(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  movement_type text not null default 'OTHER'
    check(movement_type in ('AIRPORT_ARRIVAL','AIRPORT_DEPARTURE','HOTEL_TRANSFER','VENUE_TRANSFER','LOCAL_TRANSFER','OTHER')),
  guest_name text not null,
  guest_group text,
  party_size integer not null default 1 check(party_size>=1 and party_size<=500),
  contact_phone text,
  contact_email text,
  origin text not null,
  destination text not null,
  airline text,
  flight_number text,
  airport text,
  terminal text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists incident_guest_details_event_idx on public.incident_guest_details(event_id);

alter table public.incident_guest_details enable row level security;

drop policy if exists incident_guest_details_read on public.incident_guest_details;
create policy incident_guest_details_read
on public.incident_guest_details
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or private.field_can_read_incident(incident_id)
  or private.command_has_event_access(event_id)
);

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='incident_guest_details') then
    alter publication supabase_realtime add table public.incident_guest_details;
  end if;
end $$;

-- ------------------------------------------------------------
-- 3. incident_units: primary task flag + driver acknowledgement of a change
-- ------------------------------------------------------------
alter table public.incident_units
  add column if not exists is_primary boolean not null default false,
  add column if not exists primary_set_at timestamptz,
  add column if not exists primary_set_by uuid references auth.users(id) on delete set null,
  add column if not exists primary_acknowledged_at timestamptz;

create index if not exists incident_units_unit_primary_idx
  on public.incident_units(unit_id) where cleared_at is null and is_primary=true;

alter table public.incident_units replica identity full;

-- Every existing open assignment is the unit's only one: mark primary.
update public.incident_units iu
set is_primary=true
where iu.cleared_at is null
  and not exists(
    select 1 from public.incident_units o
    where o.unit_id=iu.unit_id and o.cleared_at is null and o.id<>iu.id and o.is_primary
  );

-- ------------------------------------------------------------
-- 4. MOVE dispositions
-- ------------------------------------------------------------
alter table public.event_dispositions drop constraint if exists event_dispositions_scope_check;
alter table public.event_dispositions
  add constraint event_dispositions_scope_check check(scope in ('GENERAL','EMS','MOVE'));

create or replace function private.seed_move_dispositions(p_event_id uuid)
returns void
language sql
security definer
set search_path=public
as $$
  insert into public.event_dispositions(event_id,scope,code,label,sort_order)
  values
    (p_event_id,'MOVE','COMPLETE','Guest Delivered',10),
    (p_event_id,'MOVE','NO_SHOW','Guest No Show',20),
    (p_event_id,'MOVE','CANCELLED','Movement Cancelled',30),
    (p_event_id,'MOVE','REASSIGNED','Handled by Other Transport',40)
  on conflict(event_id,scope,code) do nothing;
$$;
revoke all on function private.seed_move_dispositions(uuid) from public;

select private.seed_move_dispositions(e.id) from public.events e;

create or replace function private.seed_move_dispositions_on_event()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform private.seed_move_dispositions(new.id);
  return new;
end;
$$;
drop trigger if exists seed_move_dispositions_on_event on public.events;
create trigger seed_move_dispositions_on_event
after insert on public.events for each row execute function private.seed_move_dispositions_on_event();

-- ------------------------------------------------------------
-- 5. The unit-status hook: units.status mirrors the PRIMARY open assignment.
--    Every assign/status/unassign/close RPC already calls this.
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
      where iu.unit_id=p_unit_id
        and iu.cleared_at is null
        and i.status='OPEN'
      order by iu.is_primary desc,
               (i.incident_kind='MOVE') desc,
               iu.assigned_at desc
      limit 1
    ),
    p_fallback
  );
$$;

-- Auto-promote the remaining open assignment when the primary one clears.
create or replace function private.promote_remaining_primary_assignment()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  next_id uuid;
begin
  if new.cleared_at is not null and old.cleared_at is null then
    if not exists(select 1 from public.incident_units o where o.unit_id=new.unit_id and o.cleared_at is null and o.is_primary) then
      select o.id into next_id
      from public.incident_units o
      join public.incidents i on i.id=o.incident_id
      where o.unit_id=new.unit_id and o.cleared_at is null
      order by (i.incident_kind='MOVE') desc, o.assigned_at desc
      limit 1;
      if next_id is not null then
        update public.incident_units set is_primary=true,primary_set_at=now(),primary_acknowledged_at=null where id=next_id;
      end if;
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists promote_remaining_primary_assignment on public.incident_units;
create trigger promote_remaining_primary_assignment
after update of cleared_at on public.incident_units
for each row execute function private.promote_remaining_primary_assignment();

-- ------------------------------------------------------------
-- 6. assign_unit: one CAD ticket + one MOVE ticket per unit
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
  other_incident text;
  effective_status text;
  has_other boolean;
  make_primary boolean;
begin
  select * into inc from public.incidents where id=p_incident_id and status in ('OPEN','SCHEDULED');
  if inc.id is null then
    raise exception 'Incident not found or is already closed';
  end if;
  if not public.can_dispatch_event(inc.event_id) then
    raise exception 'Dispatch access required';
  end if;
  if not exists(select 1 from public.units where id=p_unit_id and event_id=inc.event_id and active=true) then
    raise exception 'Unit is not an active unit in this event';
  end if;

  -- A unit may hold at most one ticket of each kind. A second MOVE for the same
  -- driver stays SCHEDULED and unassigned until the first completes, except that
  -- scheduled (not yet active) MOVEs may be queued freely.
  select i.incident_number into other_incident
  from public.incident_units iu
  join public.incidents i on i.id=iu.incident_id
  where iu.unit_id=p_unit_id
    and iu.cleared_at is null
    and i.status='OPEN'
    and i.id<>p_incident_id
    and i.incident_kind=inc.incident_kind
    and inc.status='OPEN'
  order by iu.assigned_at desc
  limit 1;
  if other_incident is not null then
    raise exception 'Unit is already working % %',case when inc.incident_kind='MOVE' then 'MOVE' else 'ticket' end,other_incident;
  end if;

  select exists(
    select 1 from public.incident_units iu join public.incidents i on i.id=iu.incident_id
    where iu.unit_id=p_unit_id and iu.cleared_at is null and i.status='OPEN'
  ) into has_other;

  -- Default rule: a MOVE is the primary task; a CAD ticket added to a MOVE
  -- unit is secondary. A scheduled MOVE never takes priority until active.
  make_primary:=(not has_other) or (inc.incident_kind='MOVE' and inc.status='OPEN');
  if inc.status='SCHEDULED' then make_primary:=not has_other; end if;

  if make_primary then
    update public.incident_units set is_primary=false where unit_id=p_unit_id and cleared_at is null and is_primary;
  end if;

  select status into old_s from public.units where id=p_unit_id;

  insert into public.incident_units(incident_id,unit_id,is_primary,primary_set_at)
  values(p_incident_id,p_unit_id,make_primary,case when make_primary then now() end)
  on conflict(incident_id,unit_id)
  do update set assigned_at=now(),cleared_at=null,is_primary=excluded.is_primary,primary_set_at=excluded.primary_set_at,primary_acknowledged_at=null;

  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,case when inc.status='OPEN' then 'ASSIGNED' else coalesce(old_s,'AVAILABLE') end);

  update public.units set status=effective_status where id=p_unit_id;

  if old_s is distinct from effective_status then
    insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,old_s,effective_status,auth.uid(),'staff');
  end if;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,p_incident_id,p_unit_id,'UNIT_ASSIGNED',
    jsonb_build_object('incident_kind',inc.incident_kind,'primary',make_primary,'scheduled',inc.status='SCHEDULED'),auth.uid(),'staff');
end;
$$;

-- ------------------------------------------------------------
-- 7. Primary task control
-- ------------------------------------------------------------
create or replace function public.dispatch_set_primary_assignment(
  p_incident_id uuid,
  p_unit_id uuid
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
begin
  select * into inc from public.incidents where id=p_incident_id;
  if inc.id is null then raise exception 'Incident not found'; end if;
  if not public.can_dispatch_event(inc.event_id) then raise exception 'Dispatcher access required'; end if;
  if inc.status<>'OPEN' then raise exception 'Only an active ticket can be the primary task'; end if;

  select * into link from public.incident_units where incident_id=p_incident_id and unit_id=p_unit_id and cleared_at is null for update;
  if link.id is null then raise exception 'Unit is not currently assigned to this incident'; end if;
  if link.is_primary then return; end if;

  update public.incident_units set is_primary=false where unit_id=p_unit_id and cleared_at is null and is_primary;
  update public.incident_units
  set is_primary=true,primary_set_at=now(),primary_set_by=auth.uid(),primary_acknowledged_at=null
  where id=link.id;

  select status into old_s from public.units where id=p_unit_id;
  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,coalesce(old_s,'AVAILABLE'));
  update public.units set status=effective_status where id=p_unit_id;
  if old_s is distinct from effective_status then
    insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
    values(inc.event_id,p_incident_id,p_unit_id,old_s,effective_status,auth.uid(),'staff');
  end if;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,p_incident_id,p_unit_id,'PRIMARY_TASK_SET',
    jsonb_build_object('incident_kind',inc.incident_kind,'incident_number',inc.incident_number),auth.uid(),'staff');
end;
$$;
revoke all on function public.dispatch_set_primary_assignment(uuid,uuid) from public;
grant execute on function public.dispatch_set_primary_assignment(uuid,uuid) to authenticated;

create or replace function public.field_acknowledge_primary_change(
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
  ack timestamptz;
begin
  select * into fs from public.field_sessions where id=p_field_session_id and auth_user_id=auth.uid() and active=true for update;
  if fs.id is null or fs.unit_id is null then raise exception 'Active Field Unit session not found'; end if;
  select * into link from public.incident_units where incident_id=p_incident_id and unit_id=fs.unit_id and cleared_at is null for update;
  if link.id is null then raise exception 'This unit is not currently assigned to that incident'; end if;
  if not link.is_primary then raise exception 'This ticket is not the primary task'; end if;
  if link.primary_acknowledged_at is null then
    ack:=now();
    update public.incident_units set primary_acknowledged_at=ack where id=link.id;
    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(fs.event_id,p_incident_id,fs.unit_id,'PRIMARY_TASK_ACKNOWLEDGED',jsonb_build_object('field_session_id',fs.id),auth.uid(),'field');
  else
    ack:=link.primary_acknowledged_at;
  end if;
  return ack;
end;
$$;
revoke all on function public.field_acknowledge_primary_change(uuid,uuid) from public;
grant execute on function public.field_acknowledge_primary_change(uuid,uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. MOVE creation / editing
-- ------------------------------------------------------------
create or replace function private.next_move_number(p_event_id uuid)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
begin
  select * into e from public.events where id=p_event_id for update;
  update public.events set move_sequence=e.move_sequence+1 where id=p_event_id;
  return e.move_prefix||'-'||lpad(e.move_sequence::text,3,'0');
end;
$$;
revoke all on function private.next_move_number(uuid) from public;

create or replace function public.create_move_incident(
  p_event_id uuid,
  p_department_id uuid,
  p_scheduled_at timestamptz,
  p_guest jsonb,
  p_notes text default null,
  p_priority text default 'Standard',
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_map_x double precision default null,
  p_map_y double precision default null,
  p_activate_lead_minutes integer default 60,
  p_assign_unit_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  iid uuid;
  number_value text;
  guest_name_value text;
  origin_value text;
  destination_value text;
  due boolean;
  active_op uuid;
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if not exists(select 1 from public.event_departments d where d.id=p_department_id and d.event_id=p_event_id and d.active=true and d.guest_logistics_enabled=true) then
    raise exception 'Department is not an active Guest Logistics department';
  end if;
  if p_scheduled_at is null then raise exception 'Scheduled pickup time is required'; end if;

  guest_name_value:=nullif(trim(coalesce(p_guest->>'guest_name','')),'');
  origin_value:=nullif(trim(coalesce(p_guest->>'origin','')),'');
  destination_value:=nullif(trim(coalesce(p_guest->>'destination','')),'');
  if guest_name_value is null then raise exception 'Guest name is required'; end if;
  if origin_value is null or destination_value is null then raise exception 'Pickup and destination are required'; end if;

  number_value:=private.next_move_number(p_event_id);
  due:=(p_scheduled_at - make_interval(mins=>coalesce(p_activate_lead_minutes,60)))<=now();
  select id into active_op from public.operational_periods where event_id=p_event_id and status='ACTIVE' limit 1;

  insert into public.incidents(
    event_id,operational_period_id,incident_number,incident_kind,call_type,priority,status,
    poi_id,map_layer_id,zone_id,latitude,longitude,map_x,map_y,landmark,notes,
    scheduled_at,activate_lead_minutes,activated_at,created_by
  ) values(
    p_event_id,case when due then active_op end,number_value,'MOVE',
    coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),'OTHER')||' · '||guest_name_value,
    coalesce(nullif(trim(coalesce(p_priority,'')),''),'Standard'),
    case when due then 'OPEN' else 'SCHEDULED' end,
    p_poi_id,p_map_layer_id,p_zone_id,p_latitude,p_longitude,p_map_x,p_map_y,
    origin_value,p_notes,
    p_scheduled_at,coalesce(p_activate_lead_minutes,60),case when due then now() end,auth.uid()
  ) returning id into iid;

  insert into public.incident_departments(incident_id,department_id) values(iid,p_department_id);

  insert into public.incident_guest_details(
    incident_id,event_id,movement_type,guest_name,guest_group,party_size,contact_phone,contact_email,
    origin,destination,airline,flight_number,airport,terminal
  ) values(
    iid,p_event_id,
    coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),'OTHER'),
    guest_name_value,
    nullif(trim(coalesce(p_guest->>'guest_group','')),''),
    greatest(1,least(500,coalesce((p_guest->>'party_size')::integer,1))),
    nullif(trim(coalesce(p_guest->>'contact_phone','')),''),
    nullif(trim(coalesce(p_guest->>'contact_email','')),''),
    origin_value,destination_value,
    nullif(trim(coalesce(p_guest->>'airline','')),''),
    nullif(trim(coalesce(p_guest->>'flight_number','')),''),
    nullif(trim(coalesce(p_guest->>'airport','')),''),
    nullif(trim(coalesce(p_guest->>'terminal','')),'')
  );

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,iid,'MOVE_CREATED',jsonb_build_object('scheduled_at',p_scheduled_at,'guest_name',guest_name_value,'status',case when due then 'OPEN' else 'SCHEDULED' end),auth.uid(),'staff');

  if p_assign_unit_id is not null then
    perform public.assign_unit(iid,p_assign_unit_id);
  end if;
  return iid;
end;
$$;
revoke all on function public.create_move_incident(uuid,uuid,timestamptz,jsonb,text,text,uuid,uuid,uuid,double precision,double precision,double precision,double precision,integer,uuid) from public;
grant execute on function public.create_move_incident(uuid,uuid,timestamptz,jsonb,text,text,uuid,uuid,uuid,double precision,double precision,double precision,double precision,integer,uuid) to authenticated;

create or replace function public.update_move_incident(
  p_incident_id uuid,
  p_scheduled_at timestamptz,
  p_guest jsonb,
  p_notes text default null,
  p_priority text default null,
  p_department_id uuid default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  guest_name_value text;
begin
  select * into inc from public.incidents where id=p_incident_id and incident_kind='MOVE' for update;
  if inc.id is null then raise exception 'MOVE not found'; end if;
  if not public.can_dispatch_event(inc.event_id) then raise exception 'Dispatch access required'; end if;
  if inc.status='CLOSED' then raise exception 'MOVE is closed'; end if;
  guest_name_value:=nullif(trim(coalesce(p_guest->>'guest_name','')),'');
  if guest_name_value is null then raise exception 'Guest name is required'; end if;

  update public.incident_guest_details g
  set movement_type=coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),g.movement_type),
      guest_name=guest_name_value,
      guest_group=nullif(trim(coalesce(p_guest->>'guest_group','')),''),
      party_size=greatest(1,least(500,coalesce((p_guest->>'party_size')::integer,g.party_size))),
      contact_phone=nullif(trim(coalesce(p_guest->>'contact_phone','')),''),
      contact_email=nullif(trim(coalesce(p_guest->>'contact_email','')),''),
      origin=coalesce(nullif(trim(coalesce(p_guest->>'origin','')),''),g.origin),
      destination=coalesce(nullif(trim(coalesce(p_guest->>'destination','')),''),g.destination),
      airline=nullif(trim(coalesce(p_guest->>'airline','')),''),
      flight_number=nullif(trim(coalesce(p_guest->>'flight_number','')),''),
      airport=nullif(trim(coalesce(p_guest->>'airport','')),''),
      terminal=nullif(trim(coalesce(p_guest->>'terminal','')),''),
      updated_at=now()
  where g.incident_id=inc.id;

  update public.incidents
  set scheduled_at=coalesce(p_scheduled_at,scheduled_at),
      notes=coalesce(p_notes,notes),
      priority=coalesce(nullif(trim(coalesce(p_priority,'')),''),priority),
      call_type=coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),'OTHER')||' · '||guest_name_value,
      landmark=coalesce(nullif(trim(coalesce(p_guest->>'origin','')),''),landmark)
  where id=inc.id;

  if p_department_id is not null and p_department_id<>(select department_id from public.incident_departments where incident_id=inc.id limit 1) then
    if not exists(select 1 from public.event_departments d where d.id=p_department_id and d.event_id=inc.event_id and d.active=true and d.guest_logistics_enabled=true) then
      raise exception 'Department is not an active Guest Logistics department';
    end if;
    delete from public.incident_departments where incident_id=inc.id;
    insert into public.incident_departments(incident_id,department_id) values(inc.id,p_department_id);
  end if;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,inc.id,'MOVE_UPDATED',jsonb_build_object('scheduled_at',p_scheduled_at),auth.uid(),'staff');
end;
$$;
revoke all on function public.update_move_incident(uuid,timestamptz,jsonb,text,text,uuid) from public;
grant execute on function public.update_move_incident(uuid,timestamptz,jsonb,text,text,uuid) to authenticated;

-- ------------------------------------------------------------
-- 9. Activation (auto ~N minutes before pickup, or manual)
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

  -- Assigned drivers now carry an active ticket: refresh units.status and make
  -- the MOVE primary unless a CAD ticket was explicitly prioritized.
  for unit_rec in
    select iu.id as link_id,u.id as unit_id,u.status
    from public.incident_units iu join public.units u on u.id=iu.unit_id
    where iu.incident_id=inc.id and iu.cleared_at is null
  loop
    if not exists(select 1 from public.incident_units o join public.incidents oi on oi.id=o.incident_id
                  where o.unit_id=unit_rec.unit_id and o.cleared_at is null and o.is_primary and o.id<>unit_rec.link_id
                    and oi.status='OPEN' and o.primary_set_by is not null) then
      update public.incident_units set is_primary=false where unit_id=unit_rec.unit_id and cleared_at is null and is_primary and id<>unit_rec.link_id;
      update public.incident_units set is_primary=true,primary_set_at=coalesce(primary_set_at,now()) where id=unit_rec.link_id;
    end if;
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
revoke all on function private.activate_incident(uuid,text) from public;

create or replace function public.activate_due_move_incidents(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  n integer:=0;
begin
  if not (public.can_dispatch_event(p_event_id) or public.has_event_staff_access(p_event_id) or private.command_has_event_access(p_event_id)) then
    return 0;
  end if;
  for r in
    select id from public.incidents
    where event_id=p_event_id and incident_kind='MOVE' and status='SCHEDULED'
      and scheduled_at - make_interval(mins=>activate_lead_minutes)<=now()
    order by scheduled_at
  loop
    if private.activate_incident(r.id,'system') then n:=n+1; end if;
  end loop;
  return n;
end;
$$;
revoke all on function public.activate_due_move_incidents(uuid) from public;
grant execute on function public.activate_due_move_incidents(uuid) to authenticated;

create or replace function public.dispatch_activate_incident(p_incident_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare eid uuid;
begin
  select event_id into eid from public.incidents where id=p_incident_id;
  if eid is null then raise exception 'Incident not found'; end if;
  if not public.can_dispatch_event(eid) then raise exception 'Dispatch access required'; end if;
  if not private.activate_incident(p_incident_id,'staff') then raise exception 'Incident is not scheduled'; end if;
end;
$$;
revoke all on function public.dispatch_activate_incident(uuid) from public;
grant execute on function public.dispatch_activate_incident(uuid) to authenticated;

-- ------------------------------------------------------------
-- 10. MOVE status engine (staff or the assigned Field Unit)
-- ------------------------------------------------------------
create or replace function public.close_move_incident(
  p_incident_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  code text;
  unit_rec record;
  effective_status text;
  actor_kind_value text;
  field_unit uuid;
  released integer:=0;
begin
  select * into inc from public.incidents where id=p_incident_id and incident_kind='MOVE' and status in ('OPEN','SCHEDULED') for update;
  if inc.id is null then raise exception 'Open MOVE not found'; end if;

  field_unit:=private.current_field_unit();
  if public.can_dispatch_event(inc.event_id) then actor_kind_value:='staff';
  elsif field_unit is not null and exists(select 1 from public.incident_units iu where iu.incident_id=inc.id and iu.unit_id=field_unit and iu.cleared_at is null) then actor_kind_value:='field';
  else raise exception 'Dispatch access or an active Field Unit assignment is required';
  end if;

  code:=upper(trim(coalesce(p_disposition,'')));
  if not exists(select 1 from public.event_dispositions d where d.event_id=inc.event_id and d.scope='MOVE' and d.code=code and d.active=true) then
    raise exception 'Choose a valid MOVE disposition';
  end if;

  for unit_rec in
    select u.id as unit_id,u.status from public.incident_units iu join public.units u on u.id=iu.unit_id
    where iu.incident_id=inc.id and iu.cleared_at is null
  loop
    update public.incident_units set cleared_at=now() where incident_id=inc.id and unit_id=unit_rec.unit_id and cleared_at is null;
    effective_status:=private.guest_logistics_primary_unit_status(unit_rec.unit_id,'AVAILABLE');
    update public.units set status=effective_status where id=unit_rec.unit_id;
    if unit_rec.status is distinct from effective_status then
      insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
      values(inc.event_id,inc.id,unit_rec.unit_id,unit_rec.status,effective_status,auth.uid(),actor_kind_value);
    end if;
    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(inc.event_id,inc.id,unit_rec.unit_id,'UNIT_UNASSIGNED',jsonb_build_object('new_status',effective_status,'reason','MOVE_CLOSED','automatic',true),auth.uid(),actor_kind_value);
    released:=released+1;
  end loop;

  update public.incidents set status='CLOSED',closed_at=now(),disposition=code where id=inc.id;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,inc.id,'INCIDENT_CLOSED',jsonb_build_object('disposition',code,'move_disposition',code,'released_units',released,'incident_kind','MOVE'),auth.uid(),actor_kind_value);
end;
$$;
revoke all on function public.close_move_incident(uuid,text) from public;
grant execute on function public.close_move_incident(uuid,text) to authenticated;

create or replace function public.set_move_status(
  p_incident_id uuid,
  p_unit_id uuid,
  p_status text,
  p_client_time timestamptz default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  inc public.incidents;
  link public.incident_units;
  target text;
  actor_kind_value text;
  field_unit uuid;
  old_s text;
  effective_status text;
  current_s text;
begin
  select * into inc from public.incidents where id=p_incident_id and incident_kind='MOVE' for update;
  if inc.id is null then raise exception 'MOVE not found'; end if;
  if inc.status='CLOSED' then raise exception 'MOVE is already closed'; end if;

  field_unit:=private.current_field_unit();
  if public.can_dispatch_event(inc.event_id) then actor_kind_value:='staff';
  elsif field_unit is not null and field_unit=p_unit_id then actor_kind_value:='field';
  else raise exception 'Not authorized for this MOVE';
  end if;

  select * into link from public.incident_units where incident_id=inc.id and unit_id=p_unit_id and cleared_at is null for update;
  if link.id is null then raise exception 'Unit is not assigned to this MOVE'; end if;

  target:=upper(trim(coalesce(p_status,'')));
  if target in ('COMPLETE','NO_SHOW','CANCELLED') then
    perform public.close_move_incident(inc.id,target);
    return;
  end if;
  if target not in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION') then
    raise exception 'Invalid MOVE status';
  end if;
  if actor_kind_value='field' and link.acknowledged_at is null then
    raise exception 'Acknowledge this MOVE before changing its status';
  end if;

  current_s:=coalesce(link.cad_status,'ASSIGNED');
  if target='EN_ROUTE_PICKUP' and current_s not in ('ASSIGNED') then raise exception 'Driver must start from Assigned'; end if;
  if target='AT_PICKUP' and current_s<>'EN_ROUTE_PICKUP' then raise exception 'Driver must be en route to pickup first'; end if;
  if target='PASSENGER_ONBOARD' and current_s<>'AT_PICKUP' then raise exception 'Driver must be at pickup first'; end if;
  if target='EN_ROUTE_DESTINATION' and current_s<>'PASSENGER_ONBOARD' then raise exception 'Guest must be on board first'; end if;

  if exists(select 1 from public.units u where u.id=p_unit_id and u.status='OUT_OF_SERVICE') then
    raise exception 'Driver unit is out of service';
  end if;

  -- A driver starting early activates the scheduled MOVE.
  if inc.status='SCHEDULED' then
    perform private.activate_incident(inc.id,actor_kind_value);
  end if;

  update public.incident_units set cad_status=target,cad_status_updated_at=now() where id=link.id;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(inc.event_id,inc.id,p_unit_id,'CAD_ASSIGNMENT_STATUS_CHANGED',jsonb_build_object('from',current_s,'to',target,'incident_kind','MOVE'),auth.uid(),actor_kind_value);

  select status into old_s from public.units where id=p_unit_id;
  effective_status:=private.guest_logistics_primary_unit_status(p_unit_id,target);
  update public.units set status=effective_status where id=p_unit_id;
  if old_s is distinct from effective_status then
    insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind,client_time)
    values(inc.event_id,inc.id,p_unit_id,old_s,effective_status,auth.uid(),actor_kind_value,p_client_time);
    insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
    values(inc.event_id,inc.id,p_unit_id,'UNIT_STATUS_CHANGED',jsonb_build_object('from',old_s,'to',effective_status),auth.uid(),actor_kind_value);
  end if;
end;
$$;
revoke all on function public.set_move_status(uuid,uuid,text,timestamptz) from public;
grant execute on function public.set_move_status(uuid,uuid,text,timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 11. Dispatch task snapshot: every open assignment (incl. scheduled MOVEs)
-- ------------------------------------------------------------
drop function if exists public.dispatch_task_status_snapshot(uuid);

create function public.dispatch_task_status_snapshot(p_event_id uuid)
returns table(
  task_kind text,
  incident_id uuid,
  movement_id uuid,
  unit_id uuid,
  status text,
  assigned_at timestamptz,
  acknowledged_at timestamptz,
  updated_at timestamptz,
  is_primary boolean,
  primary_acknowledged_at timestamptz,
  incident_status text
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_event_id is null then raise exception 'Event is required'; end if;
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatcher access required'; end if;
  return query
  select
    i.incident_kind::text,
    iu.incident_id,
    null::uuid,
    iu.unit_id,
    coalesce(iu.cad_status,'ASSIGNED')::text,
    iu.assigned_at,
    iu.acknowledged_at,
    coalesce(iu.cad_status_updated_at,iu.assigned_at),
    iu.is_primary,
    iu.primary_acknowledged_at,
    i.status::text
  from public.incident_units iu
  join public.incidents i on i.id=iu.incident_id
  where i.event_id=p_event_id and i.status in ('OPEN','SCHEDULED') and iu.cleared_at is null
  order by 1,2,4;
end;
$$;
revoke all on function public.dispatch_task_status_snapshot(uuid) from public;
grant execute on function public.dispatch_task_status_snapshot(uuid) to authenticated;

-- ------------------------------------------------------------
-- 12. Convert legacy Guest Logistics movements into MOVE incidents
-- ------------------------------------------------------------
do $$
declare
  m record;
  iid uuid;
  st text;
  cad text;
  active_op uuid;
  number_value text;
begin
  for m in
    select * from public.guest_logistics_movements
    where not exists(select 1 from public.incidents i where i.legacy_movement_id=guest_logistics_movements.id)
    order by scheduled_at
  loop
    st:=case when m.status in ('COMPLETE','NO_SHOW','CANCELLED') then 'CLOSED'
             when m.status in ('SCHEDULED','READY','ASSIGNED') and m.scheduled_at - interval '60 minutes'>now() then 'SCHEDULED'
             else 'OPEN' end;
    cad:=case when m.status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION') then m.status else 'ASSIGNED' end;
    select id into active_op from public.operational_periods where event_id=m.event_id and status='ACTIVE' limit 1;
    number_value:=coalesce(nullif(m.movement_number,''),private.next_move_number(m.event_id));
    if exists(select 1 from public.incidents i where i.event_id=m.event_id and i.incident_number=number_value) then
      number_value:=private.next_move_number(m.event_id);
    end if;

    insert into public.incidents(
      event_id,operational_period_id,incident_number,incident_kind,call_type,priority,status,
      latitude,longitude,landmark,notes,disposition,created_at,closed_at,
      scheduled_at,activated_at,legacy_movement_id,created_by
    ) values(
      m.event_id,coalesce(m.operational_period_id,case when st<>'SCHEDULED' then active_op end),number_value,'MOVE',
      m.movement_type||' · '||m.guest_name,'Standard',st,
      null,null,m.origin,m.notes,case when st='CLOSED' then m.status end,m.created_at,
      case when st='CLOSED' then coalesce(m.completed_at,m.no_show_at,m.cancelled_at,m.updated_at) end,
      m.scheduled_at,case when st='OPEN' then coalesce(m.en_route_pickup_at,m.assigned_at,now()) end,m.id,m.created_by
    ) returning id into iid;

    insert into public.incident_departments(incident_id,department_id) values(iid,m.department_id);

    insert into public.incident_guest_details(incident_id,event_id,movement_type,guest_name,guest_group,party_size,contact_phone,contact_email,origin,destination,airline,flight_number,airport,terminal)
    values(iid,m.event_id,m.movement_type,m.guest_name,m.guest_group,m.party_size,m.contact_phone,m.contact_email,m.origin,m.destination,m.airline,m.flight_number,m.airport,m.terminal);

    if m.assigned_unit_id is not null and st<>'CLOSED' then
      insert into public.incident_units(incident_id,unit_id,assigned_at,acknowledged_at,cad_status,cad_status_updated_at,is_primary,primary_set_at)
      values(iid,m.assigned_unit_id,coalesce(m.assigned_at,now()),m.driver_acknowledged_at,cad,m.updated_at,
             st='OPEN',case when st='OPEN' then now() end)
      on conflict(incident_id,unit_id) do nothing;
      -- The acknowledgement-reset trigger clears acknowledged_at on insert;
      -- restore the driver's existing acknowledgement.
      if m.driver_acknowledged_at is not null then
        update public.incident_units set acknowledged_at=m.driver_acknowledged_at where incident_id=iid and unit_id=m.assigned_unit_id;
      end if;
      if st='OPEN' then
        update public.incident_units set is_primary=false where unit_id=m.assigned_unit_id and cleared_at is null and incident_id<>iid;
        update public.units u set status=private.guest_logistics_primary_unit_status(u.id,u.status) where u.id=m.assigned_unit_id;
      end if;
    end if;

    insert into public.cad_activity(event_id,incident_id,action,detail,actor_kind)
    values(m.event_id,iid,'MOVE_MIGRATED',jsonb_build_object('legacy_movement_id',m.id,'legacy_status',m.status),'system');
  end loop;
end $$;

-- Legacy link column is superseded by incident_kind='MOVE'; leave data in place.
comment on column public.incidents.guest_logistics_movement_id is 'Legacy (pre-0.18). MOVEs are now incidents with incident_kind=MOVE.';

-- ------------------------------------------------------------
-- 13. CAD support tickets linked to a MOVE (replaces the legacy movement link)
-- ------------------------------------------------------------
alter table public.incidents
  add column if not exists related_incident_id uuid references public.incidents(id) on delete set null;

create or replace function public.create_incident_v6(
  p_event_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_create_poi boolean default false,
  p_poi_category text default null,
  p_poi_aliases text[] default null,
  p_related_incident_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  iid uuid;
  rel public.incidents;
begin
  if p_related_incident_id is not null then
    select * into rel from public.incidents where id=p_related_incident_id and event_id=p_event_id;
    if rel.id is null then raise exception 'Related incident was not found in this event'; end if;
  end if;
  iid:=public.create_incident_v4(p_event_id,p_department_ids,p_call_type,p_priority,p_latitude,p_longitude,p_map_x,p_map_y,p_landmark,p_notes,p_poi_id,p_map_layer_id,p_zone_id,p_create_poi,p_poi_category,p_poi_aliases);
  if rel.id is not null then
    update public.incidents set related_incident_id=rel.id where id=iid;
    insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
    values(p_event_id,iid,'RELATED_INCIDENT_LINKED',jsonb_build_object('related_incident_id',rel.id,'related_incident_number',rel.incident_number,'related_kind',rel.incident_kind),auth.uid(),'staff');
  end if;
  return iid;
end;
$$;
revoke all on function public.create_incident_v6(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid,boolean,text,text[],uuid) from public;
grant execute on function public.create_incident_v6(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid,boolean,text,text[],uuid) to authenticated;

-- Carry legacy links forward.
update public.incidents c
set related_incident_id=m.id
from public.incidents m
where c.guest_logistics_movement_id is not null
  and m.legacy_movement_id=c.guest_logistics_movement_id
  and c.related_incident_id is null;
