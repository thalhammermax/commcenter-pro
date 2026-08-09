-- CommCenter Pro v0.3.0 — EMS Operations
-- Adds treatment areas, lightweight patient/encounter tracking, ambulances,
-- field/treatment/ambulance handoffs, treatment-area stations, and EMS command data.
--
-- This intentionally stores OPERATIONAL patient-flow data, not an ePCR.

alter table public.events
  add column if not exists next_ems_encounter_number integer not null default 1;

-- ============================================================
-- EMS RESOURCE CONFIGURATION
-- ============================================================

create table if not exists public.ems_unit_config (
  unit_id uuid primary key references public.units(id) on delete cascade,
  ems_role text not null check (ems_role in ('field_team','ambulance','command')),
  transport_capable boolean not null default false,
  ambulance_level text check (ambulance_level is null or ambulance_level in ('BLS','ALS','CCT','OTHER')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.ems_treatment_areas (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  department_id uuid references public.event_departments(id) on delete set null,
  poi_id uuid references public.event_pois(id) on delete set null,
  name text not null,
  capacity integer not null default 1 check (capacity > 0),
  status text not null default 'OPEN' check (status in ('OPEN','LIMITED','FULL','CLOSED')),
  accepting_patients boolean not null default true,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  unique(event_id,name)
);

create index if not exists ems_treatment_areas_event_idx
  on public.ems_treatment_areas(event_id,active);

create table if not exists public.treatment_area_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  treatment_area_id uuid references public.ems_treatment_areas(id) on delete set null,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  operator_name text,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz,
  active boolean not null default true
);

create index if not exists treatment_area_sessions_auth_active_idx
  on public.treatment_area_sessions(auth_user_id,active);
create index if not exists treatment_area_sessions_area_active_idx
  on public.treatment_area_sessions(treatment_area_id,active);

-- ============================================================
-- EMS ENCOUNTERS + HANDOFFS
-- ============================================================

create table if not exists public.ems_encounters (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  incident_id uuid references public.incidents(id) on delete set null,
  tracking_number text not null,
  current_status text not null default 'FIELD' check (
    current_status in ('FIELD','IN_TREATMENT','WITH_AMBULANCE','TRANSPORTING','CLOSED')
  ),
  current_unit_id uuid references public.units(id) on delete set null,
  current_treatment_area_id uuid references public.ems_treatment_areas(id) on delete set null,
  origin_unit_id uuid references public.units(id) on delete set null,
  operational_note text,
  transport_destination text,
  transport_started_at timestamptz,
  transport_completed_at timestamptz,
  final_disposition text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  unique(event_id,tracking_number),
  check (not (current_unit_id is not null and current_treatment_area_id is not null))
);

create index if not exists ems_encounters_event_status_idx
  on public.ems_encounters(event_id,current_status);
create index if not exists ems_encounters_current_unit_idx
  on public.ems_encounters(current_unit_id) where current_unit_id is not null;
create index if not exists ems_encounters_current_area_idx
  on public.ems_encounters(current_treatment_area_id) where current_treatment_area_id is not null;
create index if not exists ems_encounters_incident_idx
  on public.ems_encounters(incident_id) where incident_id is not null;

create table if not exists public.ems_handoffs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  encounter_id uuid not null references public.ems_encounters(id) on delete cascade,
  from_unit_id uuid references public.units(id) on delete set null,
  from_treatment_area_id uuid references public.ems_treatment_areas(id) on delete set null,
  to_unit_id uuid references public.units(id) on delete set null,
  to_treatment_area_id uuid references public.ems_treatment_areas(id) on delete set null,
  status text not null default 'PENDING' check (status in ('PENDING','COMPLETED','DECLINED','CANCELLED')),
  note text,
  requested_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  responded_by uuid references auth.users(id),
  responded_at timestamptz,
  completed_at timestamptz,
  check ((from_unit_id is not null)::int + (from_treatment_area_id is not null)::int = 1),
  check ((to_unit_id is not null)::int + (to_treatment_area_id is not null)::int = 1)
);

create index if not exists ems_handoffs_event_status_idx
  on public.ems_handoffs(event_id,status,requested_at desc);
create index if not exists ems_handoffs_encounter_idx
  on public.ems_handoffs(encounter_id,requested_at desc);
