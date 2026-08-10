-- CommCenter Pro v0.11.0
-- Unit Staffing / Personnel Assignment Board
--
-- Event-scoped personnel roster, Operational Period staffing assignments,
-- dispatcher check-in/check-out, and unit staffing audit history.
-- This module does not replace Auth users or Field sessions: a person may be
-- listed on a unit staffing assignment without having a CommCenter login.

-- ============================================================
-- TABLES
-- ============================================================

create table if not exists public.event_personnel (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  department_id uuid not null references public.event_departments(id) on delete restrict,
  full_name text not null,
  preferred_name text,
  personnel_identifier text,
  phone text,
  email text,
  notes text,
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(length(trim(full_name))>0)
);

create index if not exists event_personnel_event_department_idx
  on public.event_personnel(event_id,department_id,active,full_name);

create unique index if not exists event_personnel_identifier_unique_idx
  on public.event_personnel(event_id,lower(personnel_identifier))
  where personnel_identifier is not null and trim(personnel_identifier)<>'';

create table if not exists public.unit_staffing_assignments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  operational_period_id uuid not null references public.operational_periods(id) on delete restrict,
  personnel_id uuid not null references public.event_personnel(id) on delete restrict,
  unit_id uuid references public.units(id) on delete restrict,
  role_label text,
  planned_start_at timestamptz,
  planned_end_at timestamptz,
  status text not null default 'PLANNED'
    check(status in ('PLANNED','CHECKED_IN','CHECKED_OUT','CANCELLED')),
  checked_in_at timestamptz,
  checked_out_at timestamptz,
  checked_in_by uuid references auth.users(id),
  checked_out_by uuid references auth.users(id),
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(operational_period_id,personnel_id),
  check(planned_end_at is null or planned_start_at is null or planned_end_at>planned_start_at)
);

create index if not exists unit_staffing_assignments_event_op_idx
  on public.unit_staffing_assignments(event_id,operational_period_id,status,unit_id);

create index if not exists unit_staffing_assignments_unit_idx
  on public.unit_staffing_assignments(unit_id,status);

create index if not exists unit_staffing_assignments_personnel_idx
  on public.unit_staffing_assignments(personnel_id,operational_period_id);

