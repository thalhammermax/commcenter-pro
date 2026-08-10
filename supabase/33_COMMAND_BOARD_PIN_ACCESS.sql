-- CommCenter Pro v0.13.1
-- Standalone Command Board access using Event ID + the event's existing 4-digit PIN.
-- Named staff retain the existing Dispatcher -> Command Display shortcut.

-- ============================================================
-- COMMAND DISPLAY SESSIONS
-- ============================================================

create table if not exists public.command_display_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  operator_name text,
  active boolean not null default true,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz
);

create index if not exists command_display_sessions_event_idx
  on public.command_display_sessions(event_id,active,started_at desc);

create unique index if not exists command_display_sessions_one_active_per_auth_idx
  on public.command_display_sessions(auth_user_id)
  where active=true;

alter table public.command_display_sessions enable row level security;

drop policy if exists command_display_sessions_own_read on public.command_display_sessions;
create policy command_display_sessions_own_read
on public.command_display_sessions
for select
to authenticated
using(auth_user_id=auth.uid());

grant select on public.command_display_sessions to authenticated;

-- ============================================================
-- ACCESS HELPER
-- ============================================================

create or replace function private.command_has_event_access(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists(
    select 1
    from public.command_display_sessions cs
    join public.events e on e.id=cs.event_id
    where cs.event_id=p_event_id
      and cs.auth_user_id=(select auth.uid())
      and cs.active=true
      and e.active=true
      and e.field_access_enabled=true
  );
$$;

revoke all on function private.command_has_event_access(uuid) from public;
grant execute on function private.command_has_event_access(uuid) to authenticated;

-- ============================================================
-- LOGIN / LOGOUT RPCs
-- ============================================================

create or replace function public.command_enter_event(
  p_event_code text,
  p_pin text,
  p_operator_name text default null
)
returns public.command_display_sessions
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.events;
  cs public.command_display_sessions;
begin
  select * into e
  from public.events
  where upper(event_code)=upper(trim(p_event_code))
    and active=true
    and field_access_enabled=true;

  if e.id is null then
    raise exception 'Event not found or specialty access is disabled';
  end if;

  if e.field_pin_hash is null
     or crypt(p_pin,e.field_pin_hash)<>e.field_pin_hash
  then
    raise exception 'Invalid event access code';
  end if;

  update public.command_display_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where auth_user_id=auth.uid()
    and active=true;

  update public.field_sessions
  set
    active=false,
    ended_at=now(),
    last_seen_at=now(),
    end_reason='REPLACED_BY_COMMAND_BOARD_LOGIN'
  where auth_user_id=auth.uid()
    and active=true;

  update public.treatment_area_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where auth_user_id=auth.uid()
    and active=true;

  insert into public.command_display_sessions(
    event_id,
    auth_user_id,
    operator_name
  ) values(
    e.id,
    auth.uid(),
    nullif(trim(p_operator_name),'')
  )
  returning * into cs;

  return cs;
end;
$$;

create or replace function public.command_end_session(p_command_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.command_display_sessions
  set
    active=false,
    ended_at=now(),
    last_seen_at=now()
  where id=p_command_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

revoke all on function public.command_enter_event(text,text,text) from public;
revoke all on function public.command_end_session(uuid) from public;
grant execute on function public.command_enter_event(text,text,text) to authenticated;
grant execute on function public.command_end_session(uuid) to authenticated;

-- One anonymous browser identity should not operate multiple specialty modes
-- simultaneously. Starting Field/Treatment access invalidates Command Board.
create or replace function private.end_command_session_on_specialty_login()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.command_display_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where auth_user_id=new.auth_user_id
    and active=true;
  return new;
end;
$$;

drop trigger if exists end_command_session_on_field_login on public.field_sessions;
create trigger end_command_session_on_field_login
after insert on public.field_sessions
for each row
execute function private.end_command_session_on_specialty_login();

drop trigger if exists end_command_session_on_treatment_login on public.treatment_area_sessions;
create trigger end_command_session_on_treatment_login
after insert on public.treatment_area_sessions
for each row
execute function private.end_command_session_on_specialty_login();

-- Archive / specialty-access disable invalidates standalone Command Boards.
create or replace function private.end_command_sessions_when_event_access_stops()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if (old.active=true and new.active=false)
     or (old.field_access_enabled=true and new.field_access_enabled=false)
  then
    update public.command_display_sessions
    set active=false,ended_at=now(),last_seen_at=now()
    where event_id=old.id
      and active=true;
  end if;
  return new;
end;
$$;

drop trigger if exists end_command_sessions_when_event_access_stops on public.events;
create trigger end_command_sessions_when_event_access_stops
after update of active,field_access_enabled on public.events
for each row
execute function private.end_command_sessions_when_event_access_stops();

-- ============================================================
-- READ-ONLY COMMAND BOARD RLS
-- ============================================================

drop policy if exists "event read" on public.events;
create policy "event read"
on public.events
for select
to authenticated
using(
  public.has_event_staff_access(id)
  or public.field_has_event_access(id)
  or private.treatment_has_event_access(id)
  or private.command_has_event_access(id)
);

drop policy if exists "departments read" on public.event_departments;
create policy "departments read"
on public.event_departments
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.command_has_event_access(event_id)
);

drop policy if exists "units read" on public.units;
create policy "units read"
on public.units
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.treatment_has_event_access(event_id)
  or private.command_has_event_access(event_id)
);