create index if not exists ems_handoffs_to_unit_pending_idx
  on public.ems_handoffs(to_unit_id,status) where to_unit_id is not null;
create index if not exists ems_handoffs_to_area_pending_idx
  on public.ems_handoffs(to_treatment_area_id,status) where to_treatment_area_id is not null;

-- ============================================================
-- PRIVATE ACCESS HELPERS (avoid circular RLS)
-- ============================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.field_can_read_incident(p_incident_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.incident_units iu
    join public.field_sessions fs on fs.unit_id=iu.unit_id
    where iu.incident_id=p_incident_id
      and iu.cleared_at is null
      and fs.auth_user_id=(select auth.uid())
      and fs.active=true
  );
$$;

create or replace function private.current_field_unit()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select fs.unit_id
  from public.field_sessions fs
  where fs.auth_user_id = (select auth.uid())
    and fs.active = true
    and fs.unit_id is not null
  order by fs.started_at desc
  limit 1;
$$;

create or replace function private.current_treatment_area()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select ts.treatment_area_id
  from public.treatment_area_sessions ts
  where ts.auth_user_id = (select auth.uid())
    and ts.active = true
    and ts.treatment_area_id is not null
  order by ts.started_at desc
  limit 1;
$$;

create or replace function private.treatment_has_event_access(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.treatment_area_sessions ts
    where ts.event_id = p_event_id
      and ts.auth_user_id = (select auth.uid())
      and ts.active = true
  );
$$;

create or replace function private.can_read_ems_resource_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_event_staff_access(p_event_id)
      or public.field_has_event_access(p_event_id)
      or private.treatment_has_event_access(p_event_id);
$$;