create table if not exists public.unit_staffing_activity (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  assignment_id uuid references public.unit_staffing_assignments(id) on delete cascade,
  personnel_id uuid not null references public.event_personnel(id) on delete restrict,
  unit_id uuid references public.units(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor_user_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists unit_staffing_activity_assignment_idx
  on public.unit_staffing_activity(assignment_id,created_at);

create index if not exists unit_staffing_activity_event_idx
  on public.unit_staffing_activity(event_id,created_at);

-- ============================================================
-- RLS
-- ============================================================

alter table public.event_personnel enable row level security;
alter table public.unit_staffing_assignments enable row level security;
alter table public.unit_staffing_activity enable row level security;

drop policy if exists event_personnel_staff_read on public.event_personnel;
create policy event_personnel_staff_read
on public.event_personnel
for select
to authenticated
using(private.staff_can_access_department(event_id,department_id));

drop policy if exists unit_staffing_assignments_staff_read on public.unit_staffing_assignments;
create policy unit_staffing_assignments_staff_read
on public.unit_staffing_assignments
for select
to authenticated
using(
  exists(
    select 1
    from public.event_personnel p
    where p.id=unit_staffing_assignments.personnel_id
      and p.event_id=unit_staffing_assignments.event_id
      and private.staff_can_access_department(
        unit_staffing_assignments.event_id,
        p.department_id
      )
  )
);

drop policy if exists unit_staffing_activity_staff_read on public.unit_staffing_activity;
create policy unit_staffing_activity_staff_read
on public.unit_staffing_activity
for select
to authenticated
using(
  exists(
    select 1
    from public.event_personnel p
    where p.id=unit_staffing_activity.personnel_id
      and p.event_id=unit_staffing_activity.event_id
      and private.staff_can_access_department(
        unit_staffing_activity.event_id,
        p.department_id
      )
  )
);

-- Direct writes are intentionally not granted. Operational changes go through
-- audited RPCs below.
grant select on public.event_personnel to authenticated;
grant select on public.unit_staffing_assignments to authenticated;
grant select on public.unit_staffing_activity to authenticated;
grant usage,select on sequence public.unit_staffing_activity_id_seq to authenticated;

-- ============================================================
-- PERSONNEL ROSTER RPCs
-- ============================================================

create or replace function public.staffing_create_personnel(
  p_event_id uuid,
  p_department_id uuid,
  p_full_name text,
  p_preferred_name text default null,
  p_personnel_identifier text default null,
  p_phone text default null,
  p_email text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  pid uuid;
begin
  if not private.staff_can_access_department(p_event_id,p_department_id) then
    raise exception 'Unit Staffing access required for this department';
  end if;

  if not exists(
    select 1 from public.event_departments d
    where d.id=p_department_id and d.event_id=p_event_id and d.active=true
  ) then
    raise exception 'Department is not active in this event';
  end if;

  if nullif(trim(coalesce(p_full_name,'')),'') is null then
    raise exception 'Full name is required';
  end if;

  insert into public.event_personnel(
    event_id,department_id,full_name,preferred_name,personnel_identifier,
    phone,email,notes,created_by
  ) values(
    p_event_id,
    p_department_id,
    trim(p_full_name),
    nullif(trim(coalesce(p_preferred_name,'')),''),
    nullif(trim(coalesce(p_personnel_identifier,'')),''),
    nullif(trim(coalesce(p_phone,'')),''),
    nullif(trim(coalesce(p_email,'')),''),
    nullif(trim(coalesce(p_notes,'')),''),
    auth.uid()
  ) returning id into pid;

  return pid;
end;
$$;

create or replace function public.staffing_update_personnel(
  p_personnel_id uuid,
  p_department_id uuid,
  p_full_name text,
  p_preferred_name text default null,
  p_personnel_identifier text default null,
  p_phone text default null,
  p_email text default null,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  p public.event_personnel;
begin
  select * into p
  from public.event_personnel
  where id=p_personnel_id
  for update;

  if p.id is null then raise exception 'Personnel record not found'; end if;
  if not private.staff_can_access_department(p.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;
  if not private.staff_can_access_department(p.event_id,p_department_id) then
    raise exception 'You do not have access to the selected department';
  end if;
  if not exists(
    select 1 from public.event_departments d
    where d.id=p_department_id and d.event_id=p.event_id and d.active=true
  ) then
    raise exception 'Department is not active in this event';
  end if;
  if nullif(trim(coalesce(p_full_name,'')),'') is null then
    raise exception 'Full name is required';
  end if;

  update public.event_personnel
  set department_id=p_department_id,
      full_name=trim(p_full_name),
      preferred_name=nullif(trim(coalesce(p_preferred_name,'')),''),
      personnel_identifier=nullif(trim(coalesce(p_personnel_identifier,'')),''),
      phone=nullif(trim(coalesce(p_phone,'')),''),
      email=nullif(trim(coalesce(p_email,'')),''),
      notes=nullif(trim(coalesce(p_notes,'')),''),
      updated_at=now()
  where id=p.id;
end;
$$;

create or replace function public.staffing_archive_personnel(
  p_personnel_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  p public.event_personnel;
begin
  select * into p
  from public.event_personnel
  where id=p_personnel_id
  for update;

  if p.id is null then raise exception 'Personnel record not found'; end if;
  if not private.staff_can_access_department(p.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;
  if coalesce(p_confirmation,'')<>p.full_name then
    raise exception 'Confirmation text does not match personnel name';
  end if;

  if exists(
    select 1
    from public.unit_staffing_assignments a
    where a.personnel_id=p.id
      and a.status in ('PLANNED','CHECKED_IN')
  ) then
    raise exception 'Personnel has an open staffing assignment. Cancel or check out the assignment first.';
  end if;

  update public.event_personnel
  set active=false,updated_at=now()
  where id=p.id;
end;
$$;

-- ============================================================
-- ASSIGNMENT RPCs
-- ============================================================

create or replace function public.staffing_save_assignment(
  p_personnel_id uuid,
  p_operational_period_id uuid,
  p_unit_id uuid default null,
  p_role_label text default null,
  p_planned_start_at timestamptz default null,
  p_planned_end_at timestamptz default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  p public.event_personnel;
  op public.operational_periods;
  a public.unit_staffing_assignments;
  aid uuid;
  prior_unit uuid;
  new_status text;
begin
  select * into p from public.event_personnel where id=p_personnel_id and active=true;
  if p.id is null then raise exception 'Active personnel record not found'; end if;
  if not private.staff_can_access_department(p.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;

  select * into op from public.operational_periods where id=p_operational_period_id;
  if op.id is null or op.event_id<>p.event_id then
    raise exception 'Operational Period is not part of this event';
  end if;
  if op.status not in ('PLANNED','ACTIVE') then
    raise exception 'Personnel assignments can only be changed in a PLANNED or ACTIVE Operational Period';
  end if;

  if p_unit_id is not null then
    if not exists(
      select 1
      from public.units u
      where u.id=p_unit_id and u.event_id=p.event_id and u.active=true
    ) then
      raise exception 'Selected unit is not active in this event';
    end if;

    if not exists(
      select 1
      from public.units u
      where u.id=p_unit_id
        and private.staff_can_access_department(p.event_id,u.department_id)
    ) then
      raise exception 'You do not have access to assign personnel to this unit';
    end if;
  end if;

  if p_planned_end_at is not null and p_planned_start_at is not null
     and p_planned_end_at<=p_planned_start_at then
    raise exception 'Planned end time must be after planned start time';
  end if;

  select * into a
  from public.unit_staffing_assignments
  where operational_period_id=op.id and personnel_id=p.id
  for update;

  if a.id is null then
    insert into public.unit_staffing_assignments(
      event_id,operational_period_id,personnel_id,unit_id,role_label,
      planned_start_at,planned_end_at,status,notes,created_by
    ) values(
      p.event_id,op.id,p.id,p_unit_id,
      nullif(trim(coalesce(p_role_label,'')),''),
      p_planned_start_at,p_planned_end_at,'PLANNED',
      nullif(trim(coalesce(p_notes,'')),''),auth.uid()
    ) returning id into aid;

    insert into public.unit_staffing_activity(
      event_id,assignment_id,personnel_id,unit_id,action,detail,actor_user_id
    ) values(
      p.event_id,aid,p.id,p_unit_id,'ASSIGNMENT_CREATED',
      jsonb_build_object(
        'role_label',nullif(trim(coalesce(p_role_label,'')),''),
        'planned_start_at',p_planned_start_at,
        'planned_end_at',p_planned_end_at
      ),auth.uid()
    );

    return aid;
  end if;

  prior_unit:=a.unit_id;
  new_status:=case when a.status in ('CANCELLED','CHECKED_OUT') then 'PLANNED' else a.status end;

  update public.unit_staffing_assignments
  set unit_id=p_unit_id,
      role_label=nullif(trim(coalesce(p_role_label,'')),''),
      planned_start_at=p_planned_start_at,
      planned_end_at=p_planned_end_at,
      notes=nullif(trim(coalesce(p_notes,'')),''),
      status=new_status,
      checked_in_at=case when a.status in ('CANCELLED','CHECKED_OUT') then null else checked_in_at end,
      checked_out_at=case when a.status in ('CANCELLED','CHECKED_OUT') then null else checked_out_at end,
      checked_in_by=case when a.status in ('CANCELLED','CHECKED_OUT') then null else checked_in_by end,
      checked_out_by=case when a.status in ('CANCELLED','CHECKED_OUT') then null else checked_out_by end,
      updated_at=now()
  where id=a.id;

  insert into public.unit_staffing_activity(
    event_id,assignment_id,personnel_id,unit_id,action,detail,actor_user_id
  ) values(
    p.event_id,a.id,p.id,p_unit_id,
    case when prior_unit is distinct from p_unit_id then 'ASSIGNMENT_REASSIGNED' else 'ASSIGNMENT_UPDATED' end,
    jsonb_build_object(
      'from_unit_id',prior_unit,
      'to_unit_id',p_unit_id,
      'role_label',nullif(trim(coalesce(p_role_label,'')),''),
      'planned_start_at',p_planned_start_at,
      'planned_end_at',p_planned_end_at
    ),auth.uid()
  );

  return a.id;
end;
$$;


create or replace function public.staffing_copy_operational_period(
  p_source_operational_period_id uuid,
  p_target_operational_period_id uuid
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  source_op public.operational_periods;
  target_op public.operational_periods;
  source_assignment record;
  copied_count integer:=0;
  new_assignment_id uuid;
begin
  select * into source_op
  from public.operational_periods
  where id=p_source_operational_period_id;

  select * into target_op
  from public.operational_periods
  where id=p_target_operational_period_id;

  if source_op.id is null or target_op.id is null then
    raise exception 'Operational Period not found';
  end if;

  if source_op.event_id<>target_op.event_id then
    raise exception 'Operational Periods must belong to the same event';
  end if;

  if source_op.id=target_op.id then
    raise exception 'Choose two different Operational Periods';
  end if;

  if target_op.status not in ('PLANNED','ACTIVE') then
    raise exception 'Staffing can only be copied into a PLANNED or ACTIVE Operational Period';
  end if;

  for source_assignment in
    select
      a.*,
      p.department_id as personnel_department_id
    from public.unit_staffing_assignments a
    join public.event_personnel p on p.id=a.personnel_id
    where a.operational_period_id=source_op.id
      and a.status<>'CANCELLED'
      and p.active=true
    order by a.created_at
  loop
    if not private.staff_can_access_department(
      source_op.event_id,
      source_assignment.personnel_department_id
    ) then
      continue;
    end if;

    if source_assignment.unit_id is not null
       and not exists(
         select 1
         from public.units u
         where u.id=source_assignment.unit_id
           and u.event_id=source_op.event_id
           and u.active=true
           and private.staff_can_access_department(source_op.event_id,u.department_id)
       )
    then
      continue;
    end if;

    if exists(
      select 1
      from public.unit_staffing_assignments existing
      where existing.operational_period_id=target_op.id
        and existing.personnel_id=source_assignment.personnel_id
    ) then
      continue;
    end if;

    insert into public.unit_staffing_assignments(
      event_id,
      operational_period_id,
      personnel_id,
      unit_id,
      role_label,
      planned_start_at,
      planned_end_at,
      status,
      notes,
      created_by
    ) values(
      target_op.event_id,
      target_op.id,
      source_assignment.personnel_id,
      source_assignment.unit_id,
      source_assignment.role_label,
      target_op.starts_at,
      target_op.ends_at,
      'PLANNED',
      source_assignment.notes,
      auth.uid()
    )
    returning id into new_assignment_id;

    insert into public.unit_staffing_activity(
      event_id,
      assignment_id,
      personnel_id,
      unit_id,
      action,
      detail,
      actor_user_id
    ) values(
      target_op.event_id,
      new_assignment_id,
      source_assignment.personnel_id,
      source_assignment.unit_id,
      'ASSIGNMENT_COPIED_FROM_OPERATIONAL_PERIOD',
      jsonb_build_object(
        'source_operational_period_id',source_op.id,
        'source_operational_period_name',source_op.name,
        'target_operational_period_id',target_op.id,
        'target_operational_period_name',target_op.name
      ),
      auth.uid()
    );

    copied_count:=copied_count+1;
  end loop;

  return copied_count;
end;
$$;

create or replace function public.staffing_check_in(p_assignment_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path=public
as $$
declare
  a public.unit_staffing_assignments;
  p public.event_personnel;
  check_time timestamptz:=now();
begin
  select * into a
  from public.unit_staffing_assignments
  where id=p_assignment_id
  for update;

  if a.id is null then raise exception 'Staffing assignment not found'; end if;
  select * into p from public.event_personnel where id=a.personnel_id;
  if p.id is null or not private.staff_can_access_department(a.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;
  if a.status='CANCELLED' then raise exception 'Cancelled assignment cannot be checked in'; end if;

  if not exists(
    select 1
    from public.operational_periods op
    where op.id=a.operational_period_id
      and op.event_id=a.event_id
      and op.status in ('PLANNED','ACTIVE')
  ) then
    raise exception 'Personnel can only be checked in to a PLANNED or ACTIVE Operational Period';
  end if;

  if a.status='CHECKED_IN' then return a.checked_in_at; end if;

  update public.unit_staffing_assignments
  set status='CHECKED_IN',
      checked_in_at=check_time,
      checked_out_at=null,
      checked_in_by=auth.uid(),
      checked_out_by=null,
      updated_at=now()
  where id=a.id;

  insert into public.unit_staffing_activity(
    event_id,assignment_id,personnel_id,unit_id,action,detail,actor_user_id
  ) values(
    a.event_id,a.id,a.personnel_id,a.unit_id,'PERSONNEL_CHECKED_IN',
    jsonb_build_object('checked_in_at',check_time),auth.uid()
  );

  return check_time;
end;
$$;

create or replace function public.staffing_check_out(p_assignment_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path=public
as $$
declare
  a public.unit_staffing_assignments;
  p public.event_personnel;
  check_time timestamptz:=now();
begin
  select * into a
  from public.unit_staffing_assignments
  where id=p_assignment_id
  for update;

  if a.id is null then raise exception 'Staffing assignment not found'; end if;
  select * into p from public.event_personnel where id=a.personnel_id;
  if p.id is null or not private.staff_can_access_department(a.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;
  if a.status<>'CHECKED_IN' then raise exception 'Personnel is not currently checked in'; end if;

  update public.unit_staffing_assignments
  set status='CHECKED_OUT',
      checked_out_at=check_time,
      checked_out_by=auth.uid(),
      updated_at=now()
  where id=a.id;

  insert into public.unit_staffing_activity(
    event_id,assignment_id,personnel_id,unit_id,action,detail,actor_user_id
  ) values(
    a.event_id,a.id,a.personnel_id,a.unit_id,'PERSONNEL_CHECKED_OUT',
    jsonb_build_object('checked_out_at',check_time),auth.uid()
  );

  return check_time;
end;
$$;

create or replace function public.staffing_cancel_assignment(p_assignment_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  a public.unit_staffing_assignments;
  p public.event_personnel;
begin
  select * into a
  from public.unit_staffing_assignments
  where id=p_assignment_id
  for update;

  if a.id is null then raise exception 'Staffing assignment not found'; end if;
  select * into p from public.event_personnel where id=a.personnel_id;
  if p.id is null or not private.staff_can_access_department(a.event_id,p.department_id) then
    raise exception 'Unit Staffing access required';
  end if;
  if a.status='CHECKED_IN' then
    raise exception 'Check the person out before cancelling the assignment';
  end if;
  if a.status='CANCELLED' then return; end if;

  update public.unit_staffing_assignments
  set status='CANCELLED',updated_at=now()
  where id=a.id;

  insert into public.unit_staffing_activity(
    event_id,assignment_id,personnel_id,unit_id,action,detail,actor_user_id
  ) values(
    a.event_id,a.id,a.personnel_id,a.unit_id,'ASSIGNMENT_CANCELLED','{}'::jsonb,auth.uid()
  );
end;
$$;

-- ============================================================
-- SAFETY GUARDS
-- ============================================================

create or replace function private.guard_unit_staffing_unit_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true and new.active=false and exists(
    select 1
    from public.unit_staffing_assignments a
    where a.unit_id=old.id
      and a.status in ('PLANNED','CHECKED_IN')
  ) then
    raise exception 'Unit has open personnel staffing assignments. Reassign or cancel them before archiving the unit.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_unit_staffing_unit_archive on public.units;
create trigger guard_unit_staffing_unit_archive
before update of active on public.units
for each row execute function private.guard_unit_staffing_unit_archive();

create or replace function private.guard_unit_staffing_department_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true and new.active=false and exists(
    select 1
    from public.event_personnel p
    where p.department_id=old.id and p.active=true
  ) then
    raise exception 'Department still has active personnel records. Archive or move those personnel before archiving the department.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_unit_staffing_department_archive on public.event_departments;
create trigger guard_unit_staffing_department_archive
before update of active on public.event_departments
for each row execute function private.guard_unit_staffing_department_archive();

create or replace function private.guard_unit_staffing_event_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true and new.active=false and exists(
    select 1 from public.unit_staffing_assignments a
    where a.event_id=old.id and a.status='CHECKED_IN'
  ) then
    raise exception 'Event still has checked-in personnel. Check everyone out before archiving the event.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_unit_staffing_event_archive on public.events;
create trigger guard_unit_staffing_event_archive
before update of active on public.events
for each row execute function private.guard_unit_staffing_event_archive();

create or replace function private.guard_unit_staffing_operational_period_close()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.status is distinct from new.status
     and new.status in ('COMPLETE','CANCELLED')
     and exists(
       select 1 from public.unit_staffing_assignments a
       where a.operational_period_id=old.id and a.status='CHECKED_IN'
     )
  then
    raise exception 'Operational Period still has checked-in personnel. Check them out before completing or cancelling the period.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_unit_staffing_operational_period_close on public.operational_periods;
create trigger guard_unit_staffing_operational_period_close
before update of status on public.operational_periods
for each row execute function private.guard_unit_staffing_operational_period_close();

-- ============================================================
-- REALTIME
-- ============================================================

do $$
begin
  if not exists(
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='event_personnel'
  ) then
    alter publication supabase_realtime add table public.event_personnel;
  end if;

  if not exists(
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='unit_staffing_assignments'
  ) then
    alter publication supabase_realtime add table public.unit_staffing_assignments;
  end if;
end $$;

-- ============================================================
-- GRANTS
-- ============================================================

revoke all on function public.staffing_create_personnel(uuid,uuid,text,text,text,text,text,text) from public;
revoke all on function public.staffing_update_personnel(uuid,uuid,text,text,text,text,text,text) from public;
revoke all on function public.staffing_archive_personnel(uuid,text) from public;
revoke all on function public.staffing_save_assignment(uuid,uuid,uuid,text,timestamptz,timestamptz,text) from public;
revoke all on function public.staffing_copy_operational_period(uuid,uuid) from public;
revoke all on function public.staffing_check_in(uuid) from public;
revoke all on function public.staffing_check_out(uuid) from public;
revoke all on function public.staffing_cancel_assignment(uuid) from public;

grant execute on function public.staffing_create_personnel(uuid,uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.staffing_update_personnel(uuid,uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.staffing_archive_personnel(uuid,text) to authenticated;
grant execute on function public.staffing_save_assignment(uuid,uuid,uuid,text,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.staffing_copy_operational_period(uuid,uuid) to authenticated;
grant execute on function public.staffing_check_in(uuid) to authenticated;
grant execute on function public.staffing_check_out(uuid) to authenticated;
grant execute on function public.staffing_cancel_assignment(uuid) to authenticated;