drop policy if exists "incidents read" on public.incidents;
create policy "incidents read"
on public.incidents
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or private.field_can_read_incident(id)
  or private.treatment_can_read_incident(id)
  or private.command_has_event_access(event_id)
);

drop policy if exists "incident departments read" on public.incident_departments;
create policy "incident departments read"
on public.incident_departments
for select
to authenticated
using(
  exists(
    select 1
    from public.incidents i
    where i.id=incident_id
      and (
        public.has_event_staff_access(i.event_id)
        or private.command_has_event_access(i.event_id)
      )
  )
);

drop policy if exists "incident units read" on public.incident_units;
create policy "incident units read"
on public.incident_units
for select
to authenticated
using(
  exists(
    select 1
    from public.incidents i
    where i.id=incident_id
      and (
        public.has_event_staff_access(i.event_id)
        or private.command_has_event_access(i.event_id)
      )
  )
  or public.field_has_unit_access(unit_id)
);

drop policy if exists "map layers read" on public.event_map_layers;
create policy "map layers read"
on public.event_map_layers
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.command_has_event_access(event_id)
);

drop policy if exists "zones read" on public.event_zones;
create policy "zones read"
on public.event_zones
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.command_has_event_access(event_id)
);

drop policy if exists "unit locations read" on public.unit_locations;
create policy "unit locations read"
on public.unit_locations
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_unit_access(unit_id)
  or private.command_has_event_access(event_id)
);

drop policy if exists operational_periods_select_access on public.operational_periods;
create policy operational_periods_select_access
on public.operational_periods
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.command_has_event_access(event_id)
);

-- Treatment Area names are needed for unit destination labels; clinical EMS
-- encounter/handoff rows remain outside the standalone Command Board loader.
create or replace function private.can_read_ems_resource_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select public.has_event_staff_access(p_event_id)
      or public.field_has_event_access(p_event_id)
      or private.treatment_has_event_access(p_event_id)
      or private.command_has_event_access(p_event_id);
$$;

-- Allow signed URLs for the private map image used by Command Board map view.
create or replace function public.storage_event_access(object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,storage
as $$
declare
  folder text;
  eid uuid;
begin
  folder:=(storage.foldername(object_name))[1];
  if folder is null
     or folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return false;
  end if;

  eid:=folder::uuid;
  return public.has_event_staff_access(eid)
      or public.field_has_event_access(eid)
      or private.command_has_event_access(eid);
end;
$$;

-- ============================================================
-- REALTIME
-- ============================================================

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='command_display_sessions'
  ) then
    alter publication supabase_realtime add table public.command_display_sessions;
  end if;
end $$;