create or replace function private.ems_config_event(p_unit_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.event_id from public.units u where u.id=p_unit_id;
$$;

create or replace function private.can_read_ems_encounter(p_encounter_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.ems_encounters e
    where e.id = p_encounter_id
      and (
        public.has_event_staff_access(e.event_id)
        or e.current_unit_id = private.current_field_unit()
        or e.current_treatment_area_id = private.current_treatment_area()
        or exists (
          select 1
          from public.ems_handoffs h
          where h.encounter_id=e.id
            and (
              h.from_unit_id = private.current_field_unit()
              or h.to_unit_id = private.current_field_unit()
              or h.from_treatment_area_id = private.current_treatment_area()
              or h.to_treatment_area_id = private.current_treatment_area()
            )
        )
      )
  );
$$;

create or replace function private.can_read_ems_handoff(p_handoff_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.ems_handoffs h
    where h.id=p_handoff_id
      and (
        public.has_event_staff_access(h.event_id)
        or h.from_unit_id = private.current_field_unit()
        or h.to_unit_id = private.current_field_unit()
        or h.from_treatment_area_id = private.current_treatment_area()
        or h.to_treatment_area_id = private.current_treatment_area()
      )
  );
$$;

create or replace function private.treatment_can_read_incident(p_incident_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.ems_encounters e
    where e.incident_id=p_incident_id
      and (
        e.current_treatment_area_id=private.current_treatment_area()
        or exists (
          select 1 from public.ems_handoffs h
          where h.encounter_id=e.id
            and (
              h.from_treatment_area_id=private.current_treatment_area()
              or h.to_treatment_area_id=private.current_treatment_area()
            )
        )
      )
  );
$$;

revoke all on function private.field_can_read_incident(uuid) from public;
revoke all on function private.current_field_unit() from public;
revoke all on function private.current_treatment_area() from public;
revoke all on function private.treatment_has_event_access(uuid) from public;
revoke all on function private.can_read_ems_resource_event(uuid) from public;
revoke all on function private.ems_config_event(uuid) from public;
revoke all on function private.can_read_ems_encounter(uuid) from public;
revoke all on function private.can_read_ems_handoff(uuid) from public;
revoke all on function private.treatment_can_read_incident(uuid) from public;

grant execute on function private.field_can_read_incident(uuid) to authenticated;
grant execute on function private.current_field_unit() to authenticated;
grant execute on function private.current_treatment_area() to authenticated;
grant execute on function private.treatment_has_event_access(uuid) to authenticated;
grant execute on function private.can_read_ems_resource_event(uuid) to authenticated;
grant execute on function private.ems_config_event(uuid) to authenticated;
grant execute on function private.can_read_ems_encounter(uuid) to authenticated;
grant execute on function private.can_read_ems_handoff(uuid) to authenticated;
grant execute on function private.treatment_can_read_incident(uuid) to authenticated;

-- ============================================================
-- TREATMENT AREA SESSION RPCs
-- ============================================================

create or replace function public.treatment_enter_event(
  p_event_code text,
  p_pin text,
  p_operator_name text default null
) returns public.treatment_area_sessions
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.events;
  ts public.treatment_area_sessions;
begin
  select * into e
  from public.events
  where upper(event_code)=upper(trim(p_event_code))
    and active=true
    and field_access_enabled=true;

  if e.id is null then
    raise exception 'Event not found or field access is disabled';
  end if;

  if e.field_pin_hash is null or crypt(p_pin,e.field_pin_hash)<>e.field_pin_hash then
    raise exception 'Invalid event access code';
  end if;

  update public.treatment_area_sessions
  set active=false,ended_at=now()
  where auth_user_id=auth.uid() and active=true;

  update public.field_sessions
  set active=false,ended_at=now()
  where auth_user_id=auth.uid() and active=true;

  insert into public.treatment_area_sessions(event_id,auth_user_id,operator_name)
  values(e.id,auth.uid(),nullif(trim(p_operator_name),''))
  returning * into ts;

  insert into public.cad_activity(event_id,action,detail,actor_user_id,actor_kind)
  values(e.id,'TREATMENT_SESSION_STARTED',jsonb_build_object('treatment_session_id',ts.id),auth.uid(),'field');

  return ts;
end;
$$;

create or replace function public.treatment_claim_area(
  p_treatment_session_id uuid,
  p_treatment_area_id uuid
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare ts public.treatment_area_sessions;
begin
  select * into ts
  from public.treatment_area_sessions
  where id=p_treatment_session_id and auth_user_id=auth.uid() and active=true;

  if ts.id is null then raise exception 'Treatment-area session not found'; end if;
  if not exists(
    select 1 from public.ems_treatment_areas ta
    where ta.id=p_treatment_area_id and ta.event_id=ts.event_id and ta.active=true
  ) then raise exception 'Invalid treatment area'; end if;

  update public.treatment_area_sessions
  set treatment_area_id=p_treatment_area_id,last_seen_at=now()
  where id=ts.id;
end;
$$;

create or replace function public.treatment_release_area(p_treatment_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.treatment_area_sessions
  set treatment_area_id=null,last_seen_at=now()
  where id=p_treatment_session_id and auth_user_id=auth.uid() and active=true;
end;
$$;

create or replace function public.treatment_end_session(p_treatment_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.treatment_area_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where id=p_treatment_session_id and auth_user_id=auth.uid() and active=true;
end;
$$;

create or replace function public.treatment_set_status(
  p_treatment_area_id uuid,
  p_status text,
  p_accepting boolean
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare eid uuid;
begin
  select event_id into eid from public.ems_treatment_areas where id=p_treatment_area_id;
  if eid is null then raise exception 'Treatment area not found'; end if;

  if not (
    public.can_dispatch_event(eid)
    or private.current_treatment_area()=p_treatment_area_id
  ) then raise exception 'Not authorized for this treatment area'; end if;

  if p_status not in ('OPEN','LIMITED','FULL','CLOSED') then
    raise exception 'Invalid treatment-area status';
  end if;

  update public.ems_treatment_areas
  set status=p_status,accepting_patients=p_accepting
  where id=p_treatment_area_id;
end;
$$;

-- ============================================================
-- EMS ENCOUNTER RPCs
-- ============================================================

create or replace function public.ems_create_encounter(
  p_event_id uuid,
  p_incident_id uuid default null,
  p_source_unit_id uuid default null,
  p_source_treatment_area_id uuid default null,
  p_operational_note text default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  n integer;
  tracking text;
  encounter_id uuid;
  initial_status text;
begin
  if ((p_source_unit_id is not null)::int + (p_source_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Exactly one source resource is required';
  end if;

  if p_incident_id is not null and not exists(
    select 1 from public.incidents i where i.id=p_incident_id and i.event_id=p_event_id
  ) then raise exception 'Incident is not part of this event'; end if;

  if p_source_unit_id is not null then
    if not exists(select 1 from public.units u where u.id=p_source_unit_id and u.event_id=p_event_id) then
      raise exception 'Unit is not part of this event';
    end if;
    if not (public.can_dispatch_event(p_event_id) or public.field_has_unit_access(p_source_unit_id)) then
      raise exception 'Not authorized for this unit';
    end if;
    initial_status:='FIELD';
  else
    if not exists(select 1 from public.ems_treatment_areas ta where ta.id=p_source_treatment_area_id and ta.event_id=p_event_id and ta.active=true) then
      raise exception 'Treatment area is not part of this event';
    end if;
    if not (public.can_dispatch_event(p_event_id) or private.current_treatment_area()=p_source_treatment_area_id) then
      raise exception 'Not authorized for this treatment area';
    end if;
    initial_status:='IN_TREATMENT';
  end if;

  update public.events
  set next_ems_encounter_number=next_ems_encounter_number+1
  where id=p_event_id
  returning next_ems_encounter_number-1 into n;

  tracking:='PT-'||lpad(n::text,4,'0');

  insert into public.ems_encounters(
    event_id,incident_id,tracking_number,current_status,current_unit_id,
    current_treatment_area_id,origin_unit_id,operational_note,created_by
  ) values(
    p_event_id,p_incident_id,tracking,initial_status,p_source_unit_id,
    p_source_treatment_area_id,p_source_unit_id,nullif(trim(p_operational_note),''),auth.uid()
  ) returning id into encounter_id;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(
    p_event_id,p_incident_id,p_source_unit_id,'EMS_ENCOUNTER_CREATED',
    jsonb_build_object('encounter_id',encounter_id,'tracking_number',tracking,'treatment_area_id',p_source_treatment_area_id),
    auth.uid(),case when public.can_dispatch_event(p_event_id) then 'staff' else 'field' end
  );

  return encounter_id;
end;
$$;

create or replace function public.ems_request_handoff(
  p_encounter_id uuid,
  p_to_unit_id uuid default null,
  p_to_treatment_area_id uuid default null,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  hid uuid;
  caller_unit uuid;
  caller_area uuid;
  target_event uuid;
  occupancy integer;
  ta public.ems_treatment_areas;
begin
  select * into e from public.ems_encounters where id=p_encounter_id and current_status<>'CLOSED';
  if e.id is null then raise exception 'Active EMS encounter not found'; end if;

  if ((p_to_unit_id is not null)::int + (p_to_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Choose exactly one handoff destination';
  end if;

  caller_unit:=private.current_field_unit();
  caller_area:=private.current_treatment_area();

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=caller_unit
    or e.current_treatment_area_id=caller_area
  ) then raise exception 'Only the current holder can request this handoff'; end if;

  if exists(select 1 from public.ems_handoffs h where h.encounter_id=e.id and h.status='PENDING') then
    raise exception 'This encounter already has a pending handoff';
  end if;

  if p_to_unit_id is not null then
    select u.event_id into target_event from public.units u where u.id=p_to_unit_id and u.active=true;
    if target_event is distinct from e.event_id then raise exception 'Destination unit is not part of this event'; end if;
    if not exists(
      select 1 from public.ems_unit_config c
      where c.unit_id=p_to_unit_id and c.active=true and (c.ems_role='ambulance' or c.transport_capable=true)
    ) then raise exception 'Destination unit is not configured as a transport-capable EMS unit'; end if;
  else
    select * into ta from public.ems_treatment_areas where id=p_to_treatment_area_id and active=true;
    if ta.id is null or ta.event_id<>e.event_id then raise exception 'Destination treatment area is not part of this event'; end if;
    if not ta.accepting_patients or ta.status in ('FULL','CLOSED') then raise exception 'Destination treatment area is not accepting patients'; end if;
    select count(*) into occupancy
    from public.ems_encounters x
    where x.current_treatment_area_id=ta.id and x.current_status<>'CLOSED';
    if occupancy>=ta.capacity then raise exception 'Destination treatment area is at capacity'; end if;
  end if;

  insert into public.ems_handoffs(
    event_id,encounter_id,from_unit_id,from_treatment_area_id,
    to_unit_id,to_treatment_area_id,note,requested_by
  ) values(
    e.event_id,e.id,e.current_unit_id,e.current_treatment_area_id,
    p_to_unit_id,p_to_treatment_area_id,nullif(trim(p_note),''),auth.uid()
  ) returning id into hid;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(
    e.event_id,e.incident_id,e.current_unit_id,'EMS_HANDOFF_REQUESTED',
    jsonb_build_object('encounter_id',e.id,'handoff_id',hid,'to_unit_id',p_to_unit_id,'to_treatment_area_id',p_to_treatment_area_id),
    auth.uid(),case when public.can_dispatch_event(e.event_id) then 'staff' else 'field' end
  );

  return hid;
end;
$$;

create or replace function public.ems_accept_handoff(p_handoff_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  h public.ems_handoffs;
  new_status text;
  role_name text;
begin
  select * into h from public.ems_handoffs where id=p_handoff_id and status='PENDING';
  if h.id is null then raise exception 'Pending handoff not found'; end if;

  if not (
    public.can_dispatch_event(h.event_id)
    or (h.to_unit_id is not null and private.current_field_unit()=h.to_unit_id)
    or (h.to_treatment_area_id is not null and private.current_treatment_area()=h.to_treatment_area_id)
  ) then raise exception 'Only the receiving resource can accept this handoff'; end if;

  if h.to_treatment_area_id is not null then
    new_status:='IN_TREATMENT';
  else
    select ems_role into role_name from public.ems_unit_config where unit_id=h.to_unit_id and active=true;
    if role_name='ambulance' then new_status:='WITH_AMBULANCE'; else new_status:='FIELD'; end if;
  end if;

  update public.ems_handoffs
  set status='COMPLETED',responded_by=auth.uid(),responded_at=now(),completed_at=now()
  where id=h.id;

  update public.ems_handoffs
  set status='CANCELLED',responded_at=now()
  where encounter_id=h.encounter_id and id<>h.id and status='PENDING';

  update public.ems_encounters
  set current_unit_id=h.to_unit_id,
      current_treatment_area_id=h.to_treatment_area_id,
      current_status=new_status
  where id=h.encounter_id;

  insert into public.cad_activity(event_id,action,detail,actor_user_id,actor_kind)
  values(
    h.event_id,'EMS_HANDOFF_COMPLETED',
    jsonb_build_object('encounter_id',h.encounter_id,'handoff_id',h.id,'to_unit_id',h.to_unit_id,'to_treatment_area_id',h.to_treatment_area_id),
    auth.uid(),case when public.can_dispatch_event(h.event_id) then 'staff' else 'field' end
  );
end;
$$;

create or replace function public.ems_decline_handoff(p_handoff_id uuid,p_note text default null)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare h public.ems_handoffs;
begin
  select * into h from public.ems_handoffs where id=p_handoff_id and status='PENDING';
  if h.id is null then raise exception 'Pending handoff not found'; end if;

  if not (
    public.can_dispatch_event(h.event_id)
    or (h.to_unit_id is not null and private.current_field_unit()=h.to_unit_id)
    or (h.to_treatment_area_id is not null and private.current_treatment_area()=h.to_treatment_area_id)
  ) then raise exception 'Only the receiving resource can decline this handoff'; end if;

  update public.ems_handoffs
  set status='DECLINED',responded_by=auth.uid(),responded_at=now(),
      note=coalesce(nullif(trim(p_note),''),note)
  where id=h.id;
end;
$$;

create or replace function public.ems_cancel_handoff(p_handoff_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare h public.ems_handoffs;
begin
  select * into h from public.ems_handoffs where id=p_handoff_id and status='PENDING';
  if h.id is null then raise exception 'Pending handoff not found'; end if;

  if not (
    public.can_dispatch_event(h.event_id)
    or (h.from_unit_id is not null and private.current_field_unit()=h.from_unit_id)
    or (h.from_treatment_area_id is not null and private.current_treatment_area()=h.from_treatment_area_id)
  ) then raise exception 'Only the sending resource can cancel this handoff'; end if;

  update public.ems_handoffs
  set status='CANCELLED',responded_by=auth.uid(),responded_at=now()
  where id=h.id;
end;
$$;

create or replace function public.ems_release_encounter(p_encounter_id uuid,p_disposition text)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare e public.ems_encounters;
begin
  select * into e from public.ems_encounters where id=p_encounter_id and current_status<>'CLOSED';
  if e.id is null then raise exception 'Active EMS encounter not found'; end if;

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
    or e.current_treatment_area_id=private.current_treatment_area()
  ) then raise exception 'Only the current holder can close this encounter'; end if;

  update public.ems_handoffs
  set status='CANCELLED',responded_at=now()
  where encounter_id=e.id and status='PENDING';

  update public.ems_encounters
  set current_status='CLOSED',final_disposition=nullif(trim(p_disposition),''),closed_at=now()
  where id=e.id;

  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(
    e.event_id,e.incident_id,e.current_unit_id,'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object('encounter_id',e.id,'tracking_number',e.tracking_number,'disposition',p_disposition),
    auth.uid(),case when public.can_dispatch_event(e.event_id) then 'staff' else 'field' end
  );
end;
$$;

create or replace function public.ems_mark_transporting(p_encounter_id uuid,p_destination text)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare e public.ems_encounters;
begin
  select * into e from public.ems_encounters where id=p_encounter_id and current_status<>'CLOSED';
  if e.id is null then raise exception 'Active EMS encounter not found'; end if;

  if e.current_unit_id is null or not exists(
    select 1 from public.ems_unit_config c
    where c.unit_id=e.current_unit_id and c.active=true and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then raise exception 'Current holder is not a transport-capable EMS unit'; end if;

  if not (public.can_dispatch_event(e.event_id) or e.current_unit_id=private.current_field_unit()) then
    raise exception 'Only the transporting unit can start transport';
  end if;

  update public.ems_encounters
  set current_status='TRANSPORTING',transport_destination=nullif(trim(p_destination),''),transport_started_at=coalesce(transport_started_at,now())
  where id=e.id;
end;
$$;

create or replace function public.ems_complete_transport(p_encounter_id uuid,p_destination text default null)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare e public.ems_encounters;
begin
  select * into e from public.ems_encounters where id=p_encounter_id and current_status<>'CLOSED';
  if e.id is null then raise exception 'Active EMS encounter not found'; end if;

  if not (public.can_dispatch_event(e.event_id) or e.current_unit_id=private.current_field_unit()) then
    raise exception 'Only the transporting unit can complete transport';
  end if;

  update public.ems_encounters
  set current_status='CLOSED',
      transport_destination=coalesce(nullif(trim(p_destination),''),transport_destination),
      transport_completed_at=now(),final_disposition='TRANSPORTED',closed_at=now()
  where id=e.id;
end;
$$;

-- Replace field entry so switching a browser from Treatment Area -> Field
-- cannot leave both anonymous session types active at the same time.
create or replace function public.field_enter_event(p_event_code text,p_pin text,p_operator_name text default null)
returns public.field_sessions
language plpgsql security definer set search_path=public,extensions
as $$
declare e public.events; fs public.field_sessions;
begin
  select * into e from public.events
  where upper(event_code)=upper(trim(p_event_code)) and active=true and field_access_enabled=true;
  if e.id is null then raise exception 'Event not found or field access is disabled'; end if;
  if e.field_pin_hash is null or crypt(p_pin,e.field_pin_hash)<>e.field_pin_hash then raise exception 'Invalid event access code'; end if;

  update public.field_sessions set active=false,ended_at=now() where auth_user_id=auth.uid() and active=true;
  update public.treatment_area_sessions set active=false,ended_at=now() where auth_user_id=auth.uid() and active=true;

  insert into public.field_sessions(event_id,auth_user_id,operator_name)
  values(e.id,auth.uid(),nullif(trim(p_operator_name),'')) returning * into fs;

  insert into public.cad_activity(event_id,action,detail,actor_user_id,actor_kind)
  values(e.id,'FIELD_SESSION_STARTED',jsonb_build_object('field_session_id',fs.id),auth.uid(),'field');
  return fs;
end;
$$;

-- ============================================================
-- RLS
-- ============================================================

-- Extend existing core read policies so treatment-area stations can read only the
-- event/unit metadata they need, plus incidents linked to patients that passed
-- through their station.
drop policy if exists "event read" on public.events;
create policy "event read" on public.events for select to authenticated
using(
  public.has_event_staff_access(id)
  or public.field_has_event_access(id)
  or private.treatment_has_event_access(id)
);

drop policy if exists "units read" on public.units;
create policy "units read" on public.units for select to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.treatment_has_event_access(event_id)
);

drop policy if exists "incidents read" on public.incidents;
create policy "incidents read" on public.incidents for select to authenticated
using(
  public.has_event_staff_access(event_id)
  or private.field_can_read_incident(id)
  or private.treatment_can_read_incident(id)
);

alter table public.ems_unit_config enable row level security;
alter table public.ems_treatment_areas enable row level security;
alter table public.treatment_area_sessions enable row level security;
alter table public.ems_encounters enable row level security;
alter table public.ems_handoffs enable row level security;

create policy "ems unit config read"
on public.ems_unit_config for select to authenticated
using (private.can_read_ems_resource_event(private.ems_config_event(unit_id)));

create policy "ems unit config admin insert"
on public.ems_unit_config for insert to authenticated
with check (public.can_admin_event(private.ems_config_event(unit_id)));

create policy "ems unit config admin update"
on public.ems_unit_config for update to authenticated
using (public.can_admin_event(private.ems_config_event(unit_id)))
with check (public.can_admin_event(private.ems_config_event(unit_id)));

create policy "ems unit config admin delete"
on public.ems_unit_config for delete to authenticated
using (public.can_admin_event(private.ems_config_event(unit_id)));

create policy "ems treatment areas read"
on public.ems_treatment_areas for select to authenticated
using (private.can_read_ems_resource_event(event_id));

create policy "ems treatment areas admin insert"
on public.ems_treatment_areas for insert to authenticated
with check (public.can_admin_event(event_id));

create policy "ems treatment areas admin update"
on public.ems_treatment_areas for update to authenticated
using (public.can_admin_event(event_id))
with check (public.can_admin_event(event_id));

create policy "ems treatment areas admin delete"
on public.ems_treatment_areas for delete to authenticated
using (public.can_admin_event(event_id));

create policy "treatment own session read"
on public.treatment_area_sessions for select to authenticated
using (auth_user_id=auth.uid());

create policy "treatment sessions staff read"
on public.treatment_area_sessions for select to authenticated
using (public.has_event_staff_access(event_id));

create policy "ems encounters read"
on public.ems_encounters for select to authenticated
using (private.can_read_ems_encounter(id));

create policy "ems handoffs read"
on public.ems_handoffs for select to authenticated
using (private.can_read_ems_handoff(id));

-- ============================================================
-- GRANTS
-- ============================================================

grant select on public.ems_unit_config,public.ems_treatment_areas,public.treatment_area_sessions,
  public.ems_encounters,public.ems_handoffs to authenticated;

grant insert,update,delete on public.ems_unit_config,public.ems_treatment_areas to authenticated;

grant execute on function public.treatment_enter_event(text,text,text) to authenticated;
grant execute on function public.treatment_claim_area(uuid,uuid) to authenticated;
grant execute on function public.treatment_release_area(uuid) to authenticated;
grant execute on function public.treatment_end_session(uuid) to authenticated;
grant execute on function public.treatment_set_status(uuid,text,boolean) to authenticated;
grant execute on function public.ems_create_encounter(uuid,uuid,uuid,uuid,text) to authenticated;
grant execute on function public.ems_request_handoff(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.ems_accept_handoff(uuid) to authenticated;
grant execute on function public.ems_decline_handoff(uuid,text) to authenticated;
grant execute on function public.ems_cancel_handoff(uuid) to authenticated;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;
grant execute on function public.ems_mark_transporting(uuid,text) to authenticated;
grant execute on function public.ems_complete_transport(uuid,text) to authenticated;

-- ============================================================
-- REALTIME
-- ============================================================

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='ems_encounters') then
    alter publication supabase_realtime add table public.ems_encounters;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='ems_handoffs') then
    alter publication supabase_realtime add table public.ems_handoffs;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='ems_treatment_areas') then
    alter publication supabase_realtime add table public.ems_treatment_areas;
  end if;
end $$;
