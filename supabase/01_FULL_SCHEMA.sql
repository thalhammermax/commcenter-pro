create extension if not exists pgcrypto;

-- ============================================================
-- TENANCY / USERS
-- ============================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

create table public.platform_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  plan text not null default 'starter',
  status text not null default 'active' check(status in ('trial','active','suspended')),
  created_at timestamptz not null default now()
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check(role in ('owner','admin','dispatcher','viewer')),
  primary key(organization_id,user_id)
);

-- ============================================================
-- EVENTS / DEPARTMENTS / UNITS
-- ============================================================

create table public.events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  slug text not null,
  event_code text not null unique,
  field_pin_hash text,
  field_access_enabled boolean not null default false,
  incident_prefix text not null default 'INC',
  next_incident_number integer not null default 1,
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  unique(organization_id,slug)
);

create table public.event_staff (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check(role in ('event_admin','dispatcher','supervisor','viewer')),
  all_departments boolean not null default true,
  primary key(event_id,user_id)
);

create table public.event_departments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  short_name text,
  status_profile jsonb not null default '["AVAILABLE","RESPONDING","ON_SCENE","CLEAR","OUT_OF_SERVICE"]'::jsonb,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(event_id,name)
);

create table public.staff_department_access (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  department_id uuid not null references public.event_departments(id) on delete cascade,
  primary key(event_id,user_id,department_id)
);

create table public.units (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  department_id uuid not null references public.event_departments(id) on delete cascade,
  name text not null,
  status text not null default 'AVAILABLE',
  home_landmark text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(event_id,name)
);

-- ============================================================
-- FIELD DEVICE SESSIONS
-- ============================================================

create table public.field_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  operator_name text,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz,
  active boolean not null default true
);

create index field_sessions_auth_active_idx on public.field_sessions(auth_user_id,active);
create index field_sessions_unit_active_idx on public.field_sessions(unit_id,active);

-- ============================================================
-- MAP BUILDER
-- ============================================================

create table public.event_maps (
  event_id uuid primary key references public.events(id) on delete cascade,
  source_pdf_path text,
  rendered_image_path text,
  image_width integer,
  image_height integer,
  georef_method text,
  georef_coefficients jsonb,
  georef_rmse_m double precision,
  georef_max_error_m double precision,
  offline_w3w_path text,
  status text not null default 'draft' check(status in ('draft','calibrated','published')),
  published_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.map_control_points (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  label text not null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision not null,
  longitude double precision not null,
  residual_m double precision,
  created_at timestamptz not null default now()
);

create index map_control_points_event_idx on public.map_control_points(event_id);

create table public.event_w3w_squares (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  words text not null,
  south double precision not null,
  north double precision not null,
  west double precision not null,
  east double precision not null,
  center_lat double precision,
  center_lon double precision,
  unique(event_id,words)
);

create index event_w3w_bounds_idx on public.event_w3w_squares(event_id,south,north,west,east);

create table public.event_pois (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  category text,
  w3w_square_id bigint references public.event_w3w_squares(id) on delete set null,
  w3w text,
  latitude double precision not null,
  longitude double precision not null,
  map_x double precision not null,
  map_y double precision not null,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index event_pois_event_idx on public.event_pois(event_id);

create table public.poi_aliases (
  id bigint generated always as identity primary key,
  poi_id uuid not null references public.event_pois(id) on delete cascade,
  alias text not null,
  unique(poi_id,alias)
);

-- ============================================================
-- INCIDENTS / AUDIT
-- ============================================================

create table public.incidents (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  incident_number text not null,
  call_type text not null,
  priority text not null default 'Standard',
  status text not null default 'OPEN' check(status in ('OPEN','CLOSED')),
  poi_id uuid references public.event_pois(id) on delete set null,
  latitude double precision not null,
  longitude double precision not null,
  map_x double precision,
  map_y double precision,
  w3w text,
  landmark text,
  notes text,
  disposition text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  unique(event_id,incident_number)
);

create table public.incident_departments (
  incident_id uuid not null references public.incidents(id) on delete cascade,
  department_id uuid not null references public.event_departments(id) on delete cascade,
  primary key(incident_id,department_id)
);

create table public.incident_units (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.incidents(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  cleared_at timestamptz,
  unique(incident_id,unit_id)
);

create index incident_units_unit_active_idx on public.incident_units(unit_id,cleared_at);

create table public.unit_status_log (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  incident_id uuid references public.incidents(id) on delete set null,
  unit_id uuid not null references public.units(id) on delete cascade,
  old_status text,
  new_status text not null,
  actor_user_id uuid references auth.users(id),
  actor_kind text not null default 'staff' check(actor_kind in ('staff','field')),
  client_time timestamptz,
  server_time timestamptz not null default now()
);

create table public.cad_activity (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  incident_id uuid references public.incidents(id) on delete set null,
  unit_id uuid references public.units(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor_user_id uuid references auth.users(id),
  actor_kind text not null default 'staff' check(actor_kind in ('staff','field','system','treatment')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- USER CREATION TRIGGER
-- ============================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path=public
as $$
begin
  insert into public.profiles(id,display_name)
  values(new.id,coalesce(new.raw_user_meta_data->>'display_name',split_part(coalesce(new.email,'field'),'@',1)))
  on conflict(id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- ============================================================
-- ACCESS HELPERS
-- ============================================================

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.platform_admins where user_id=auth.uid()); $$;

create or replace function public.has_org_access(p_org uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.organization_members where organization_id=p_org and user_id=auth.uid()); $$;

create or replace function public.is_org_admin(p_org uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.organization_members where organization_id=p_org and user_id=auth.uid() and role in ('owner','admin')); $$;

create or replace function public.has_event_staff_access(p_event uuid)
returns boolean language sql stable security definer set search_path=public
as $$
select exists(
  select 1 from public.events e
  left join public.organization_members om on om.organization_id=e.organization_id and om.user_id=auth.uid()
  left join public.event_staff es on es.event_id=e.id and es.user_id=auth.uid()
  where e.id=p_event and (om.user_id is not null or es.user_id is not null)
);
$$;

create or replace function public.can_admin_event(p_event uuid)
returns boolean language sql stable security definer set search_path=public
as $$
select exists(
  select 1 from public.events e
  left join public.organization_members om on om.organization_id=e.organization_id and om.user_id=auth.uid()
  left join public.event_staff es on es.event_id=e.id and es.user_id=auth.uid()
  where e.id=p_event and (om.role in ('owner','admin') or es.role='event_admin')
);
$$;

create or replace function public.can_dispatch_event(p_event uuid)
returns boolean language sql stable security definer set search_path=public
as $$
select exists(
  select 1 from public.events e
  left join public.organization_members om on om.organization_id=e.organization_id and om.user_id=auth.uid()
  left join public.event_staff es on es.event_id=e.id and es.user_id=auth.uid()
  where e.id=p_event and (om.role in ('owner','admin','dispatcher') or es.role in ('event_admin','dispatcher','supervisor'))
);
$$;

create or replace function public.field_has_event_access(p_event uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.field_sessions where event_id=p_event and auth_user_id=auth.uid() and active=true); $$;

create or replace function public.field_has_unit_access(p_unit uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.field_sessions where unit_id=p_unit and auth_user_id=auth.uid() and active=true); $$;


-- RLS helper: checks whether the current anonymous/authenticated field session
-- is assigned to an active unit on an incident. Kept outside the exposed public
-- schema so it can safely bypass RLS on the join tables without creating a
-- circular incidents <-> incident_units policy dependency.
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

revoke all on function private.field_can_read_incident(uuid) from public;
grant execute on function private.field_can_read_incident(uuid) to authenticated;

create or replace function public.storage_event_access(object_name text)
returns boolean language plpgsql stable security definer set search_path=public,storage
as $$
declare folder text; eid uuid;
begin
  folder := (storage.foldername(object_name))[1];
  if folder is null or folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  eid := folder::uuid;
  return public.has_event_staff_access(eid) or public.field_has_event_access(eid);
end;
$$;

create or replace function public.storage_event_admin(object_name text)
returns boolean language plpgsql stable security definer set search_path=public,storage
as $$
declare folder text; eid uuid;
begin
  folder := (storage.foldername(object_name))[1];
  if folder is null or folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  eid := folder::uuid;
  return public.can_admin_event(eid);
end;
$$;

-- ============================================================
-- STAFF RPCs
-- ============================================================

create or replace function public.platform_create_organization(p_name text)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare oid uuid; slug text;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin access required'; end if;
  if trim(p_name)='' then raise exception 'Organization name is required'; end if;
  slug:=trim(both '-' from regexp_replace(lower(trim(p_name)),'[^a-z0-9]+','-','g'));
  insert into public.organizations(name,slug) values(trim(p_name),slug) returning id into oid;
  insert into public.organization_members(organization_id,user_id,role) values(oid,auth.uid(),'owner');
  return oid;
end;
$$;

create or replace function public.add_existing_org_member(p_organization_id uuid,p_email text,p_role text)
returns void
language plpgsql security definer set search_path=public,auth
as $$
declare uid uuid;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'Organization admin access required'; end if;
  if p_role not in ('owner','admin','dispatcher','viewer') then raise exception 'Invalid organization role'; end if;
  select id into uid from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  if uid is null then raise exception 'No Supabase Auth user exists with that email. Create the user in Authentication first.'; end if;
  insert into public.organization_members(organization_id,user_id,role)
  values(p_organization_id,uid,p_role)
  on conflict(organization_id,user_id) do update set role=excluded.role;
end;
$$;

create or replace function public.staff_events_for_org(p_organization_id uuid)
returns table(id uuid,name text,event_code text,active boolean,staff_role text)
language sql stable security definer set search_path=public
as $$
select e.id,e.name,e.event_code,e.active,
  case when om.role is not null then om.role else es.role end
from public.events e
left join public.organization_members om on om.organization_id=e.organization_id and om.user_id=auth.uid()
left join public.event_staff es on es.event_id=e.id and es.user_id=auth.uid()
where e.organization_id=p_organization_id and (om.user_id is not null or es.user_id is not null)
order by e.starts_at desc nulls last,e.name;
$$;

create or replace function public.create_event(
  p_organization_id uuid,p_name text,p_event_code text,p_pin text,p_incident_prefix text
) returns uuid
language plpgsql security definer set search_path=public,extensions
as $$
declare eid uuid; slug text;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'Organization admin access required'; end if;
  if trim(p_name)='' then raise exception 'Event name is required'; end if;
  if trim(p_event_code)='' then raise exception 'Event ID is required'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'Field PIN must be exactly 4 digits'; end if;
  slug:=trim(both '-' from regexp_replace(lower(trim(p_name)),'[^a-z0-9]+','-','g'));

  insert into public.events(organization_id,name,slug,event_code,field_pin_hash,field_access_enabled,incident_prefix)
  values(p_organization_id,trim(p_name),slug,upper(trim(p_event_code)),crypt(p_pin,gen_salt('bf')),true,coalesce(nullif(upper(trim(p_incident_prefix)),''),'INC'))
  returning id into eid;
  return eid;
end;
$$;

create or replace function public.set_event_field_access(p_event_id uuid,p_pin text,p_enabled boolean)
returns void
language plpgsql security definer set search_path=public,extensions
as $$
begin
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;
  if p_pin is not null and p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits'; end if;

  update public.events
  set field_access_enabled=p_enabled,
      field_pin_hash=case when p_pin is null then field_pin_hash else crypt(p_pin,gen_salt('bf')) end
  where id=p_event_id;
end;
$$;

create or replace function public.create_incident(
  p_event_id uuid,p_department_ids uuid[],p_call_type text,p_priority text,
  p_latitude double precision,p_longitude double precision,p_map_x double precision,p_map_y double precision,
  p_w3w text,p_landmark text,p_notes text,p_poi_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare n integer; prefix text; number text; iid uuid; d uuid;
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if array_length(p_department_ids,1) is null then raise exception 'At least one department is required'; end if;

  update public.events set next_incident_number=next_incident_number+1 where id=p_event_id
  returning next_incident_number-1,incident_prefix into n,prefix;
  number:=prefix||'-'||lpad(n::text,3,'0');

  insert into public.incidents(
    event_id,incident_number,call_type,priority,poi_id,latitude,longitude,map_x,map_y,w3w,landmark,notes,created_by
  ) values(
    p_event_id,number,p_call_type,p_priority,p_poi_id,p_latitude,p_longitude,p_map_x,p_map_y,p_w3w,p_landmark,p_notes,auth.uid()
  ) returning id into iid;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    select iid,d where exists(select 1 from public.event_departments where id=d and event_id=p_event_id);
  end loop;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,iid,'INCIDENT_CREATED',jsonb_build_object('incident_number',number,'call_type',p_call_type),auth.uid(),'staff');
  return iid;
end;
$$;

-- CommCenter Pro v0.3.1
-- Dispatcher assignment / unit-control upgrade.
-- Safe to run on an existing v0.3.0 database.
-- No existing incidents or EMS encounter data are deleted.

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
    raise exception 'Unit is already assigned to %', other_incident;
  end if;

  select status into old_s
  from public.units
  where id=p_unit_id;

  insert into public.incident_units(incident_id,unit_id)
  values(p_incident_id,p_unit_id)
  on conflict(incident_id,unit_id)
  do update set assigned_at=now(),cleared_at=null;

  update public.units
  set status='ASSIGNED'
  where id=p_unit_id;

  if old_s is distinct from 'ASSIGNED' then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind
    )
    values(
      eid,p_incident_id,p_unit_id,old_s,'ASSIGNED',
      auth.uid(),'staff'
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,actor_user_id,actor_kind
  )
  values(
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

  update public.units
  set status=p_new_status
  where id=p_unit_id;

  if old_s is distinct from p_new_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind
    )
    values(
      eid,p_incident_id,p_unit_id,old_s,p_new_status,
      auth.uid(),'staff'
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  )
  values(
    eid,p_incident_id,p_unit_id,'UNIT_UNASSIGNED',
    jsonb_build_object('new_status',p_new_status),
    auth.uid(),'staff'
  );
end;
$$;


create or replace function public.staff_set_unit_status(
  p_unit_id uuid,
  p_status text,
  p_incident_id uuid default null
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
begin
  select u.event_id,u.status,d.status_profile
  into eid,old_s,dep_statuses
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
    where id=p_incident_id and event_id=eid
  ) then
    raise exception 'Incident is not part of this event';
  end if;

  if p_status<>'ASSIGNED' and not (dep_statuses ? p_status) then
    raise exception 'Status % is not allowed for this department', p_status;
  end if;

  update public.units
  set status=p_status
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind
    )
    values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
      auth.uid(),'staff'
    );

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    )
    values(
      eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',
      jsonb_build_object('from',old_s,'to',p_status),
      auth.uid(),'staff'
    );
  end if;
end;
$$;

-- CommCenter Pro v0.4.4
-- Editable incident details for Dispatch.
-- Existing incidents are preserved.

create or replace function public.update_incident_v2(
  p_incident_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  d uuid;
  old_row public.incidents;
begin
  select *
  into old_row
  from public.incidents
  where id=p_incident_id;

  if old_row.id is null then
    raise exception 'Incident not found';
  end if;

  eid:=old_row.event_id;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  if old_row.status='CLOSED' then
    raise exception 'Closed incidents cannot be edited from the active CAD';
  end if;

  if trim(coalesce(p_call_type,''))='' then
    raise exception 'Call type is required';
  end if;

  if array_length(p_department_ids,1) is null then
    raise exception 'At least one department is required';
  end if;

  if p_map_layer_id is not null and not exists(
    select 1 from public.event_map_layers
    where id=p_map_layer_id and event_id=eid and active=true
  ) then
    raise exception 'Map layer is not part of this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1 from public.event_zones
    where id=p_zone_id and event_id=eid and active=true
      and (p_map_layer_id is null or map_layer_id=p_map_layer_id)
  ) then
    raise exception 'Zone is not valid for this event/map layer';
  end if;

  if p_poi_id is not null and not exists(
    select 1 from public.event_pois
    where id=p_poi_id and event_id=eid and active=true
  ) then
    raise exception 'POI is not part of this event';
  end if;

  -- Validate every requested department before changing the link table.
  foreach d in array p_department_ids loop
    if not exists(
      select 1 from public.event_departments
      where id=d and event_id=eid and active=true
    ) then
      raise exception 'One or more selected departments are invalid for this event';
    end if;
  end loop;

  update public.incidents
  set
    call_type=trim(p_call_type),
    priority=p_priority,
    poi_id=p_poi_id,
    map_layer_id=p_map_layer_id,
    zone_id=p_zone_id,
    latitude=p_latitude,
    longitude=p_longitude,
    map_x=p_map_x,
    map_y=p_map_y,
    w3w=nullif(trim(p_w3w),''),
    landmark=nullif(trim(p_landmark),''),
    notes=nullif(trim(p_notes),'')
  where id=p_incident_id;

  delete from public.incident_departments
  where incident_id=p_incident_id;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    values(p_incident_id,d)
    on conflict do nothing;
  end loop;

  insert into public.cad_activity(
    event_id,
    incident_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    eid,
    p_incident_id,
    'INCIDENT_UPDATED',
    jsonb_build_object(
      'incident_number',old_row.incident_number,
      'old_call_type',old_row.call_type,
      'new_call_type',trim(p_call_type),
      'old_priority',old_row.priority,
      'new_priority',p_priority,
      'old_landmark',old_row.landmark,
      'new_landmark',nullif(trim(p_landmark),''),
      'old_poi_id',old_row.poi_id,
      'new_poi_id',p_poi_id,
      'old_map_layer_id',old_row.map_layer_id,
      'new_map_layer_id',p_map_layer_id,
      'old_zone_id',old_row.zone_id,
      'new_zone_id',p_zone_id
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

create or replace function public.close_incident(p_incident_id uuid,p_disposition text default null)
returns void
language plpgsql security definer set search_path=public
as $$
declare eid uuid;
begin
  select event_id into eid from public.incidents where id=p_incident_id;
  if not public.can_dispatch_event(eid) then raise exception 'Dispatch access required'; end if;
  update public.incidents set status='CLOSED',closed_at=now(),disposition=p_disposition where id=p_incident_id;
  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(eid,p_incident_id,'INCIDENT_CLOSED',jsonb_build_object('disposition',p_disposition),auth.uid(),'staff');
end;
$$;

-- ============================================================
-- W3W RPCs
-- ============================================================

create or replace function public.w3w_for_coordinate(p_event_id uuid,p_lat double precision,p_lon double precision)
returns text
language plpgsql stable security definer set search_path=public
as $$
declare result text;
begin
  if not (public.has_event_staff_access(p_event_id) or public.field_has_event_access(p_event_id)) then
    raise exception 'Not authorized';
  end if;
  select words into result
  from public.event_w3w_squares
  where event_id=p_event_id and p_lat>=south and p_lat<north and p_lon>=west and p_lon<east
  limit 1;
  return result;
end;
$$;

create or replace function public.w3w_squares_in_bounds(
  p_event_id uuid,p_south double precision,p_north double precision,p_west double precision,p_east double precision,p_limit integer default 2500
)
returns table(words text,south double precision,north double precision,west double precision,east double precision)
language plpgsql stable security definer set search_path=public
as $$
begin
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;
  return query
  select s.words,s.south,s.north,s.west,s.east
  from public.event_w3w_squares s
  where s.event_id=p_event_id
    and s.north>=p_south and s.south<=p_north
    and s.east>=p_west and s.west<=p_east
  limit least(greatest(p_limit,1),2500);
end;
$$;

-- ============================================================
-- FIELD RPCs
-- ============================================================

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
  insert into public.field_sessions(event_id,auth_user_id,operator_name)
  values(e.id,auth.uid(),nullif(trim(p_operator_name),'')) returning * into fs;

  insert into public.cad_activity(event_id,action,detail,actor_user_id,actor_kind)
  values(e.id,'FIELD_SESSION_STARTED',jsonb_build_object('field_session_id',fs.id),auth.uid(),'field');
  return fs;
end;
$$;

create or replace function public.field_claim_unit(p_field_session_id uuid,p_unit_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
declare fs public.field_sessions;
begin
  select * into fs from public.field_sessions where id=p_field_session_id and auth_user_id=auth.uid() and active=true;
  if fs.id is null then raise exception 'Field session not found'; end if;
  if not exists(select 1 from public.units where id=p_unit_id and event_id=fs.event_id and active=true) then raise exception 'Invalid unit'; end if;
  update public.field_sessions set unit_id=p_unit_id,last_seen_at=now() where id=fs.id;
end;
$$;

create or replace function public.field_release_unit(p_field_session_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
begin
  update public.field_sessions set unit_id=null,last_seen_at=now()
  where id=p_field_session_id and auth_user_id=auth.uid() and active=true;
end;
$$;

create or replace function public.field_end_session(p_field_session_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
begin
  update public.field_sessions set active=false,ended_at=now(),last_seen_at=now()
  where id=p_field_session_id and auth_user_id=auth.uid() and active=true;
end;
$$;

create or replace function public.field_set_unit_status(
  p_unit_id uuid,p_status text,p_incident_id uuid default null,p_client_time timestamptz default null
) returns void
language plpgsql security definer set search_path=public
as $$
declare eid uuid; old_s text; allowed jsonb;
begin
  if not public.field_has_unit_access(p_unit_id) then raise exception 'Not authorized for this unit'; end if;

  select u.event_id,u.status,d.status_profile into eid,old_s,allowed
  from public.units u join public.event_departments d on d.id=u.department_id where u.id=p_unit_id;

  if not (allowed ? p_status) then raise exception 'Status not allowed for this department'; end if;

  update public.units set status=p_status where id=p_unit_id;
  insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind,client_time)
  values(eid,p_incident_id,p_unit_id,old_s,p_status,auth.uid(),'field',p_client_time);
  insert into public.cad_activity(event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',jsonb_build_object('from',old_s,'to',p_status),auth.uid(),'field');

  if p_incident_id is not null and p_status in ('AVAILABLE','CLEAR','COMPLETE') then
    update public.incident_units set cleared_at=now()
    where incident_id=p_incident_id and unit_id=p_unit_id and cleared_at is null;
  end if;
end;
$$;

-- ============================================================
-- REPORT VIEW
-- ============================================================

create or replace view public.dispatch_log
with (security_invoker=true)
as
select
  i.event_id,i.incident_number,i.created_at as received_time,
  string_agg(distinct d.short_name,', ' order by d.short_name) as departments,
  i.call_type,i.priority,i.landmark,i.w3w,i.latitude,i.longitude,i.disposition,
  string_agg(distinct u.name,', ' order by u.name) as units,
  min(sl.server_time) filter(where sl.new_status in ('RESPONDING','EN_ROUTE')) as first_enroute,
  min(sl.server_time) filter(where sl.new_status='ON_SCENE') as first_onscene,
  min(sl.server_time) filter(where sl.new_status='TRANSPORTING') as first_transporting,
  max(sl.server_time) filter(where sl.new_status in ('AVAILABLE','CLEAR','COMPLETE')) as last_clear,
  i.closed_at
from public.incidents i
left join public.incident_departments idept on idept.incident_id=i.id
left join public.event_departments d on d.id=idept.department_id
left join public.incident_units iu on iu.incident_id=i.id
left join public.units u on u.id=iu.unit_id
left join public.unit_status_log sl on sl.incident_id=i.id
group by i.id;

-- ============================================================
-- STORAGE BUCKET
-- ============================================================

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values(
  'event-assets','event-assets',false,52428800,
  array['application/pdf','image/webp','application/json']
)
on conflict(id) do update
set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

-- ============================================================
-- RLS
-- ============================================================

alter table public.profiles enable row level security;
alter table public.platform_admins enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.events enable row level security;
alter table public.event_staff enable row level security;
alter table public.event_departments enable row level security;
alter table public.staff_department_access enable row level security;
alter table public.units enable row level security;
alter table public.field_sessions enable row level security;
alter table public.event_maps enable row level security;
alter table public.map_control_points enable row level security;
alter table public.event_w3w_squares enable row level security;
alter table public.event_pois enable row level security;
alter table public.poi_aliases enable row level security;
alter table public.incidents enable row level security;
alter table public.incident_departments enable row level security;
alter table public.incident_units enable row level security;
alter table public.unit_status_log enable row level security;
alter table public.cad_activity enable row level security;

create policy "profile self read" on public.profiles for select using(id=auth.uid());
create policy "platform admin self read" on public.platform_admins for select using(user_id=auth.uid());
create policy "org members read org" on public.organizations for select using(public.has_org_access(id) or public.is_platform_admin());
create policy "org membership read" on public.organization_members for select using(user_id=auth.uid() or public.is_org_admin(organization_id));
create policy "event read" on public.events for select using(public.has_event_staff_access(id) or public.field_has_event_access(id));
create policy "event staff read" on public.event_staff for select using(public.has_event_staff_access(event_id));

create policy "departments read" on public.event_departments for select using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "departments admin insert" on public.event_departments for insert with check(public.can_admin_event(event_id));
create policy "departments admin update" on public.event_departments for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "departments admin delete" on public.event_departments for delete using(public.can_admin_event(event_id));

create policy "staff dept access read" on public.staff_department_access for select using(public.has_event_staff_access(event_id));

create policy "units read" on public.units for select using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "units admin insert" on public.units for insert with check(public.can_admin_event(event_id));
create policy "units admin update" on public.units for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "units admin delete" on public.units for delete using(public.can_admin_event(event_id));

create policy "field own sessions read" on public.field_sessions for select using(auth_user_id=auth.uid());
create policy "staff field sessions read" on public.field_sessions for select using(public.has_event_staff_access(event_id));

create policy "event maps read" on public.event_maps for select using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "event maps admin insert" on public.event_maps for insert with check(public.can_admin_event(event_id));
create policy "event maps admin update" on public.event_maps for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "event maps admin delete" on public.event_maps for delete using(public.can_admin_event(event_id));

create policy "control points staff read" on public.map_control_points for select using(public.has_event_staff_access(event_id));
create policy "control points admin insert" on public.map_control_points for insert with check(public.can_admin_event(event_id));
create policy "control points admin update" on public.map_control_points for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "control points admin delete" on public.map_control_points for delete using(public.can_admin_event(event_id));

create policy "w3w staff read" on public.event_w3w_squares for select using(public.has_event_staff_access(event_id));
create policy "w3w admin insert" on public.event_w3w_squares for insert with check(public.can_admin_event(event_id));
create policy "w3w admin update" on public.event_w3w_squares for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "w3w admin delete" on public.event_w3w_squares for delete using(public.can_admin_event(event_id));

create policy "poi read" on public.event_pois for select using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "poi admin insert" on public.event_pois for insert with check(public.can_admin_event(event_id));
create policy "poi admin update" on public.event_pois for update using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "poi admin delete" on public.event_pois for delete using(public.can_admin_event(event_id));

create policy "poi aliases read" on public.poi_aliases for select using(
  exists(select 1 from public.event_pois p where p.id=poi_id and (public.has_event_staff_access(p.event_id) or public.field_has_event_access(p.event_id)))
);
create policy "poi aliases admin insert" on public.poi_aliases for insert with check(
  exists(select 1 from public.event_pois p where p.id=poi_id and public.can_admin_event(p.event_id))
);
create policy "poi aliases admin update" on public.poi_aliases for update using(
  exists(select 1 from public.event_pois p where p.id=poi_id and public.can_admin_event(p.event_id))
);
create policy "poi aliases admin delete" on public.poi_aliases for delete using(
  exists(select 1 from public.event_pois p where p.id=poi_id and public.can_admin_event(p.event_id))
);

create policy "incidents read" on public.incidents
for select to authenticated
using(
  public.has_event_staff_access(event_id)
  or private.field_can_read_incident(id)
);
create policy "incident departments read" on public.incident_departments for select using(
  exists(select 1 from public.incidents i where i.id=incident_id and public.has_event_staff_access(i.event_id))
);
create policy "incident units read" on public.incident_units for select using(
  exists(select 1 from public.incidents i where i.id=incident_id and public.has_event_staff_access(i.event_id))
  or public.field_has_unit_access(unit_id)
);
create policy "status log read" on public.unit_status_log for select using(public.has_event_staff_access(event_id));
create policy "activity read" on public.cad_activity for select using(public.has_event_staff_access(event_id));

-- Storage RLS
drop policy if exists "CommCenter event asset read" on storage.objects;
drop policy if exists "CommCenter event asset insert" on storage.objects;
drop policy if exists "CommCenter event asset update" on storage.objects;
drop policy if exists "CommCenter event asset delete" on storage.objects;

create policy "CommCenter event asset read"
on storage.objects for select to authenticated
using(bucket_id='event-assets' and public.storage_event_access(name));

create policy "CommCenter event asset insert"
on storage.objects for insert to authenticated
with check(bucket_id='event-assets' and public.storage_event_admin(name));

create policy "CommCenter event asset update"
on storage.objects for update to authenticated
using(bucket_id='event-assets' and public.storage_event_admin(name))
with check(bucket_id='event-assets' and public.storage_event_admin(name));

create policy "CommCenter event asset delete"
on storage.objects for delete to authenticated
using(bucket_id='event-assets' and public.storage_event_admin(name));

-- ============================================================
-- REALTIME
-- ============================================================

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='incidents') then
    alter publication supabase_realtime add table public.incidents;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='units') then
    alter publication supabase_realtime add table public.units;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='incident_units') then
    alter publication supabase_realtime add table public.incident_units;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='unit_status_log') then
    alter publication supabase_realtime add table public.unit_status_log;
  end if;
end $$;

-- ============================================================
-- EXPLICIT GRANTS
-- ============================================================

grant usage on schema public to authenticated;
grant select on public.profiles,public.platform_admins,public.organizations,public.organization_members,public.events,public.event_staff,
  public.event_departments,public.staff_department_access,public.units,public.field_sessions,public.event_maps,
  public.map_control_points,public.event_w3w_squares,public.event_pois,public.poi_aliases,public.incidents,
  public.incident_departments,public.incident_units,public.unit_status_log,public.cad_activity to authenticated;

grant insert,update,delete on public.event_departments,public.units,public.event_maps,public.map_control_points,
  public.event_w3w_squares,public.event_pois,public.poi_aliases to authenticated;

grant usage,select on all sequences in schema public to authenticated;

grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.platform_create_organization(text) to authenticated;
grant execute on function public.add_existing_org_member(uuid,text,text) to authenticated;
grant execute on function public.staff_events_for_org(uuid) to authenticated;
grant execute on function public.create_event(uuid,text,text,text,text) to authenticated;
grant execute on function public.set_event_field_access(uuid,text,boolean) to authenticated;
grant execute on function public.create_incident(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,text,uuid) to authenticated;
grant execute on function public.assign_unit(uuid,uuid) to authenticated;
grant execute on function public.unassign_unit(uuid,uuid,text) to authenticated;
grant execute on function public.staff_set_unit_status(uuid,text,uuid) to authenticated;
grant execute on function public.update_incident_v2(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,text,uuid,uuid,uuid) to authenticated;
grant execute on function public.close_incident(uuid,text) to authenticated;
grant execute on function public.w3w_for_coordinate(uuid,double precision,double precision) to authenticated;
grant execute on function public.w3w_squares_in_bounds(uuid,double precision,double precision,double precision,double precision,integer) to authenticated;
grant execute on function public.field_enter_event(text,text,text) to authenticated;
grant execute on function public.field_claim_unit(uuid,uuid) to authenticated;
grant execute on function public.field_release_unit(uuid) to authenticated;
grant execute on function public.field_end_session(uuid) to authenticated;
grant execute on function public.field_set_unit_status(uuid,text,uuid,timestamptz) to authenticated;
grant select on public.dispatch_log to authenticated;

-- ============================================================
-- COMM CENTER PRO v0.3.0 EMS OPERATIONS
-- ============================================================
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
-- CommCenter Pro v0.4.0
-- Multi-level venue / stadium mapping upgrade.
-- Safe for an existing v0.3.1 database. Existing maps/incidents/POIs are preserved.

alter table public.events
  add column if not exists venue_type text not null default 'outdoor'
  check (venue_type in ('outdoor','multi_level','hybrid')),
  add column if not exists offline_w3w_path text;

create table if not exists public.event_map_layers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  short_name text,
  level_code text,
  level_number integer,
  level_type text not null default 'venue'
    check (level_type in ('exterior','field','concourse','suite','deck','back_of_house','parking','venue','other')),
  sort_order integer not null default 100,
  source_pdf_path text,
  rendered_image_path text,
  image_width integer,
  image_height integer,
  georef_method text,
  georef_coefficients jsonb,
  georef_rmse_m double precision,
  georef_max_error_m double precision,
  status text not null default 'draft' check(status in ('draft','calibrated','published')),
  is_default boolean not null default false,
  active boolean not null default true,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(event_id,name)
);

create unique index if not exists event_map_layers_one_default_idx
  on public.event_map_layers(event_id)
  where is_default=true and active=true;

alter table public.map_control_points
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete cascade;

alter table public.event_pois
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete set null;

create table if not exists public.event_zones (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  map_layer_id uuid references public.event_map_layers(id) on delete cascade,
  name text not null,
  short_name text,
  category text,
  notes text,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(event_id,map_layer_id,name)
);

alter table public.event_pois
  add column if not exists zone_id uuid references public.event_zones(id) on delete set null;

alter table public.incidents
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete set null,
  add column if not exists zone_id uuid references public.event_zones(id) on delete set null;

alter table public.units
  add column if not exists current_map_layer_id uuid references public.event_map_layers(id) on delete set null,
  add column if not exists current_zone_id uuid references public.event_zones(id) on delete set null,
  add column if not exists current_poi_id uuid references public.event_pois(id) on delete set null;

create table if not exists public.venue_access_points (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  access_type text not null
    check(access_type in ('elevator','stairwell','escalator','ramp','portal','vomitory','tunnel','gate','corridor','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(event_id,name)
);

create table if not exists public.venue_access_point_nodes (
  id uuid primary key default gen_random_uuid(),
  access_point_id uuid not null references public.venue_access_points(id) on delete cascade,
  map_layer_id uuid not null references public.event_map_layers(id) on delete cascade,
  zone_id uuid references public.event_zones(id) on delete set null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision,
  longitude double precision,
  w3w text,
  instructions text,
  created_at timestamptz not null default now(),
  unique(access_point_id,map_layer_id)
);

create index if not exists event_map_layers_event_idx on public.event_map_layers(event_id,sort_order);
create index if not exists event_zones_event_layer_idx on public.event_zones(event_id,map_layer_id,sort_order);
create index if not exists venue_access_points_event_idx on public.venue_access_points(event_id);
create index if not exists venue_access_nodes_layer_idx on public.venue_access_point_nodes(map_layer_id);

-- Migrate the existing single event map into a default map layer once.
insert into public.event_map_layers(
  event_id,name,short_name,level_code,level_type,sort_order,
  source_pdf_path,rendered_image_path,image_width,image_height,
  georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
  status,is_default,published_at,updated_at
)
select
  em.event_id,'Event / Site Level','EVENT','EVENT','venue',10,
  em.source_pdf_path,em.rendered_image_path,em.image_width,em.image_height,
  em.georef_method,em.georef_coefficients,em.georef_rmse_m,em.georef_max_error_m,
  em.status,true,em.published_at,em.updated_at
from public.event_maps em
where not exists(select 1 from public.event_map_layers l where l.event_id=em.event_id);

-- Attach legacy control points/POIs to the default layer when possible.
update public.map_control_points cp
set map_layer_id=l.id
from public.event_map_layers l
where cp.event_id=l.event_id and l.is_default=true and cp.map_layer_id is null;

update public.event_pois p
set map_layer_id=l.id
from public.event_map_layers l
where p.event_id=l.event_id and l.is_default=true and p.map_layer_id is null;

update public.incidents i
set map_layer_id=l.id
from public.event_map_layers l
where i.event_id=l.event_id and l.is_default=true and i.map_layer_id is null;

-- ---------------- Access helpers / RLS ----------------
alter table public.event_map_layers enable row level security;
alter table public.event_zones enable row level security;
alter table public.venue_access_points enable row level security;
alter table public.venue_access_point_nodes enable row level security;

create policy "map layers read" on public.event_map_layers for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "map layers admin insert" on public.event_map_layers for insert
with check(public.can_admin_event(event_id));
create policy "map layers admin update" on public.event_map_layers for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "map layers admin delete" on public.event_map_layers for delete
using(public.can_admin_event(event_id));

create policy "zones read" on public.event_zones for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "zones admin insert" on public.event_zones for insert
with check(public.can_admin_event(event_id));
create policy "zones admin update" on public.event_zones for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "zones admin delete" on public.event_zones for delete
using(public.can_admin_event(event_id));

create policy "access points read" on public.venue_access_points for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "access points admin insert" on public.venue_access_points for insert
with check(public.can_admin_event(event_id));
create policy "access points admin update" on public.venue_access_points for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "access points admin delete" on public.venue_access_points for delete
using(public.can_admin_event(event_id));

create policy "access nodes read" on public.venue_access_point_nodes for select
using(exists(
  select 1 from public.venue_access_points ap
  where ap.id=access_point_id and (public.has_event_staff_access(ap.event_id) or public.field_has_event_access(ap.event_id))
));
create policy "access nodes admin insert" on public.venue_access_point_nodes for insert
with check(exists(
  select 1 from public.venue_access_points ap
  where ap.id=access_point_id and public.can_admin_event(ap.event_id)
));
create policy "access nodes admin update" on public.venue_access_point_nodes for update
using(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)))
with check(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)));
create policy "access nodes admin delete" on public.venue_access_point_nodes for delete
using(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)));

grant select,insert,update,delete on public.event_map_layers,public.event_zones,public.venue_access_points,public.venue_access_point_nodes to authenticated;

-- ---------------- v2 incident creation ----------------
create or replace function public.create_incident_v2(
  p_event_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare n integer; prefix text; number text; iid uuid; d uuid;
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if array_length(p_department_ids,1) is null then raise exception 'At least one department is required'; end if;

  if p_map_layer_id is not null and not exists(select 1 from public.event_map_layers where id=p_map_layer_id and event_id=p_event_id and active=true) then
    raise exception 'Map layer is not part of this event';
  end if;
  if p_zone_id is not null and not exists(select 1 from public.event_zones where id=p_zone_id and event_id=p_event_id and active=true) then
    raise exception 'Zone is not part of this event';
  end if;

  update public.events set next_incident_number=next_incident_number+1 where id=p_event_id
  returning next_incident_number-1,incident_prefix into n,prefix;
  number:=prefix||'-'||lpad(n::text,3,'0');

  insert into public.incidents(
    event_id,incident_number,call_type,priority,poi_id,map_layer_id,zone_id,
    latitude,longitude,map_x,map_y,w3w,landmark,notes,created_by
  ) values(
    p_event_id,number,p_call_type,p_priority,p_poi_id,p_map_layer_id,p_zone_id,
    p_latitude,p_longitude,p_map_x,p_map_y,p_w3w,p_landmark,p_notes,auth.uid()
  ) returning id into iid;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    select iid,d where exists(select 1 from public.event_departments where id=d and event_id=p_event_id);
  end loop;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,iid,'INCIDENT_CREATED',jsonb_build_object(
    'incident_number',number,'call_type',p_call_type,'map_layer_id',p_map_layer_id,'zone_id',p_zone_id
  ),auth.uid(),'staff');
  return iid;
end;
$$;

grant execute on function public.create_incident_v2(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,text,uuid,uuid,uuid) to authenticated;

create or replace function public.staff_set_unit_location(
  p_unit_id uuid,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_poi_id uuid default null
) returns void
language plpgsql security definer set search_path=public
as $$
declare eid uuid;
begin
  select event_id into eid from public.units where id=p_unit_id and active=true;
  if eid is null then raise exception 'Active unit not found'; end if;
  if not public.can_dispatch_event(eid) then raise exception 'Dispatch access required'; end if;

  if p_map_layer_id is not null and not exists(select 1 from public.event_map_layers where id=p_map_layer_id and event_id=eid) then raise exception 'Invalid map layer'; end if;
  if p_zone_id is not null and not exists(select 1 from public.event_zones where id=p_zone_id and event_id=eid) then raise exception 'Invalid zone'; end if;
  if p_poi_id is not null and not exists(select 1 from public.event_pois where id=p_poi_id and event_id=eid) then raise exception 'Invalid POI'; end if;

  update public.units set current_map_layer_id=p_map_layer_id,current_zone_id=p_zone_id,current_poi_id=p_poi_id where id=p_unit_id;
  insert into public.cad_activity(event_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(eid,p_unit_id,'UNIT_LOCATION_CHANGED',jsonb_build_object('map_layer_id',p_map_layer_id,'zone_id',p_zone_id,'poi_id',p_poi_id),auth.uid(),'staff');
end;
$$;

grant execute on function public.staff_set_unit_location(uuid,uuid,uuid,uuid) to authenticated;


-- CommCenter Pro v0.5.0
-- Organization Venue Library
--
-- Adds reusable, versioned organization-level venue templates.
-- Events receive copied snapshots of venue maps/POIs/zones/access points.
-- Historical events never change when a venue template gets a new version.

create table if not exists public.organization_venues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  slug text not null,
  venue_type text not null default 'outdoor'
    check(venue_type in ('outdoor','multi_level','hybrid')),
  address text,
  active boolean not null default true,
  current_version_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,slug)
);

create table if not exists public.organization_venue_versions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.organization_venues(id) on delete cascade,
  version_number integer not null,
  status text not null default 'draft'
    check(status in ('draft','published','archived')),
  source_event_id uuid references public.events(id) on delete set null,
  notes text,
  offline_w3w_path text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique(venue_id,version_number)
);

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='organization_venues_current_version_fk'
  ) then
    alter table public.organization_venues
      add constraint organization_venues_current_version_fk
      foreign key(current_version_id)
      references public.organization_venue_versions(id)
      on delete set null;
  end if;
end $$;

create table if not exists public.organization_venue_map_layers (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  source_event_layer_id uuid,
  name text not null,
  short_name text,
  level_code text,
  level_number integer,
  level_type text not null default 'venue'
    check(level_type in ('exterior','field','concourse','suite','deck','back_of_house','parking','venue','other')),
  sort_order integer not null default 100,
  source_pdf_path text,
  rendered_image_path text,
  image_width integer,
  image_height integer,
  georef_method text,
  georef_coefficients jsonb,
  georef_rmse_m double precision,
  georef_max_error_m double precision,
  source_status text not null default 'draft',
  is_default boolean not null default false,
  source_published_at timestamptz,
  created_at timestamptz not null default now(),
  unique(version_id,name)
);

create table if not exists public.organization_venue_map_control_points (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid not null references public.organization_venue_map_layers(id) on delete cascade,
  label text not null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision not null,
  longitude double precision not null,
  residual_m double precision,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_venue_zones (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid references public.organization_venue_map_layers(id) on delete cascade,
  source_event_zone_id uuid,
  name text not null,
  short_name text,
  category text,
  notes text,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(version_id,map_layer_id,name)
);

create table if not exists public.organization_venue_w3w_squares (
  id bigint generated always as identity primary key,
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  words text not null,
  south double precision not null,
  north double precision not null,
  west double precision not null,
  east double precision not null,
  center_lat double precision,
  center_lon double precision,
  unique(version_id,words)
);

create table if not exists public.organization_venue_pois (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid references public.organization_venue_map_layers(id) on delete set null,
  zone_id uuid references public.organization_venue_zones(id) on delete set null,
  source_event_poi_id uuid,
  name text not null,
  category text,
  w3w text,
  latitude double precision not null,
  longitude double precision not null,
  map_x double precision not null,
  map_y double precision not null,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_venue_poi_aliases (
  id bigint generated always as identity primary key,
  poi_id uuid not null references public.organization_venue_pois(id) on delete cascade,
  alias text not null,
  unique(poi_id,alias)
);

create table if not exists public.organization_venue_access_points (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  source_event_access_point_id uuid,
  name text not null,
  access_type text not null
    check(access_type in ('elevator','stairwell','escalator','ramp','portal','vomitory','tunnel','gate','corridor','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(version_id,name)
);

create table if not exists public.organization_venue_access_point_nodes (
  id uuid primary key default gen_random_uuid(),
  access_point_id uuid not null references public.organization_venue_access_points(id) on delete cascade,
  map_layer_id uuid not null references public.organization_venue_map_layers(id) on delete cascade,
  zone_id uuid references public.organization_venue_zones(id) on delete set null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision,
  longitude double precision,
  w3w text,
  instructions text,
  created_at timestamptz not null default now(),
  unique(access_point_id,map_layer_id)
);

create index if not exists org_venues_org_idx
  on public.organization_venues(organization_id,name);
create index if not exists org_venue_versions_venue_idx
  on public.organization_venue_versions(venue_id,version_number desc);
create index if not exists org_venue_layers_version_idx
  on public.organization_venue_map_layers(version_id,sort_order);
create index if not exists org_venue_zones_version_idx
  on public.organization_venue_zones(version_id,map_layer_id,sort_order);
create index if not exists org_venue_pois_version_idx
  on public.organization_venue_pois(version_id,name);
create index if not exists org_venue_w3w_bounds_idx
  on public.organization_venue_w3w_squares(version_id,south,north,west,east);

alter table public.events
  add column if not exists venue_id uuid references public.organization_venues(id) on delete set null,
  add column if not exists venue_version_id uuid references public.organization_venue_versions(id) on delete set null;

alter table public.event_map_layers
  add column if not exists source_venue_layer_id uuid references public.organization_venue_map_layers(id) on delete set null;

alter table public.event_zones
  add column if not exists source_venue_zone_id uuid references public.organization_venue_zones(id) on delete set null;

alter table public.event_pois
  add column if not exists source_venue_poi_id uuid references public.organization_venue_pois(id) on delete set null,
  add column if not exists poi_scope text not null default 'event'
    check(poi_scope in ('event','venue_snapshot'));

-- ---------------- Venue access helpers ----------------

create or replace function public.has_venue_version_access(p_version uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.organization_venue_versions vv
    join public.organization_venues v on v.id=vv.venue_id
    where vv.id=p_version
      and public.has_org_access(v.organization_id)
  );
$$;

create or replace function public.can_admin_venue_version(p_version uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.organization_venue_versions vv
    join public.organization_venues v on v.id=vv.venue_id
    where vv.id=p_version
      and public.is_org_admin(v.organization_id)
  );
$$;

create or replace function public.storage_venue_access(object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,storage
as $$
declare
  folders text[];
  oid uuid;
begin
  folders:=storage.foldername(object_name);
  if array_length(folders,1)<2 or folders[1]<>'venues' then return false; end if;
  if folders[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  oid:=folders[2]::uuid;
  return public.has_org_access(oid);
end;
$$;

create or replace function public.storage_venue_admin(object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,storage
as $$
declare
  folders text[];
  oid uuid;
begin
  folders:=storage.foldername(object_name);
  if array_length(folders,1)<2 or folders[1]<>'venues' then return false; end if;
  if folders[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  oid:=folders[2]::uuid;
  return public.is_org_admin(oid);
end;
$$;

-- ---------------- RLS ----------------

alter table public.organization_venues enable row level security;
alter table public.organization_venue_versions enable row level security;
alter table public.organization_venue_map_layers enable row level security;
alter table public.organization_venue_map_control_points enable row level security;
alter table public.organization_venue_zones enable row level security;
alter table public.organization_venue_w3w_squares enable row level security;
alter table public.organization_venue_pois enable row level security;
alter table public.organization_venue_poi_aliases enable row level security;
alter table public.organization_venue_access_points enable row level security;
alter table public.organization_venue_access_point_nodes enable row level security;

drop policy if exists "organization venues read" on public.organization_venues;
drop policy if exists "organization venues insert" on public.organization_venues;
drop policy if exists "organization venues update" on public.organization_venues;
drop policy if exists "organization venues delete" on public.organization_venues;

create policy "organization venues read"
on public.organization_venues for select to authenticated
using(public.has_org_access(organization_id));

create policy "organization venues insert"
on public.organization_venues for insert to authenticated
with check(public.is_org_admin(organization_id));

create policy "organization venues update"
on public.organization_venues for update to authenticated
using(public.is_org_admin(organization_id))
with check(public.is_org_admin(organization_id));

create policy "organization venues delete"
on public.organization_venues for delete to authenticated
using(public.is_org_admin(organization_id));

drop policy if exists "organization venue versions read" on public.organization_venue_versions;
drop policy if exists "organization venue versions insert" on public.organization_venue_versions;
drop policy if exists "organization venue versions update" on public.organization_venue_versions;
drop policy if exists "organization venue versions delete" on public.organization_venue_versions;

create policy "organization venue versions read"
on public.organization_venue_versions for select to authenticated
using(public.has_venue_version_access(id));

create policy "organization venue versions insert"
on public.organization_venue_versions for insert to authenticated
with check(exists(
  select 1 from public.organization_venues v
  where v.id=venue_id and public.is_org_admin(v.organization_id)
));

create policy "organization venue versions update"
on public.organization_venue_versions for update to authenticated
using(public.can_admin_venue_version(id))
with check(public.can_admin_venue_version(id));

create policy "organization venue versions delete"
on public.organization_venue_versions for delete to authenticated
using(public.can_admin_venue_version(id));

drop policy if exists "organization venue layers read" on public.organization_venue_map_layers;
drop policy if exists "organization venue layers write" on public.organization_venue_map_layers;
drop policy if exists "organization venue control points read" on public.organization_venue_map_control_points;
drop policy if exists "organization venue control points write" on public.organization_venue_map_control_points;
drop policy if exists "organization venue zones read" on public.organization_venue_zones;
drop policy if exists "organization venue zones write" on public.organization_venue_zones;
drop policy if exists "organization venue w3w read" on public.organization_venue_w3w_squares;
drop policy if exists "organization venue w3w write" on public.organization_venue_w3w_squares;
drop policy if exists "organization venue pois read" on public.organization_venue_pois;
drop policy if exists "organization venue pois write" on public.organization_venue_pois;
drop policy if exists "organization venue poi aliases read" on public.organization_venue_poi_aliases;
drop policy if exists "organization venue poi aliases write" on public.organization_venue_poi_aliases;
drop policy if exists "organization venue access read" on public.organization_venue_access_points;
drop policy if exists "organization venue access write" on public.organization_venue_access_points;
drop policy if exists "organization venue access nodes read" on public.organization_venue_access_point_nodes;
drop policy if exists "organization venue access nodes write" on public.organization_venue_access_point_nodes;

create policy "organization venue layers read"
on public.organization_venue_map_layers for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue layers write"
on public.organization_venue_map_layers for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue control points read"
on public.organization_venue_map_control_points for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue control points write"
on public.organization_venue_map_control_points for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue zones read"
on public.organization_venue_zones for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue zones write"
on public.organization_venue_zones for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue w3w read"
on public.organization_venue_w3w_squares for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue w3w write"
on public.organization_venue_w3w_squares for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue pois read"
on public.organization_venue_pois for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue pois write"
on public.organization_venue_pois for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue poi aliases read"
on public.organization_venue_poi_aliases for select to authenticated
using(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.has_venue_version_access(p.version_id)
));
create policy "organization venue poi aliases write"
on public.organization_venue_poi_aliases for all to authenticated
using(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.can_admin_venue_version(p.version_id)
))
with check(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.can_admin_venue_version(p.version_id)
));

create policy "organization venue access read"
on public.organization_venue_access_points for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue access write"
on public.organization_venue_access_points for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue access nodes read"
on public.organization_venue_access_point_nodes for select to authenticated
using(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.has_venue_version_access(ap.version_id)
));
create policy "organization venue access nodes write"
on public.organization_venue_access_point_nodes for all to authenticated
using(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.can_admin_venue_version(ap.version_id)
))
with check(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.can_admin_venue_version(ap.version_id)
));

grant select,insert,update,delete on
  public.organization_venues,
  public.organization_venue_versions,
  public.organization_venue_map_layers,
  public.organization_venue_map_control_points,
  public.organization_venue_zones,
  public.organization_venue_w3w_squares,
  public.organization_venue_pois,
  public.organization_venue_poi_aliases,
  public.organization_venue_access_points,
  public.organization_venue_access_point_nodes
to authenticated;

-- Extend the existing private bucket policies to organization venue assets.
drop policy if exists "CommCenter event asset read" on storage.objects;
drop policy if exists "CommCenter event asset insert" on storage.objects;
drop policy if exists "CommCenter event asset update" on storage.objects;
drop policy if exists "CommCenter event asset delete" on storage.objects;

create policy "CommCenter event asset read"
on storage.objects for select to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_access(name) or public.storage_venue_access(name))
);

create policy "CommCenter event asset insert"
on storage.objects for insert to authenticated
with check(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

create policy "CommCenter event asset update"
on storage.objects for update to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
)
with check(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

create policy "CommCenter event asset delete"
on storage.objects for delete to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

-- ---------------- RPC: organization venue picker ----------------

create or replace function public.organization_venue_choices(p_organization_id uuid)
returns table(
  venue_id uuid,
  venue_name text,
  venue_type text,
  address text,
  version_id uuid,
  version_number integer
)
language sql
stable
security definer
set search_path=public
as $$
  select
    v.id,
    v.name,
    v.venue_type,
    v.address,
    vv.id,
    vv.version_number
  from public.organization_venues v
  join public.organization_venue_versions vv
    on vv.id=v.current_version_id
   and vv.status='published'
  where v.organization_id=p_organization_id
    and v.active=true
    and public.has_org_access(p_organization_id)
  order by v.name;
$$;

grant execute on function public.organization_venue_choices(uuid) to authenticated;

-- ---------------- RPC: save event into a new immutable venue version ----------------

create or replace function public.save_event_as_venue_version(
  p_event_id uuid,
  p_venue_id uuid default null,
  p_venue_name text default null,
  p_address text default null,
  p_notes text default null,
  p_include_event_pois boolean default false
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
  venue_row public.organization_venues;
  new_venue_id uuid;
  new_version_id uuid;
  new_version_number integer;
  layer_row record;
  new_layer_id uuid;
  zone_row record;
  new_zone_id uuid;
  poi_row record;
  new_poi_id uuid;
  ap_row record;
  new_ap_id uuid;
  node_row record;
  mapped_layer_id uuid;
  mapped_zone_id uuid;
  layer_payload jsonb:='[]'::jsonb;
  generated_slug text;
begin
  select * into e from public.events where id=p_event_id;
  if e.id is null then raise exception 'Event not found'; end if;
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;
  if not public.is_org_admin(e.organization_id) then
    raise exception 'Organization admin access is required to save a reusable venue';
  end if;

  if p_venue_id is null then
    if trim(coalesce(p_venue_name,''))='' then raise exception 'Venue name is required'; end if;
    generated_slug:=trim(both '-' from regexp_replace(lower(trim(p_venue_name)),'[^a-z0-9]+','-','g'));
    if generated_slug='' then generated_slug:='venue'; end if;
    if exists(select 1 from public.organization_venues where organization_id=e.organization_id and slug=generated_slug) then
      generated_slug:=generated_slug||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6);
    end if;

    insert into public.organization_venues(
      organization_id,name,slug,venue_type,address
    ) values(
      e.organization_id,trim(p_venue_name),generated_slug,coalesce(e.venue_type,'outdoor'),nullif(trim(p_address),'')
    )
    returning * into venue_row;

    new_venue_id:=venue_row.id;
  else
    select * into venue_row
    from public.organization_venues
    where id=p_venue_id and organization_id=e.organization_id and active=true;

    if venue_row.id is null then raise exception 'Venue does not belong to this organization'; end if;
    new_venue_id:=venue_row.id;

    update public.organization_venues
    set venue_type=coalesce(e.venue_type,venue_type),
        address=coalesce(nullif(trim(p_address),''),address),
        updated_at=now()
    where id=new_venue_id;
  end if;

  select coalesce(max(version_number),0)+1
  into new_version_number
  from public.organization_venue_versions
  where venue_id=new_venue_id;

  insert into public.organization_venue_versions(
    venue_id,version_number,status,source_event_id,notes,created_by
  ) values(
    new_venue_id,new_version_number,'draft',p_event_id,nullif(trim(p_notes),''),auth.uid()
  )
  returning id into new_version_id;

  -- Reusable W3W square library. Server-side insert/select avoids browser-sized transfers.
  insert into public.organization_venue_w3w_squares(
    version_id,words,south,north,west,east,center_lat,center_lon
  )
  select
    new_version_id,words,south,north,west,east,center_lat,center_lon
  from public.event_w3w_squares
  where event_id=p_event_id;

  -- Layers + calibration.
  for layer_row in
    select * from public.event_map_layers
    where event_id=p_event_id and active=true
    order by sort_order,name
  loop
    insert into public.organization_venue_map_layers(
      version_id,source_event_layer_id,name,short_name,level_code,level_number,level_type,sort_order,
      image_width,image_height,georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
      source_status,is_default,source_published_at
    ) values(
      new_version_id,layer_row.id,layer_row.name,layer_row.short_name,layer_row.level_code,
      layer_row.level_number,layer_row.level_type,layer_row.sort_order,
      layer_row.image_width,layer_row.image_height,layer_row.georef_method,layer_row.georef_coefficients,
      layer_row.georef_rmse_m,layer_row.georef_max_error_m,
      layer_row.status,layer_row.is_default,layer_row.published_at
    )
    returning id into new_layer_id;

    insert into public.organization_venue_map_control_points(
      version_id,map_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    )
    select
      new_version_id,new_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    from public.map_control_points
    where event_id=p_event_id and map_layer_id=layer_row.id;

    layer_payload:=layer_payload||jsonb_build_array(jsonb_build_object(
      'venue_layer_id',new_layer_id,
      'name',layer_row.name,
      'source_pdf_path',layer_row.source_pdf_path,
      'rendered_image_path',layer_row.rendered_image_path
    ));
  end loop;

  -- Zones.
  for zone_row in
    select * from public.event_zones
    where event_id=p_event_id and active=true
    order by sort_order,name
  loop
    select id into mapped_layer_id
    from public.organization_venue_map_layers
    where version_id=new_version_id
      and source_event_layer_id=zone_row.map_layer_id
    limit 1;

    insert into public.organization_venue_zones(
      version_id,map_layer_id,source_event_zone_id,name,short_name,category,notes,sort_order,active
    ) values(
      new_version_id,mapped_layer_id,zone_row.id,zone_row.name,zone_row.short_name,
      zone_row.category,zone_row.notes,zone_row.sort_order,zone_row.active
    );
  end loop;

  -- POIs. If this event is already based on a venue, event-only overlays are
  -- excluded unless the admin explicitly promotes them into the new venue version.
  for poi_row in
    select *
    from public.event_pois
    where event_id=p_event_id
      and active=true
      and (
        e.venue_id is null
        or poi_scope='venue_snapshot'
        or p_include_event_pois=true
      )
    order by name
  loop
    select id into mapped_layer_id
    from public.organization_venue_map_layers
    where version_id=new_version_id
      and source_event_layer_id=poi_row.map_layer_id
    limit 1;

    mapped_zone_id:=null;
    if poi_row.zone_id is not null then
      select id into mapped_zone_id
      from public.organization_venue_zones
      where version_id=new_version_id
        and source_event_zone_id=poi_row.zone_id
      limit 1;
    end if;

    insert into public.organization_venue_pois(
      version_id,map_layer_id,zone_id,source_event_poi_id,name,category,w3w,
      latitude,longitude,map_x,map_y,notes,active
    ) values(
      new_version_id,mapped_layer_id,mapped_zone_id,poi_row.id,poi_row.name,poi_row.category,poi_row.w3w,
      poi_row.latitude,poi_row.longitude,poi_row.map_x,poi_row.map_y,poi_row.notes,poi_row.active
    )
    returning id into new_poi_id;

    insert into public.organization_venue_poi_aliases(poi_id,alias)
    select new_poi_id,alias
    from public.poi_aliases
    where poi_id=poi_row.id;
  end loop;

  -- Vertical access routes and per-level nodes.
  for ap_row in
    select * from public.venue_access_points
    where event_id=p_event_id and active=true
    order by name
  loop
    insert into public.organization_venue_access_points(
      version_id,source_event_access_point_id,name,access_type,notes,active
    ) values(
      new_version_id,ap_row.id,ap_row.name,ap_row.access_type,ap_row.notes,ap_row.active
    )
    returning id into new_ap_id;

    for node_row in
      select * from public.venue_access_point_nodes
      where access_point_id=ap_row.id
    loop
      select id into mapped_layer_id
      from public.organization_venue_map_layers
      where version_id=new_version_id
        and source_event_layer_id=node_row.map_layer_id
      limit 1;

      mapped_zone_id:=null;
      if node_row.zone_id is not null then
        select id into mapped_zone_id
        from public.organization_venue_zones
        where version_id=new_version_id
          and source_event_zone_id=node_row.zone_id
        limit 1;
      end if;

      if mapped_layer_id is not null then
        insert into public.organization_venue_access_point_nodes(
          access_point_id,map_layer_id,zone_id,map_x,map_y,latitude,longitude,w3w,instructions
        ) values(
          new_ap_id,mapped_layer_id,mapped_zone_id,node_row.map_x,node_row.map_y,
          node_row.latitude,node_row.longitude,node_row.w3w,node_row.instructions
        );
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'organization_id',e.organization_id,
    'venue_id',new_venue_id,
    'venue_name',coalesce(venue_row.name,p_venue_name),
    'version_id',new_version_id,
    'version_number',new_version_number,
    'source_offline_w3w_path',e.offline_w3w_path,
    'layers',layer_payload
  );
end;
$$;

grant execute on function public.save_event_as_venue_version(uuid,uuid,text,text,text,boolean) to authenticated;

create or replace function public.publish_venue_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  vv public.organization_venue_versions;
  oid uuid;
begin
  select * into vv from public.organization_venue_versions where id=p_version_id;
  if vv.id is null then raise exception 'Venue version not found'; end if;

  select organization_id into oid
  from public.organization_venues
  where id=vv.venue_id;

  if not public.is_org_admin(oid) then
    raise exception 'Organization admin access required';
  end if;

  update public.organization_venue_versions
  set status='archived'
  where venue_id=vv.venue_id
    and id<>p_version_id
    and status='published';

  update public.organization_venue_versions
  set status='published',published_at=now()
  where id=p_version_id;

  update public.organization_venues
  set current_version_id=p_version_id,updated_at=now()
  where id=vv.venue_id;

  if vv.source_event_id is not null then
    update public.events
    set venue_id=vv.venue_id,
        venue_version_id=p_version_id
    where id=vv.source_event_id;
  end if;
end;
$$;

grant execute on function public.publish_venue_version(uuid) to authenticated;

-- ---------------- RPC: clone published venue into an event snapshot ----------------

create or replace function public.apply_venue_version_to_event(
  p_event_id uuid,
  p_version_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
  vv public.organization_venue_versions;
  venue_row public.organization_venues;
  venue_layer record;
  event_layer_id uuid;
  zone_row record;
  event_zone_id uuid;
  poi_row record;
  event_poi_id uuid;
  ap_row record;
  event_ap_id uuid;
  node_row record;
  mapped_event_layer_id uuid;
  mapped_event_zone_id uuid;
  layer_payload jsonb:='[]'::jsonb;
begin
  select * into e from public.events where id=p_event_id;
  if e.id is null then raise exception 'Event not found'; end if;
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;

  select * into vv
  from public.organization_venue_versions
  where id=p_version_id and status='published';
  if vv.id is null then raise exception 'Published venue version not found'; end if;

  select * into venue_row
  from public.organization_venues
  where id=vv.venue_id and organization_id=e.organization_id and active=true;
  if venue_row.id is null then raise exception 'Venue does not belong to this event organization'; end if;

  if exists(select 1 from public.event_map_layers where event_id=p_event_id)
     or exists(select 1 from public.event_pois where event_id=p_event_id)
     or exists(select 1 from public.event_zones where event_id=p_event_id)
     or exists(select 1 from public.venue_access_points where event_id=p_event_id)
  then
    raise exception 'This event already has map configuration. Apply a venue only to a blank event map.';
  end if;

  insert into public.event_w3w_squares(
    event_id,words,south,north,west,east,center_lat,center_lon
  )
  select
    p_event_id,words,south,north,west,east,center_lat,center_lon
  from public.organization_venue_w3w_squares
  where version_id=p_version_id
  on conflict(event_id,words) do nothing;

  for venue_layer in
    select * from public.organization_venue_map_layers
    where version_id=p_version_id
    order by sort_order,name
  loop
    insert into public.event_map_layers(
      event_id,source_venue_layer_id,name,short_name,level_code,level_number,level_type,sort_order,
      image_width,image_height,georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
      status,is_default,active
    ) values(
      p_event_id,venue_layer.id,venue_layer.name,venue_layer.short_name,venue_layer.level_code,
      venue_layer.level_number,venue_layer.level_type,venue_layer.sort_order,
      venue_layer.image_width,venue_layer.image_height,venue_layer.georef_method,venue_layer.georef_coefficients,
      venue_layer.georef_rmse_m,venue_layer.georef_max_error_m,
      'draft',venue_layer.is_default,true
    )
    returning id into event_layer_id;

    insert into public.map_control_points(
      event_id,map_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    )
    select
      p_event_id,event_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    from public.organization_venue_map_control_points
    where version_id=p_version_id
      and map_layer_id=venue_layer.id;

    layer_payload:=layer_payload||jsonb_build_array(jsonb_build_object(
      'event_layer_id',event_layer_id,
      'venue_layer_id',venue_layer.id,
      'name',venue_layer.name,
      'source_pdf_path',venue_layer.source_pdf_path,
      'rendered_image_path',venue_layer.rendered_image_path,
      'source_status',venue_layer.source_status,
      'source_published_at',venue_layer.source_published_at
    ));
  end loop;

  for zone_row in
    select * from public.organization_venue_zones
    where version_id=p_version_id and active=true
    order by sort_order,name
  loop
    select id into mapped_event_layer_id
    from public.event_map_layers
    where event_id=p_event_id
      and source_venue_layer_id=zone_row.map_layer_id
    limit 1;

    insert into public.event_zones(
      event_id,map_layer_id,source_venue_zone_id,name,short_name,category,notes,sort_order,active
    ) values(
      p_event_id,mapped_event_layer_id,zone_row.id,zone_row.name,zone_row.short_name,
      zone_row.category,zone_row.notes,zone_row.sort_order,zone_row.active
    );
  end loop;

  for poi_row in
    select * from public.organization_venue_pois
    where version_id=p_version_id and active=true
    order by name
  loop
    mapped_event_layer_id:=null;
    mapped_event_zone_id:=null;

    if poi_row.map_layer_id is not null then
      select id into mapped_event_layer_id
      from public.event_map_layers
      where event_id=p_event_id
        and source_venue_layer_id=poi_row.map_layer_id
      limit 1;
    end if;

    if poi_row.zone_id is not null then
      select id into mapped_event_zone_id
      from public.event_zones
      where event_id=p_event_id
        and source_venue_zone_id=poi_row.zone_id
      limit 1;
    end if;

    insert into public.event_pois(
      event_id,map_layer_id,zone_id,source_venue_poi_id,poi_scope,
      name,category,w3w,latitude,longitude,map_x,map_y,notes,active
    ) values(
      p_event_id,mapped_event_layer_id,mapped_event_zone_id,poi_row.id,'venue_snapshot',
      poi_row.name,poi_row.category,poi_row.w3w,poi_row.latitude,poi_row.longitude,
      poi_row.map_x,poi_row.map_y,poi_row.notes,poi_row.active
    )
    returning id into event_poi_id;

    insert into public.poi_aliases(poi_id,alias)
    select event_poi_id,alias
    from public.organization_venue_poi_aliases
    where poi_id=poi_row.id;
  end loop;

  for ap_row in
    select * from public.organization_venue_access_points
    where version_id=p_version_id and active=true
    order by name
  loop
    insert into public.venue_access_points(
      event_id,name,access_type,notes,active
    ) values(
      p_event_id,ap_row.name,ap_row.access_type,ap_row.notes,ap_row.active
    )
    returning id into event_ap_id;

    for node_row in
      select * from public.organization_venue_access_point_nodes
      where access_point_id=ap_row.id
    loop
      select id into mapped_event_layer_id
      from public.event_map_layers
      where event_id=p_event_id
        and source_venue_layer_id=node_row.map_layer_id
      limit 1;

      mapped_event_zone_id:=null;
      if node_row.zone_id is not null then
        select id into mapped_event_zone_id
        from public.event_zones
        where event_id=p_event_id
          and source_venue_zone_id=node_row.zone_id
        limit 1;
      end if;

      if mapped_event_layer_id is not null then
        insert into public.venue_access_point_nodes(
          access_point_id,map_layer_id,zone_id,map_x,map_y,latitude,longitude,w3w,instructions
        ) values(
          event_ap_id,mapped_event_layer_id,mapped_event_zone_id,
          node_row.map_x,node_row.map_y,node_row.latitude,node_row.longitude,node_row.w3w,node_row.instructions
        );
      end if;
    end loop;
  end loop;

  update public.events
  set venue_id=venue_row.id,
      venue_version_id=vv.id,
      venue_type=venue_row.venue_type
  where id=p_event_id;

  return jsonb_build_object(
    'venue_id',venue_row.id,
    'venue_name',venue_row.name,
    'version_id',vv.id,
    'version_number',vv.version_number,
    'offline_w3w_path',vv.offline_w3w_path,
    'layers',layer_payload
  );
end;
$$;

grant execute on function public.apply_venue_version_to_event(uuid,uuid) to authenticated;


-- CommCenter Pro v0.5.1
-- Live field unit location sharing.
--
-- Design:
-- * Browser/device permission is still required by the Geolocation API.
-- * Only the CURRENT unit location is stored. CommCenter Pro does not create
--   a breadcrumb/route history in this release.
-- * Field devices can publish only for the unit they currently hold.
-- * Event staff can read live locations for their event.
-- * Stopping sharing removes the current location row.
-- * Multi-level venues use units.current_map_layer_id to provide vertical context.

alter table public.events
  add column if not exists field_location_enabled boolean not null default false;

create table if not exists public.unit_locations (
  unit_id uuid primary key references public.units(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  field_session_id uuid references public.field_sessions(id) on delete set null,
  latitude double precision not null check(latitude between -90 and 90),
  longitude double precision not null check(longitude between -180 and 180),
  accuracy_m double precision,
  altitude_m double precision,
  heading_deg double precision,
  speed_mps double precision,
  client_time timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists unit_locations_event_updated_idx
  on public.unit_locations(event_id,updated_at desc);

alter table public.unit_locations enable row level security;

drop policy if exists "unit locations read" on public.unit_locations;

create policy "unit locations read"
on public.unit_locations
for select
to authenticated
using(
  public.has_event_staff_access(event_id)
  or public.field_has_unit_access(unit_id)
);

grant select on public.unit_locations to authenticated;

create or replace function public.set_event_field_location_enabled(
  p_event_id uuid,
  p_enabled boolean
) returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  update public.events
  set field_location_enabled=coalesce(p_enabled,false)
  where id=p_event_id;

  if not coalesce(p_enabled,false) then
    delete from public.unit_locations
    where event_id=p_event_id;
  end if;
end;
$$;

create or replace function public.field_update_unit_location(
  p_unit_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision default null,
  p_altitude_m double precision default null,
  p_heading_deg double precision default null,
  p_speed_mps double precision default null,
  p_client_time timestamptz default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions;
  eid uuid;
begin
  if p_latitude not between -90 and 90
     or p_longitude not between -180 and 180 then
    raise exception 'Invalid geographic coordinates';
  end if;

  select *
  into fs
  from public.field_sessions
  where auth_user_id=auth.uid()
    and unit_id=p_unit_id
    and active=true
  order by started_at desc
  limit 1;

  if fs.id is null then
    raise exception 'No active field session for this unit';
  end if;

  eid:=fs.event_id;

  if not exists(
    select 1 from public.events
    where id=eid
      and field_location_enabled=true
      and active=true
  ) then
    raise exception 'Field location sharing is disabled for this event';
  end if;

  insert into public.unit_locations(
    unit_id,event_id,field_session_id,
    latitude,longitude,accuracy_m,altitude_m,heading_deg,speed_mps,
    client_time,updated_at
  ) values(
    p_unit_id,eid,fs.id,
    p_latitude,p_longitude,
    case when p_accuracy_m is null then null else greatest(p_accuracy_m,0) end,
    p_altitude_m,
    case
      when p_heading_deg is null or p_heading_deg<0 then null
      else mod(p_heading_deg::numeric,360)::double precision
    end,
    case when p_speed_mps is null or p_speed_mps<0 then null else p_speed_mps end,
    coalesce(p_client_time,now()),
    now()
  )
  on conflict(unit_id)
  do update set
    event_id=excluded.event_id,
    field_session_id=excluded.field_session_id,
    latitude=excluded.latitude,
    longitude=excluded.longitude,
    accuracy_m=excluded.accuracy_m,
    altitude_m=excluded.altitude_m,
    heading_deg=excluded.heading_deg,
    speed_mps=excluded.speed_mps,
    client_time=excluded.client_time,
    updated_at=now();

  update public.field_sessions
  set last_seen_at=now()
  where id=fs.id;
end;
$$;

create or replace function public.field_stop_unit_location(
  p_unit_id uuid
) returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.field_has_unit_access(p_unit_id) then
    raise exception 'Not authorized for this unit';
  end if;

  delete from public.unit_locations
  where unit_id=p_unit_id;
end;
$$;

create or replace function public.field_set_unit_venue_location(
  p_unit_id uuid,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
begin
  if not public.field_has_unit_access(p_unit_id) then
    raise exception 'Not authorized for this unit';
  end if;

  select event_id into eid
  from public.units
  where id=p_unit_id and active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if p_map_layer_id is not null and not exists(
    select 1
    from public.event_map_layers
    where id=p_map_layer_id
      and event_id=eid
      and active=true
      and status='published'
  ) then
    raise exception 'Map layer is not valid for this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones
    where id=p_zone_id
      and event_id=eid
      and active=true
      and (p_map_layer_id is null or map_layer_id=p_map_layer_id)
  ) then
    raise exception 'Zone is not valid for this map layer';
  end if;

  update public.units
  set current_map_layer_id=p_map_layer_id,
      current_zone_id=p_zone_id,
      current_poi_id=null
  where id=p_unit_id;
end;
$$;

-- Remove a unit's current GPS position when the field device intentionally
-- releases the unit or ends the field session.
create or replace function public.field_release_unit(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set unit_id=null,last_seen_at=now()
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

create or replace function public.field_end_session(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set active=false,ended_at=now(),last_seen_at=now()
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

grant execute on function public.set_event_field_location_enabled(uuid,boolean) to authenticated;
grant execute on function public.field_update_unit_location(uuid,double precision,double precision,double precision,double precision,double precision,double precision,timestamptz) to authenticated;
grant execute on function public.field_stop_unit_location(uuid) to authenticated;
grant execute on function public.field_set_unit_venue_location(uuid,uuid,uuid) to authenticated;

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='unit_locations'
  ) then
    alter publication supabase_realtime add table public.unit_locations;
  end if;
end $$;


-- CommCenter Pro v0.5.2
-- Treatment-area custody confirmation from Dispatch or Treatment Area Station.
--
-- Operational rule:
-- * The CAD incident number remains the patient reference.
-- * Dispatch can mark that an incident/patient was handed off to a treatment area.
-- * A treatment-area station can independently mark that the patient was received.
-- * Either action reconciles CURRENT custody to the treatment area.
-- * Existing pending handoff requests to that treatment area are completed.
-- * Conflicting pending handoffs are cancelled.
-- * All manual reconciliation is recorded in cad_activity.

create or replace function private.place_incident_in_treatment(
  p_incident_id uuid,
  p_treatment_area_id uuid,
  p_note text,
  p_actor_kind text
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  ta public.ems_treatment_areas;
  e public.ems_encounters;
  matching_handoff public.ems_handoffs;
  new_handoff_id uuid;
  old_unit uuid;
  old_area uuid;
  already_here boolean:=false;
begin
  select * into i
  from public.incidents
  where id=p_incident_id
    and status<>'CLOSED';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select * into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and event_id=i.event_id
    and active=true;

  if ta.id is null then
    raise exception 'Active treatment area not found for this event';
  end if;

  select *
  into e
  from public.ems_encounters
  where event_id=i.event_id
    and incident_id=i.id
    and current_status<>'CLOSED'
  order by created_at
  limit 1;

  if e.id is null then
    insert into public.ems_encounters(
      event_id,
      incident_id,
      tracking_number,
      current_status,
      current_unit_id,
      current_treatment_area_id,
      origin_unit_id,
      operational_note,
      created_by
    ) values(
      i.event_id,
      i.id,
      i.incident_number,
      'IN_TREATMENT',
      null,
      ta.id,
      null,
      nullif(trim(p_note),''),
      auth.uid()
    )
    returning * into e;

    insert into public.cad_activity(
      event_id,incident_id,action,detail,actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,'EMS_TREATMENT_RECEIVED',
      jsonb_build_object(
        'encounter_id',e.id,
        'incident_number',i.incident_number,
        'treatment_area_id',ta.id,
        'treatment_area_name',ta.name,
        'confirmation_source',p_actor_kind,
        'created_ems_flow',true,
        'note',nullif(trim(p_note),'')
      ),
      auth.uid(),p_actor_kind
    );

    return 'RECEIVED';
  end if;

  if e.current_treatment_area_id=ta.id and e.current_status='IN_TREATMENT' then
    already_here:=true;
  end if;

  old_unit:=e.current_unit_id;
  old_area:=e.current_treatment_area_id;

  -- If the sender already requested exactly this handoff, complete that request.
  select *
  into matching_handoff
  from public.ems_handoffs h
  where h.encounter_id=e.id
    and h.status='PENDING'
    and h.to_treatment_area_id=ta.id
  order by h.requested_at
  limit 1;

  if matching_handoff.id is not null then
    update public.ems_handoffs
    set status='COMPLETED',
        responded_by=auth.uid(),
        responded_at=now(),
        completed_at=now(),
        note=coalesce(nullif(trim(p_note),''),note)
    where id=matching_handoff.id;

    new_handoff_id:=matching_handoff.id;
  elsif not already_here and (old_unit is not null or old_area is not null) then
    insert into public.ems_handoffs(
      event_id,encounter_id,
      from_unit_id,from_treatment_area_id,
      to_unit_id,to_treatment_area_id,
      status,note,
      requested_by,requested_at,
      responded_by,responded_at,completed_at
    ) values(
      i.event_id,e.id,
      old_unit,old_area,
      null,ta.id,
      'COMPLETED',nullif(trim(p_note),''),
      auth.uid(),now(),
      auth.uid(),now(),now()
    )
    returning id into new_handoff_id;
  end if;

  -- A confirmed real-world custody state supersedes other pending requests.
  update public.ems_handoffs
  set status='CANCELLED',
      responded_by=auth.uid(),
      responded_at=now(),
      note=coalesce(note,'Cancelled when treatment-area custody was confirmed')
  where encounter_id=e.id
    and status='PENDING'
    and (new_handoff_id is null or id<>new_handoff_id);

  update public.ems_encounters
  set current_unit_id=null,
      current_treatment_area_id=ta.id,
      current_status='IN_TREATMENT',
      operational_note=coalesce(nullif(trim(p_note),''),operational_note)
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,old_unit,'EMS_TREATMENT_RECEIVED',
    jsonb_build_object(
      'encounter_id',e.id,
      'incident_number',i.incident_number,
      'handoff_id',new_handoff_id,
      'from_unit_id',old_unit,
      'from_treatment_area_id',old_area,
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'confirmation_source',p_actor_kind,
      'already_here',already_here,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  if already_here then
    return 'ALREADY_HERE';
  end if;

  return 'RECEIVED';
end;
$$;

revoke all on function private.place_incident_in_treatment(uuid,uuid,text,text) from public;

create or replace function public.ems_dispatch_mark_treatment_handoff(
  p_incident_id uuid,
  p_treatment_area_id uuid,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
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

  return private.place_incident_in_treatment(
    p_incident_id,
    p_treatment_area_id,
    p_note,
    'staff'
  );
end;
$$;

create or replace function public.treatment_receive_incident(
  p_treatment_area_id uuid,
  p_incident_id uuid,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path=public
as $$
begin
  if private.current_treatment_area() is distinct from p_treatment_area_id then
    raise exception 'This station is not currently assigned to that treatment area';
  end if;

  return private.place_incident_in_treatment(
    p_incident_id,
    p_treatment_area_id,
    p_note,
    'treatment'
  );
end;
$$;

create or replace function public.treatment_search_open_incidents(
  p_treatment_area_id uuid,
  p_query text default null
) returns table(
  incident_id uuid,
  incident_number text,
  call_type text,
  priority text,
  landmark text,
  created_at timestamptz,
  current_ems_status text,
  current_treatment_area_id uuid
)
language sql
stable
security definer
set search_path=public
as $$
  select
    i.id,
    i.incident_number,
    i.call_type,
    i.priority,
    i.landmark,
    i.created_at,
    e.current_status,
    e.current_treatment_area_id
  from public.ems_treatment_areas ta
  join public.incidents i
    on i.event_id=ta.event_id
   and i.status<>'CLOSED'
  left join lateral (
    select ee.current_status,ee.current_treatment_area_id
    from public.ems_encounters ee
    where ee.event_id=i.event_id
      and ee.incident_id=i.id
      and ee.current_status<>'CLOSED'
    order by ee.created_at
    limit 1
  ) e on true
  where ta.id=p_treatment_area_id
    and ta.active=true
    and private.current_treatment_area()=ta.id
    and (
      trim(coalesce(p_query,''))=''
      or i.incident_number ilike '%'||trim(p_query)||'%'
      or i.call_type ilike '%'||trim(p_query)||'%'
      or coalesce(i.landmark,'') ilike '%'||trim(p_query)||'%'
    )
  order by i.created_at desc
  limit 15;
$$;

grant execute on function public.ems_dispatch_mark_treatment_handoff(uuid,uuid,text) to authenticated;
grant execute on function public.treatment_receive_incident(uuid,uuid,text) to authenticated;
grant execute on function public.treatment_search_open_incidents(uuid,text) to authenticated;


-- CommCenter Pro v0.6.0
-- Dispatcher quick POIs.
--
-- New incident modal, dispatcher department scope, and Command Center Display
-- are frontend/workstation features and do not require database tables.
--
-- This migration permits a dispatcher to create EVENT-ONLY POIs without
-- granting direct INSERT permission on the map-builder tables.

create or replace function public.dispatcher_create_poi(
  p_event_id uuid,
  p_name text,
  p_category text,
  p_map_layer_id uuid,
  p_zone_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text default null,
  p_notes text default null,
  p_aliases text[] default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_id_value uuid;
  square_id_value bigint;
  alias_value text;
begin
  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatch access required';
  end if;

  if trim(coalesce(p_name,''))='' then
    raise exception 'POI name is required';
  end if;

  if p_latitude is null or p_latitude not between -90 and 90
     or p_longitude is null or p_longitude not between -180 and 180 then
    raise exception 'Valid latitude/longitude are required';
  end if;

  if p_map_x is null or p_map_y is null then
    raise exception 'Map coordinates are required';
  end if;

  if p_map_layer_id is null or not exists(
    select 1
    from public.event_map_layers
    where id=p_map_layer_id
      and event_id=p_event_id
      and active=true
  ) then
    raise exception 'A valid event map layer is required';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones
    where id=p_zone_id
      and event_id=p_event_id
      and map_layer_id=p_map_layer_id
      and active=true
  ) then
    raise exception 'Zone is not valid for the selected map layer';
  end if;

  if nullif(trim(p_w3w),'') is not null then
    select id
    into square_id_value
    from public.event_w3w_squares
    where event_id=p_event_id
      and words=regexp_replace(trim(p_w3w),'^/+', '')
    limit 1;
  end if;

  insert into public.event_pois(
    event_id,
    map_layer_id,
    zone_id,
    name,
    category,
    w3w_square_id,
    w3w,
    latitude,
    longitude,
    map_x,
    map_y,
    notes,
    active,
    poi_scope
  ) values(
    p_event_id,
    p_map_layer_id,
    p_zone_id,
    trim(p_name),
    nullif(trim(p_category),''),
    square_id_value,
    nullif(regexp_replace(trim(coalesce(p_w3w,'')),'^/+', ''),''),
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    nullif(trim(p_notes),''),
    true,
    'event'
  )
  returning id into poi_id_value;

  foreach alias_value in array coalesce(p_aliases,array[]::text[]) loop
    alias_value:=trim(alias_value);
    if alias_value<>'' then
      insert into public.poi_aliases(poi_id,alias)
      values(poi_id_value,alias_value)
      on conflict(poi_id,alias) do nothing;
    end if;
  end loop;

  insert into public.cad_activity(
    event_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    p_event_id,
    'POI_CREATED',
    jsonb_build_object(
      'poi_id',poi_id_value,
      'name',trim(p_name),
      'category',nullif(trim(p_category),''),
      'map_layer_id',p_map_layer_id,
      'zone_id',p_zone_id,
      'w3w',nullif(regexp_replace(trim(coalesce(p_w3w,'')),'^/+', ''),''),
      'source','dispatcher'
    ),
    auth.uid(),
    'staff'
  );

  return poi_id_value;
end;
$$;

revoke all on function public.dispatcher_create_poi(
  uuid,text,text,uuid,uuid,double precision,double precision,
  double precision,double precision,text,text,text[]
) from public;

grant execute on function public.dispatcher_create_poi(
  uuid,text,text,uuid,uuid,double precision,double precision,
  double precision,double precision,text,text,text[]
) to authenticated;

-- Make newly created POIs visible to other live CAD clients without requiring
-- a page refresh. Clients that do not subscribe are unaffected.
do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='event_pois'
  ) then
    alter publication supabase_realtime add table public.event_pois;
  end if;
end $$;


-- CommCenter Pro v0.6.1
-- Treatment Area cad_activity actor-kind hotfix.
--
-- v0.5.2 introduced treatment-area custody confirmation and correctly records
-- the confirmation source as actor_kind='treatment'. The original cad_activity
-- CHECK constraint only allowed staff/field/system, so Treatment Area Station
-- could reconcile custody successfully up to the audit-log INSERT and then fail
-- with:
--
-- new row for relation "cad_activity" violates check constraint
-- "cad_activity_actor_kind_check"
--
-- This migration expands only the audit-log actor classification. It does not
-- change treatment-area permissions or incident/custody behavior.

alter table public.cad_activity
  drop constraint if exists cad_activity_actor_kind_check;

alter table public.cad_activity
  add constraint cad_activity_actor_kind_check
  check(actor_kind in ('staff','field','system','treatment'));


-- CommCenter Pro v0.7.0
-- Direct EMS custody transfers; handoff requests retired.
--
-- Operational model:
-- * The CAD incident number remains the patient reference.
-- * A handoff is recorded when it happens; there is no request/accept workflow.
-- * Dispatch can place/transfer a patient directly to a treatment area OR ambulance.
-- * Field teams can transfer directly to a treatment area or ambulance.
-- * Treatment areas can transfer directly to an ambulance.
-- * Treatment Area Station can still reconcile an arrival by searching the incident.
-- * ems_handoffs remains as the historical transfer ledger; new rows are COMPLETED immediately.


-- Ensure Treatment Area Station audit rows are valid even when upgrading from
-- a database that did not receive the v0.6.1 hotfix separately.
alter table public.cad_activity
  drop constraint if exists cad_activity_actor_kind_check;

alter table public.cad_activity
  add constraint cad_activity_actor_kind_check
  check(actor_kind in ('staff','field','system','treatment'));

-- Retire any legacy request that was still waiting when this migration is applied.
update public.ems_handoffs
set
  status='CANCELLED',
  responded_at=coalesce(responded_at,now()),
  note=case
    when nullif(trim(coalesce(note,'')),'') is null then 'Cancelled when direct handoff workflow was enabled'
    else note||' · Cancelled when direct handoff workflow was enabled'
  end
where status='PENDING';

-- Keep encounter creation aligned with the incident-number patient-reference model.
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
  i public.incidents;
  encounter_id uuid;
  initial_status text;
  actor_kind_value text;
begin
  if p_incident_id is null then
    raise exception 'A CAD incident is required for EMS custody';
  end if;

  if ((p_source_unit_id is not null)::int + (p_source_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Exactly one source resource is required';
  end if;

  select * into i
  from public.incidents
  where id=p_incident_id
    and event_id=p_event_id
    and status<>'CLOSED';

  if i.id is null then
    raise exception 'Active incident is not part of this event';
  end if;

  select id into encounter_id
  from public.ems_encounters
  where event_id=p_event_id
    and incident_id=p_incident_id
    and current_status<>'CLOSED'
  order by created_at
  limit 1;

  if encounter_id is not null then
    return encounter_id;
  end if;

  if p_source_unit_id is not null then
    if not exists(
      select 1 from public.units
      where id=p_source_unit_id and event_id=p_event_id and active=true
    ) then
      raise exception 'Unit is not part of this event';
    end if;

    if not (
      public.can_dispatch_event(p_event_id)
      or public.field_has_unit_access(p_source_unit_id)
    ) then
      raise exception 'Not authorized for this unit';
    end if;

    if exists(
      select 1 from public.ems_unit_config
      where unit_id=p_source_unit_id
        and active=true
        and (ems_role='ambulance' or transport_capable=true)
    ) then
      initial_status:='WITH_AMBULANCE';
    else
      initial_status:='FIELD';
    end if;
  else
    if not exists(
      select 1 from public.ems_treatment_areas
      where id=p_source_treatment_area_id
        and event_id=p_event_id
        and active=true
    ) then
      raise exception 'Treatment area is not part of this event';
    end if;

    if not (
      public.can_dispatch_event(p_event_id)
      or private.current_treatment_area()=p_source_treatment_area_id
    ) then
      raise exception 'Not authorized for this treatment area';
    end if;

    initial_status:='IN_TREATMENT';
  end if;

  actor_kind_value:=case
    when public.can_dispatch_event(p_event_id) then 'staff'
    when p_source_treatment_area_id is not null then 'treatment'
    else 'field'
  end;

  insert into public.ems_encounters(
    event_id,incident_id,tracking_number,current_status,current_unit_id,
    current_treatment_area_id,origin_unit_id,operational_note,created_by
  ) values(
    p_event_id,p_incident_id,i.incident_number,initial_status,p_source_unit_id,
    p_source_treatment_area_id,
    case when initial_status='FIELD' then p_source_unit_id else null end,
    nullif(trim(p_operational_note),''),
    auth.uid()
  )
  returning id into encounter_id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,p_incident_id,p_source_unit_id,'EMS_FLOW_STARTED',
    jsonb_build_object(
      'encounter_id',encounter_id,
      'incident_number',i.incident_number,
      'current_status',initial_status,
      'treatment_area_id',p_source_treatment_area_id
    ),
    auth.uid(),actor_kind_value
  );

  return encounter_id;
end;
$$;

-- Internal direct-transfer primitive.
create or replace function private.ems_direct_transfer(
  p_encounter_id uuid,
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
  e public.ems_encounters;
  ta public.ems_treatment_areas;
  old_unit uuid;
  old_area uuid;
  new_status text;
  occupancy integer;
  handoff_id uuid;
begin
  if ((p_to_unit_id is not null)::int + (p_to_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Choose exactly one handoff destination';
  end if;

  select * into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS custody record not found';
  end if;

  if p_to_unit_id is not null then
    if not exists(
      select 1 from public.units u
      where u.id=p_to_unit_id
        and u.event_id=e.event_id
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

    if e.current_unit_id=p_to_unit_id and e.current_status in ('WITH_AMBULANCE','TRANSPORTING') then
      return 'ALREADY_HERE';
    end if;

    new_status:='WITH_AMBULANCE';
  else
    select * into ta
    from public.ems_treatment_areas
    where id=p_to_treatment_area_id
      and event_id=e.event_id
      and active=true;

    if ta.id is null then
      raise exception 'Treatment area is not part of this event';
    end if;

    if e.current_treatment_area_id=p_to_treatment_area_id and e.current_status='IN_TREATMENT' then
      return 'ALREADY_HERE';
    end if;

    if not ta.accepting_patients or ta.status in ('FULL','CLOSED') then
      raise exception 'Treatment area is not accepting patients';
    end if;

    select count(*) into occupancy
    from public.ems_encounters x
    where x.current_treatment_area_id=ta.id
      and x.current_status<>'CLOSED'
      and x.id<>e.id;

    if occupancy>=ta.capacity then
      raise exception 'Treatment area is at capacity';
    end if;

    new_status:='IN_TREATMENT';
  end if;

  old_unit:=e.current_unit_id;
  old_area:=e.current_treatment_area_id;

  -- No request state survives a real-world custody transfer.
  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now()),
    note=coalesce(note,'Cancelled by direct custody transfer')
  where encounter_id=e.id
    and status='PENDING';

  -- Historical transfer ledger: completed immediately.
  if old_unit is not null or old_area is not null then
    insert into public.ems_handoffs(
      event_id,encounter_id,
      from_unit_id,from_treatment_area_id,
      to_unit_id,to_treatment_area_id,
      status,note,
      requested_by,requested_at,
      responded_by,responded_at,completed_at
    ) values(
      e.event_id,e.id,
      old_unit,old_area,
      p_to_unit_id,p_to_treatment_area_id,
      'COMPLETED',nullif(trim(p_note),''),
      auth.uid(),now(),
      auth.uid(),now(),now()
    )
    returning id into handoff_id;
  end if;

  update public.ems_encounters
  set
    current_unit_id=p_to_unit_id,
    current_treatment_area_id=p_to_treatment_area_id,
    current_status=new_status,
    operational_note=coalesce(nullif(trim(p_note),''),operational_note)
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,e.incident_id,old_unit,'EMS_HANDOFF_COMPLETED',
    jsonb_build_object(
      'encounter_id',e.id,
      'handoff_id',handoff_id,
      'from_unit_id',old_unit,
      'from_treatment_area_id',old_area,
      'to_unit_id',p_to_unit_id,
      'to_treatment_area_id',p_to_treatment_area_id,
      'direct',true,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  return 'TRANSFERRED';
end;
$$;

revoke all on function private.ems_direct_transfer(uuid,uuid,uuid,text,text) from public;

-- Internal incident-level setter. This allows Dispatch or Treatment Area Station
-- to reconcile real-world custody even if no EMS flow row existed beforehand.
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
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  return 'RECEIVED';
end;
$$;

revoke all on function private.ems_set_incident_custody(uuid,uuid,uuid,text,text) from public;

-- Current holder transfers custody immediately.
create or replace function public.ems_transfer_custody(
  p_encounter_id uuid,
  p_to_unit_id uuid default null,
  p_to_treatment_area_id uuid default null,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  actor_kind_value text;
begin
  select * into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS custody record not found';
  end if;

  if public.can_dispatch_event(e.event_id) then
    actor_kind_value:='staff';
  elsif e.current_treatment_area_id is not null
        and private.current_treatment_area()=e.current_treatment_area_id then
    actor_kind_value:='treatment';
  elsif e.current_unit_id is not null
        and private.current_field_unit()=e.current_unit_id then
    actor_kind_value:='field';
  else
    raise exception 'Only Dispatch or the current custodian can hand off this patient';
  end if;

  return private.ems_direct_transfer(
    e.id,p_to_unit_id,p_to_treatment_area_id,p_note,actor_kind_value
  );
end;
$$;

-- Dispatch can set or transfer an incident directly to either destination type.
create or replace function public.ems_dispatch_set_incident_custody(
  p_incident_id uuid,
  p_to_unit_id uuid default null,
  p_to_treatment_area_id uuid default null,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
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

  return private.ems_set_incident_custody(
    p_incident_id,p_to_unit_id,p_to_treatment_area_id,p_note,'staff'
  );
end;
$$;

-- Treatment Area Station: physical receipt is authoritative and immediate.
create or replace function public.treatment_receive_incident(
  p_treatment_area_id uuid,
  p_incident_id uuid,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path=public
as $$
begin
  if private.current_treatment_area() is distinct from p_treatment_area_id then
    raise exception 'This station is not currently assigned to that treatment area';
  end if;

  return private.ems_set_incident_custody(
    p_incident_id,null,p_treatment_area_id,p_note,'treatment'
  );
end;
$$;

-- Backward-compatible Dispatch function name; now performs a direct transfer.
create or replace function public.ems_dispatch_mark_treatment_handoff(
  p_incident_id uuid,
  p_treatment_area_id uuid,
  p_note text default null
) returns text
language sql
security definer
set search_path=public
as $$
  select public.ems_dispatch_set_incident_custody(
    p_incident_id,null,p_treatment_area_id,p_note
  );
$$;

revoke all on function public.ems_transfer_custody(uuid,uuid,uuid,text) from public;
revoke all on function public.ems_dispatch_set_incident_custody(uuid,uuid,uuid,text) from public;
revoke all on function public.treatment_receive_incident(uuid,uuid,text) from public;

grant execute on function public.ems_transfer_custody(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.ems_dispatch_set_incident_custody(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.treatment_receive_incident(uuid,uuid,text) to authenticated;

-- The old request/accept RPCs remain defined for historical compatibility, but
-- the v0.7 frontend does not call or expose them.


-- W3W is retired from the active application workflow. These wrapper RPCs keep
-- the existing database columns available for historical compatibility while
-- new application writes omit W3W entirely.

create or replace function public.create_incident_v3(
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
  p_zone_id uuid default null
) returns uuid
language sql
security definer
set search_path=public
as $$
  select public.create_incident_v2(
    p_event_id,p_department_ids,p_call_type,p_priority,
    p_latitude,p_longitude,p_map_x,p_map_y,
    null,p_landmark,p_notes,p_poi_id,p_map_layer_id,p_zone_id
  );
$$;

create or replace function public.update_incident_v3(
  p_incident_id uuid,
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
  p_zone_id uuid default null
) returns void
language sql
security definer
set search_path=public
as $$
  select public.update_incident_v2(
    p_incident_id,p_department_ids,p_call_type,p_priority,
    p_latitude,p_longitude,p_map_x,p_map_y,
    null,p_landmark,p_notes,p_poi_id,p_map_layer_id,p_zone_id
  );
$$;

create or replace function public.dispatcher_create_poi_v2(
  p_event_id uuid,
  p_name text,
  p_category text,
  p_map_layer_id uuid,
  p_zone_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_notes text default null,
  p_aliases text[] default null
) returns uuid
language sql
security definer
set search_path=public
as $$
  select public.dispatcher_create_poi(
    p_event_id,p_name,p_category,p_map_layer_id,p_zone_id,
    p_latitude,p_longitude,p_map_x,p_map_y,
    null,p_notes,p_aliases
  );
$$;

revoke all on function public.create_incident_v3(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid) from public;
revoke all on function public.update_incident_v3(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid) from public;
revoke all on function public.dispatcher_create_poi_v2(uuid,text,text,uuid,uuid,double precision,double precision,double precision,double precision,text,text[]) from public;

grant execute on function public.create_incident_v3(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid) to authenticated;
grant execute on function public.update_incident_v3(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,uuid,uuid,uuid) to authenticated;
grant execute on function public.dispatcher_create_poi_v2(uuid,text,text,uuid,uuid,double precision,double precision,double precision,double precision,text,text[]) to authenticated;


-- Fully retire the old request/accept API for normal clients. Historical
-- functions remain in the database only so old migration history stays intact.
revoke execute on function public.ems_request_handoff(uuid,uuid,uuid,text) from authenticated;
revoke execute on function public.ems_accept_handoff(uuid) from authenticated;
revoke execute on function public.ems_decline_handoff(uuid,text) from authenticated;
revoke execute on function public.ems_cancel_handoff(uuid) from authenticated;


-- CommCenter Pro v0.7.1
-- Keep CAD unit commitment synchronized with direct EMS custody transfers.
--
-- Rules:
-- * When custody leaves a field unit, that initial/current field unit is cleared
--   from the CAD incident and returned to AVAILABLE.
-- * When custody is handed to an ambulance, that ambulance is automatically
--   committed/assigned to the CAD incident.
-- * If no EMS custody row existed yet, any actively assigned EMS field-team
--   unit(s) are treated as the initial patient-care unit(s) and cleared.
-- * Non-EMS departments/units are never cleared by this helper.
-- * An ambulance already committed to another open incident cannot be silently
--   stolen; the handoff is rejected transactionally instead.

alter table public.unit_status_log
  drop constraint if exists unit_status_log_actor_kind_check;

alter table public.unit_status_log
  add constraint unit_status_log_actor_kind_check
  check(actor_kind in ('staff','field','system','treatment'));

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
  incident_number_value text;
  other_incident text;
  clear_rec record;
  old_status_value text;
  destination_old_status text;
  old_assignment_active boolean:=false;
begin
  select event_id,incident_number
  into eid,incident_number_value
  from public.incidents
  where id=p_incident_id
    and status='OPEN';

  if eid is null then
    raise exception 'Active incident not found';
  end if;

  -- Validate the destination ambulance assignment before clearing anything.
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

  -- Normal case: clear the unit that actually had EMS custody.
  -- Reconciliation case: if there was no custody row/unit assignment to identify,
  -- clear only EMS field-team units from this incident, never Security/Facilities
  -- or other non-patient-care resources.
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
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=clear_rec.unit_id
      and cleared_at is null;

    update public.units
    set status='AVAILABLE'
    where id=clear_rec.unit_id;

    if old_status_value is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind
      ) values(
        eid,p_incident_id,clear_rec.unit_id,old_status_value,'AVAILABLE',
        auth.uid(),p_actor_kind
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,clear_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','EMS_HANDOFF',
        'automatic',true
      ),
      auth.uid(),p_actor_kind
    );
  end loop;

  -- A receiving ambulance becomes the committed CAD unit for the same patient/call.
  if p_to_unit_id is not null and not exists(
    select 1
    from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_to_unit_id
      and cleared_at is null
  ) then
    select status
    into destination_old_status
    from public.units
    where id=p_to_unit_id;

    insert into public.incident_units(incident_id,unit_id)
    values(p_incident_id,p_to_unit_id)
    on conflict(incident_id,unit_id)
    do update set assigned_at=now(),cleared_at=null;

    update public.units
    set status='ASSIGNED'
    where id=p_to_unit_id;

    if destination_old_status is distinct from 'ASSIGNED' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind
      ) values(
        eid,p_incident_id,p_to_unit_id,destination_old_status,'ASSIGNED',
        auth.uid(),p_actor_kind
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_to_unit_id,'UNIT_ASSIGNED',
      jsonb_build_object(
        'reason','EMS_HANDOFF',
        'automatic',true
      ),
      auth.uid(),p_actor_kind
    );
  end if;
end;
$$;

revoke all on function private.ems_sync_incident_units(uuid,uuid,uuid,text) from public;

create or replace function private.ems_direct_transfer(
  p_encounter_id uuid,
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
  e public.ems_encounters;
  ta public.ems_treatment_areas;
  old_unit uuid;
  old_area uuid;
  new_status text;
  occupancy integer;
  handoff_id uuid;
begin
  if ((p_to_unit_id is not null)::int + (p_to_treatment_area_id is not null)::int) <> 1 then
    raise exception 'Choose exactly one handoff destination';
  end if;

  select * into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS custody record not found';
  end if;

  if p_to_unit_id is not null then
    if not exists(
      select 1 from public.units u
      where u.id=p_to_unit_id
        and u.event_id=e.event_id
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

    if e.current_unit_id=p_to_unit_id and e.current_status in ('WITH_AMBULANCE','TRANSPORTING') then
      return 'ALREADY_HERE';
    end if;

    new_status:='WITH_AMBULANCE';
  else
    select * into ta
    from public.ems_treatment_areas
    where id=p_to_treatment_area_id
      and event_id=e.event_id
      and active=true;

    if ta.id is null then
      raise exception 'Treatment area is not part of this event';
    end if;

    if e.current_treatment_area_id=p_to_treatment_area_id and e.current_status='IN_TREATMENT' then
      return 'ALREADY_HERE';
    end if;

    if not ta.accepting_patients or ta.status in ('FULL','CLOSED') then
      raise exception 'Treatment area is not accepting patients';
    end if;

    select count(*) into occupancy
    from public.ems_encounters x
    where x.current_treatment_area_id=ta.id
      and x.current_status<>'CLOSED'
      and x.id<>e.id;

    if occupancy>=ta.capacity then
      raise exception 'Treatment area is at capacity';
    end if;

    new_status:='IN_TREATMENT';
  end if;

  old_unit:=e.current_unit_id;
  old_area:=e.current_treatment_area_id;

  -- Synchronize CAD assignment before committing custody. PostgreSQL function
  -- execution is transactional, so a destination conflict rolls back the
  -- entire handoff instead of leaving EMS custody and CAD assignment divergent.
  perform private.ems_sync_incident_units(
    e.incident_id,
    old_unit,
    p_to_unit_id,
    p_actor_kind
  );

  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now()),
    note=coalesce(note,'Cancelled by direct custody transfer')
  where encounter_id=e.id
    and status='PENDING';

  if old_unit is not null or old_area is not null then
    insert into public.ems_handoffs(
      event_id,encounter_id,
      from_unit_id,from_treatment_area_id,
      to_unit_id,to_treatment_area_id,
      status,note,
      requested_by,requested_at,
      responded_by,responded_at,completed_at
    ) values(
      e.event_id,e.id,
      old_unit,old_area,
      p_to_unit_id,p_to_treatment_area_id,
      'COMPLETED',nullif(trim(p_note),''),
      auth.uid(),now(),
      auth.uid(),now(),now()
    )
    returning id into handoff_id;
  end if;

  update public.ems_encounters
  set
    current_unit_id=p_to_unit_id,
    current_treatment_area_id=p_to_treatment_area_id,
    current_status=new_status,
    operational_note=coalesce(nullif(trim(p_note),''),operational_note)
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,e.incident_id,old_unit,'EMS_HANDOFF_COMPLETED',
    jsonb_build_object(
      'encounter_id',e.id,
      'handoff_id',handoff_id,
      'from_unit_id',old_unit,
      'from_treatment_area_id',old_area,
      'to_unit_id',p_to_unit_id,
      'to_treatment_area_id',p_to_treatment_area_id,
      'cad_assignment_synced',true,
      'direct',true,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  return 'TRANSFERRED';
end;
$$;

revoke all on function private.ems_direct_transfer(uuid,uuid,uuid,text,text) from public;

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

  -- There is no existing EMS custodian row, so use the incident's active EMS
  -- field-team assignment(s) as the initial patient-care unit(s). These are
  -- cleared, and the receiving ambulance is committed when applicable.
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


-- CommCenter Pro v0.7.3
-- Incident-close unit release + transport destination tracking.

alter table public.units
  add column if not exists current_transport_destination_text text,
  add column if not exists current_transport_treatment_area_id uuid
    references public.ems_treatment_areas(id) on delete set null;

alter table public.units
  drop constraint if exists units_transport_destination_check;

alter table public.units
  add constraint units_transport_destination_check
  check (
    not (
      current_transport_destination_text is not null
      and current_transport_treatment_area_id is not null
    )
  );

alter table public.unit_status_log
  add column if not exists transport_destination_text text,
  add column if not exists transport_treatment_area_id uuid
    references public.ems_treatment_areas(id) on delete set null;

-- Staff status update with destination-aware TRANSPORTING behavior.
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

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
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
        'to',p_status,
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

-- Field version of the destination-aware status update.
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

  select exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) into is_ambulance;

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

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,client_time,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
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
        'to',p_status,
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

revoke all on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) from public;
grant execute on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) to authenticated;

-- Starting transport from the EMS panel also updates the normal CAD unit status
-- and destination fields so the two views cannot diverge.
create or replace function public.ems_mark_transporting(
  p_encounter_id uuid,
  p_destination text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  old_status_value text;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if e.current_unit_id is null or not exists(
    select 1 from public.ems_unit_config c
    where c.unit_id=e.current_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'Current holder is not a transport-capable EMS unit';
  end if;

  if nullif(trim(p_destination),'') is null then
    raise exception 'Destination facility is required';
  end if;

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
  ) then
    raise exception 'Only Dispatch or the transporting unit can start transport';
  end if;

  select status into old_status_value
  from public.units
  where id=e.current_unit_id;

  update public.ems_encounters
  set
    current_status='TRANSPORTING',
    transport_destination=trim(p_destination),
    transport_started_at=coalesce(transport_started_at,now())
  where id=e.id;

  update public.units
  set
    status='TRANSPORTING',
    current_transport_destination_text=trim(p_destination),
    current_transport_treatment_area_id=null
  where id=e.current_unit_id;

  if old_status_value is distinct from 'TRANSPORTING' then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      e.event_id,e.incident_id,e.current_unit_id,
      old_status_value,'TRANSPORTING',
      auth.uid(),
      case when public.can_dispatch_event(e.event_id) then 'staff' else 'field' end,
      trim(p_destination),null
    );

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      e.event_id,e.incident_id,e.current_unit_id,
      'UNIT_STATUS_CHANGED',
      jsonb_build_object(
        'from',old_status_value,
        'to','TRANSPORTING',
        'transport_destination_text',trim(p_destination)
      ),
      auth.uid(),
      case when public.can_dispatch_event(e.event_id) then 'staff' else 'field' end
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    e.event_id,e.incident_id,e.current_unit_id,
    'EMS_TRANSPORT_STARTED',
    jsonb_build_object(
      'encounter_id',e.id,
      'destination',trim(p_destination)
    ),
    auth.uid(),
    case when public.can_dispatch_event(e.event_id) then 'staff' else 'field' end
  );
end;
$$;

-- Keep automatic EMS handoff assignment changes from leaving stale transport
-- destination data behind.
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
  incident_number_value text;
  other_incident text;
  clear_rec record;
  old_status_value text;
  destination_old_status text;
  old_assignment_active boolean:=false;
begin
  select event_id,incident_number
  into eid,incident_number_value
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
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=clear_rec.unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=clear_rec.unit_id;

    if old_status_value is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,clear_rec.unit_id,old_status_value,'AVAILABLE',
        auth.uid(),p_actor_kind,null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,clear_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','EMS_HANDOFF',
        'automatic',true
      ),
      auth.uid(),p_actor_kind
    );
  end loop;

  if p_to_unit_id is not null and not exists(
    select 1
    from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_to_unit_id
      and cleared_at is null
  ) then
    select status
    into destination_old_status
    from public.units
    where id=p_to_unit_id;

    insert into public.incident_units(incident_id,unit_id)
    values(p_incident_id,p_to_unit_id)
    on conflict(incident_id,unit_id)
    do update set assigned_at=now(),cleared_at=null;

    update public.units
    set
      status='ASSIGNED',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=p_to_unit_id;

    if destination_old_status is distinct from 'ASSIGNED' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,p_to_unit_id,destination_old_status,'ASSIGNED',
        auth.uid(),p_actor_kind,null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_to_unit_id,'UNIT_ASSIGNED',
      jsonb_build_object(
        'reason','EMS_HANDOFF',
        'automatic',true
      ),
      auth.uid(),p_actor_kind
    );
  end if;
end;
$$;

revoke all on function private.ems_sync_incident_units(uuid,uuid,uuid,text) from public;

-- Closing a CAD call releases every unit still committed to that call and
-- returns each one to AVAILABLE.
create or replace function public.close_incident(
  p_incident_id uuid,
  p_disposition text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  unit_rec record;
  released_count integer:=0;
begin
  select event_id
  into eid
  from public.incidents
  where id=p_incident_id;

  if eid is null then
    raise exception 'Incident not found';
  end if;

  if not public.can_dispatch_event(eid) then
    raise exception 'Dispatch access required';
  end if;

  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=p_incident_id
      and iu.cleared_at is null
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=unit_rec.unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=unit_rec.unit_id;

    if unit_rec.status is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
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
    disposition=p_disposition
  where id=p_incident_id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',p_disposition,
      'released_units',released_count
    ),
    auth.uid(),'staff'
  );
end;
$$;


-- CommCenter Pro v0.7.5
-- Arrive transporting units at their selected treatment-area destination.
--
-- This is another entry point into the same incident-level EMS patient flow:
--
-- TRANSPORTING unit
--   -> Arrived at Treatment Area
--   -> treatment area becomes current EMS custody
--   -> transporting unit is cleared from the CAD incident
--   -> transporting unit becomes AVAILABLE
--   -> treatment-area census updates through the existing EMS encounter flow
--
-- The destination comes from units.current_transport_treatment_area_id so the
-- arrival action cannot accidentally hand the patient to a different area.

create or replace function public.unit_arrive_treatment_area(
  p_unit_id uuid,
  p_incident_id uuid
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  unit_status_value text;
  treatment_area_id_value uuid;
  treatment_area_name_value text;
  encounter_id_value uuid;
  actor_kind_value text;
  still_assigned boolean;
  old_status_value text;
begin
  select
    u.event_id,
    u.status,
    u.current_transport_treatment_area_id
  into
    eid,
    unit_status_value,
    treatment_area_id_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this unit';
  end if;

  if unit_status_value<>'TRANSPORTING' then
    raise exception 'Unit must be TRANSPORTING before it can arrive at a treatment area';
  end if;

  if treatment_area_id_value is null then
    raise exception 'This unit does not have a treatment-area transport destination';
  end if;

  if not exists(
    select 1
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.incident_id=p_incident_id
      and iu.unit_id=p_unit_id
      and iu.cleared_at is null
      and i.event_id=eid
      and i.status='OPEN'
  ) then
    raise exception 'Unit is not actively committed to that incident';
  end if;

  select a.name
  into treatment_area_name_value
  from public.ems_treatment_areas a
  where a.id=treatment_area_id_value
    and a.event_id=eid
    and a.active=true;

  if treatment_area_name_value is null then
    raise exception 'Treatment-area destination is no longer active';
  end if;

  -- If the incident has no EMS custody row yet, establish this transporting
  -- unit as the current patient custodian first. ems_create_encounter() returns
  -- the existing open encounter when one already exists.
  select public.ems_create_encounter(
    eid,
    p_incident_id,
    p_unit_id,
    null,
    null
  )
  into encounter_id_value;

  -- Use the same direct-custody transfer primitive as the incident-level
  -- Handoff / Custody workflow. This updates EMS custody, the transfer ledger,
  -- treatment-area census, CAD assignment, and unit status atomically.
  perform private.ems_direct_transfer(
    encounter_id_value,
    null,
    treatment_area_id_value,
    'Arrived at treatment area',
    actor_kind_value
  );

  -- In the normal path, ems_direct_transfer clears p_unit_id because it was the
  -- current EMS custodian. If an older/reconciled encounter had a different
  -- current custodian, make sure the transporting unit is still cleared too.
  select exists(
    select 1
    from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null
  )
  into still_assigned;

  if still_assigned then
    select status
    into old_status_value
    from public.units
    where id=p_unit_id;

    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=p_unit_id;

    if old_status_value is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,p_unit_id,
        old_status_value,'AVAILABLE',
        auth.uid(),actor_kind_value,
        null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,
      'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','ARRIVED_TREATMENT_AREA',
        'treatment_area_id',treatment_area_id_value,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );
  end if;

  -- The helper normally clears these fields along with the unit assignment;
  -- explicitly clear them here as a final state guarantee.
  update public.units
  set
    status='AVAILABLE',
    current_transport_destination_text=null,
    current_transport_treatment_area_id=null
  where id=p_unit_id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    'UNIT_ARRIVED_TREATMENT_AREA',
    jsonb_build_object(
      'treatment_area_id',treatment_area_id_value,
      'treatment_area_name',treatment_area_name_value,
      'encounter_id',encounter_id_value,
      'patient_custody_transferred',true
    ),
    auth.uid(),actor_kind_value
  );

  return treatment_area_name_value;
end;
$$;

revoke all on function public.unit_arrive_treatment_area(uuid,uuid) from public;
grant execute on function public.unit_arrive_treatment_area(uuid,uuid) to authenticated;


-- CommCenter Pro v0.7.6
-- Ambulance transport outcome confirmation.
--
-- When an ambulance has an active EMS transport and is returned to AVAILABLE,
-- CommCenter Pro requires one of two outcomes:
--   DELIVERED = patient delivered to the destination facility
--   REFUSAL   = transport unit obtained a patient refusal
--
-- Either outcome:
-- * closes the EMS patient-flow encounter
-- * clears the ambulance from the CAD incident
-- * returns the ambulance to AVAILABLE
-- * clears its live transport destination
-- * records the disposition and CAD audit history
--
-- The CAD incident itself remains open for Dispatch to close separately.

create or replace function public.ems_finish_ambulance_transport(
  p_unit_id uuid,
  p_incident_id uuid,
  p_outcome text
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  eid uuid;
  unit_status_value text;
  destination_value text;
  outcome_value text;
  disposition_value text;
  actor_kind_value text;
begin
  outcome_value:=upper(trim(coalesce(p_outcome,'')));

  if outcome_value not in ('DELIVERED','REFUSAL') then
    raise exception 'Transport outcome must be DELIVERED or REFUSAL';
  end if;

  select u.event_id,u.status,u.current_transport_destination_text
  into eid,unit_status_value,destination_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active ambulance not found';
  end if;

  if not exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'Unit is not configured as a transport ambulance';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this ambulance';
  end if;

  select *
  into e
  from public.ems_encounters x
  where x.event_id=eid
    and x.incident_id=p_incident_id
    and x.current_unit_id=p_unit_id
    and x.current_status='TRANSPORTING'
  order by x.created_at desc
  limit 1;

  if e.id is null then
    raise exception 'No active ambulance transport was found for this incident';
  end if;

  destination_value:=coalesce(nullif(trim(e.transport_destination),''),nullif(trim(destination_value),''));

  if outcome_value='DELIVERED' and destination_value is null then
    raise exception 'Destination facility is required before recording hospital delivery';
  end if;

  disposition_value:=case
    when outcome_value='DELIVERED' then 'TRANSPORTED'
    else 'REFUSAL'
  end;

  update public.ems_encounters
  set
    current_status='CLOSED',
    transport_destination=destination_value,
    transport_completed_at=case
      when outcome_value='DELIVERED' then now()
      else transport_completed_at
    end,
    final_disposition=disposition_value,
    closed_at=now()
  where id=e.id;

  update public.incident_units
  set cleared_at=now()
  where incident_id=p_incident_id
    and unit_id=p_unit_id
    and cleared_at is null;

  update public.units
  set
    status='AVAILABLE',
    current_transport_destination_text=null,
    current_transport_treatment_area_id=null
  where id=p_unit_id;

  if unit_status_value is distinct from 'AVAILABLE' then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,
      unit_status_value,'AVAILABLE',
      auth.uid(),actor_kind_value,
      destination_value,null
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    case
      when outcome_value='DELIVERED' then 'EMS_TRANSPORT_COMPLETED'
      else 'EMS_TRANSPORT_REFUSAL'
    end,
    jsonb_build_object(
      'encounter_id',e.id,
      'outcome',outcome_value,
      'disposition',disposition_value,
      'destination',destination_value,
      'automatic_unit_release',true
    ),
    auth.uid(),actor_kind_value
  );

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_STATUS_CHANGED',
    jsonb_build_object(
      'from',unit_status_value,
      'to','AVAILABLE',
      'reason',case
        when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED'
        else 'TRANSPORT_REFUSAL'
      end
    ),
    auth.uid(),actor_kind_value
  );

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_UNASSIGNED',
    jsonb_build_object(
      'new_status','AVAILABLE',
      'reason',case
        when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED'
        else 'TRANSPORT_REFUSAL'
      end,
      'automatic',true
    ),
    auth.uid(),actor_kind_value
  );

  return outcome_value;
end;
$$;

revoke all on function public.ems_finish_ambulance_transport(uuid,uuid,text) from public;
grant execute on function public.ems_finish_ambulance_transport(uuid,uuid,text) to authenticated;

-- Keep the older "complete transport" RPC behavior synchronized with CAD.
create or replace function public.ems_complete_transport(
  p_encounter_id uuid,
  p_destination text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if nullif(trim(p_destination),'') is not null then
    update public.ems_encounters
    set transport_destination=trim(p_destination)
    where id=e.id;

    update public.units
    set current_transport_destination_text=trim(p_destination)
    where id=e.current_unit_id;
  end if;

  perform public.ems_finish_ambulance_transport(
    e.current_unit_id,
    e.incident_id,
    'DELIVERED'
  );
end;
$$;

revoke all on function public.ems_complete_transport(uuid,text) from public;
grant execute on function public.ems_complete_transport(uuid,text) to authenticated;

-- Prevent normal status-change APIs from bypassing the disposition prompt.
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

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
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
        'to',p_status,
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

  update public.units
  set
    status=p_status,
    current_transport_destination_text=normalized_text,
    current_transport_treatment_area_id=normalized_area
  where id=p_unit_id;

  if old_s is distinct from p_status then
    insert into public.unit_status_log(
      event_id,incident_id,unit_id,old_status,new_status,
      actor_user_id,actor_kind,client_time,
      transport_destination_text,transport_treatment_area_id
    ) values(
      eid,p_incident_id,p_unit_id,old_s,p_status,
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
        'to',p_status,
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


-- CommCenter Pro v0.8.1
-- Ambulance transport outcome now closes the CAD incident.
--
-- When a transport ambulance changes from TRANSPORTING to AVAILABLE and the
-- user confirms DELIVERED or REFUSAL, CommCenter Pro now:
--   1. closes the EMS encounter with TRANSPORTED or REFUSAL disposition
--   2. releases EVERY unit still committed to the CAD incident
--   3. returns every released unit to AVAILABLE
--   4. clears live transport destinations
--   5. closes the CAD incident
--   6. records the incident disposition and audit trail
--
-- This is allowed from either Dispatch or the current field ambulance.

create or replace function public.ems_finish_ambulance_transport(
  p_unit_id uuid,
  p_incident_id uuid,
  p_outcome text
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  i public.incidents;
  eid uuid;
  unit_status_value text;
  destination_value text;
  outcome_value text;
  disposition_value text;
  actor_kind_value text;
  unit_rec record;
  released_count integer:=0;
begin
  outcome_value:=upper(trim(coalesce(p_outcome,'')));

  if outcome_value not in ('DELIVERED','REFUSAL') then
    raise exception 'Transport outcome must be DELIVERED or REFUSAL';
  end if;

  select u.event_id,u.status,u.current_transport_destination_text
  into eid,unit_status_value,destination_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active ambulance not found';
  end if;

  if not exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'Unit is not configured as a transport ambulance';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this ambulance';
  end if;

  select *
  into i
  from public.incidents
  where id=p_incident_id
    and event_id=eid
    and status='OPEN';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select *
  into e
  from public.ems_encounters x
  where x.event_id=eid
    and x.incident_id=p_incident_id
    and x.current_unit_id=p_unit_id
    and x.current_status='TRANSPORTING'
  order by x.created_at desc
  limit 1;

  if e.id is null then
    raise exception 'No active ambulance transport was found for this incident';
  end if;

  destination_value:=coalesce(
    nullif(trim(e.transport_destination),''),
    nullif(trim(destination_value),'')
  );

  if outcome_value='DELIVERED' and destination_value is null then
    raise exception 'Destination facility is required before recording hospital delivery';
  end if;

  disposition_value:=case
    when outcome_value='DELIVERED' then 'TRANSPORTED'
    else 'REFUSAL'
  end;

  -- Close the EMS patient-flow encounter first.
  update public.ems_encounters
  set
    current_status='CLOSED',
    transport_destination=destination_value,
    transport_completed_at=case
      when outcome_value='DELIVERED' then now()
      else transport_completed_at
    end,
    final_disposition=disposition_value,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    case
      when outcome_value='DELIVERED' then 'EMS_TRANSPORT_COMPLETED'
      else 'EMS_TRANSPORT_REFUSAL'
    end,
    jsonb_build_object(
      'encounter_id',e.id,
      'outcome',outcome_value,
      'disposition',disposition_value,
      'destination',destination_value,
      'incident_will_close',true
    ),
    auth.uid(),actor_kind_value
  );

  -- Closing the call after a completed/refused ambulance transport must release
  -- every resource still committed to the incident, not just the ambulance.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=p_incident_id
      and iu.cleared_at is null
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=unit_rec.unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=unit_rec.unit_id;

    if unit_rec.status is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),actor_kind_value,
        case when unit_rec.unit_id=p_unit_id then destination_value else null end,
        null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason',case
          when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED_CALL_CLOSED'
          else 'TRANSPORT_REFUSAL_CALL_CLOSED'
        end,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );

    released_count:=released_count+1;
  end loop;

  -- Close the CAD incident using the transport outcome as the incident
  -- disposition. This is done inside this security-definer workflow because a
  -- field ambulance may be the actor that finishes the transport.
  update public.incidents
  set
    status='CLOSED',
    closed_at=now(),
    disposition=disposition_value
  where id=p_incident_id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',disposition_value,
      'transport_outcome',outcome_value,
      'destination',destination_value,
      'released_units',released_count,
      'automatic',true,
      'reason','AMBULANCE_TRANSPORT_OUTCOME'
    ),
    auth.uid(),actor_kind_value
  );

  return outcome_value;
end;
$$;

revoke all on function public.ems_finish_ambulance_transport(uuid,uuid,text) from public;
grant execute on function public.ems_finish_ambulance_transport(uuid,uuid,text) to authenticated;


-- CommCenter Pro v0.8.2
-- Atomic incident creation with optional event POI creation.
--
-- Dispatcher "on the fly" POIs now originate inside the New Incident workflow.
-- If the dispatcher selected a raw map point and chooses "Add This Location as
-- a POI", the POI and incident are created in the same PostgreSQL transaction.
--
-- If incident creation fails, the new POI is rolled back too.

create or replace function public.create_incident_v4(
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
  p_poi_aliases text[] default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  poi_id_value uuid:=p_poi_id;
  incident_id_value uuid;
begin
  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatch access required';
  end if;

  -- A raw map point can be promoted to an event-only POI as part of the same
  -- action that creates the call. Existing POI selections are never duplicated.
  if coalesce(p_create_poi,false) and poi_id_value is null then
    if nullif(trim(coalesce(p_landmark,'')),'') is null then
      raise exception 'Location Description is required when adding the call location as a POI';
    end if;

    poi_id_value:=public.dispatcher_create_poi_v2(
      p_event_id,
      trim(p_landmark),
      coalesce(nullif(trim(coalesce(p_poi_category,'')),''),'Other'),
      p_map_layer_id,
      p_zone_id,
      p_latitude,
      p_longitude,
      p_map_x,
      p_map_y,
      null,
      coalesce(p_poi_aliases,array[]::text[])
    );
  end if;

  incident_id_value:=public.create_incident_v3(
    p_event_id,
    p_department_ids,
    p_call_type,
    p_priority,
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    p_landmark,
    p_notes,
    poi_id_value,
    p_map_layer_id,
    p_zone_id
  );

  return incident_id_value;
end;
$$;

revoke all on function public.create_incident_v4(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[]
) from public;

grant execute on function public.create_incident_v4(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[]
) to authenticated;


-- CommCenter Pro v0.8.3
-- Dispatcher + Treatment Area walk-in patient creation.
--
-- A walk-in is a normal CAD incident whose patient is already physically
-- present at a treatment area. The incident number remains the patient
-- reference and an EMS encounter is created immediately with IN_TREATMENT
-- custody at the selected area.

create or replace function public.create_treatment_walkin_incident_v2(
  p_treatment_area_id uuid,
  p_call_type text default 'Walk-In Medical',
  p_priority text default 'Standard',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  ta public.ems_treatment_areas;
  poi public.event_pois;
  incident_id_value uuid;
  encounter_id_value uuid;
  n integer;
  prefix text;
  incident_number_value text;
  actor_kind_value text;
begin
  select *
  into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and active=true;

  if ta.id is null then
    raise exception 'Treatment area not found';
  end if;

  if ta.status='CLOSED' then
    raise exception 'Treatment area is closed';
  end if;

  if public.can_dispatch_event(ta.event_id) then
    actor_kind_value:='staff';
  elsif private.current_treatment_area()=ta.id then
    actor_kind_value:='treatment';
  else
    raise exception 'Not authorized for this treatment area';
  end if;

  if ta.department_id is null then
    raise exception 'Treatment area must have a department configured';
  end if;

  if ta.poi_id is null then
    raise exception 'Treatment area must be linked to a POI before creating walk-in patients';
  end if;

  select *
  into poi
  from public.event_pois
  where id=ta.poi_id
    and event_id=ta.event_id
    and active=true;

  if poi.id is null then
    raise exception 'The treatment-area POI could not be found';
  end if;

  update public.events
  set next_incident_number=next_incident_number+1
  where id=ta.event_id
  returning next_incident_number-1,incident_prefix
  into n,prefix;

  incident_number_value:=prefix||'-'||lpad(n::text,3,'0');

  insert into public.incidents(
    event_id,
    incident_number,
    call_type,
    priority,
    status,
    poi_id,
    latitude,
    longitude,
    map_x,
    map_y,
    w3w,
    landmark,
    notes,
    created_by,
    map_layer_id,
    zone_id
  ) values(
    ta.event_id,
    incident_number_value,
    coalesce(nullif(trim(p_call_type),''),'Walk-In Medical'),
    coalesce(nullif(trim(p_priority),''),'Standard'),
    'OPEN',
    poi.id,
    poi.latitude,
    poi.longitude,
    poi.map_x,
    poi.map_y,
    null,
    ta.name,
    nullif(trim(p_notes),''),
    auth.uid(),
    poi.map_layer_id,
    poi.zone_id
  )
  returning id into incident_id_value;

  insert into public.incident_departments(incident_id,department_id)
  values(incident_id_value,ta.department_id)
  on conflict do nothing;

  encounter_id_value:=public.ems_create_encounter(
    ta.event_id,
    incident_id_value,
    null,
    ta.id,
    p_notes
  );

  insert into public.cad_activity(
    event_id,
    incident_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    ta.event_id,
    incident_id_value,
    'TREATMENT_WALKIN_INCIDENT_CREATED',
    jsonb_build_object(
      'incident_number',incident_number_value,
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'encounter_id',encounter_id_value,
      'source',case when actor_kind_value='staff' then 'dispatch' else 'treatment_area_station' end
    ),
    auth.uid(),
    actor_kind_value
  );

  return incident_id_value;
end;
$$;

revoke all on function public.create_treatment_walkin_incident_v2(uuid,text,text,text) from public;
grant execute on function public.create_treatment_walkin_incident_v2(uuid,text,text,text) to authenticated;

-- Preserve the existing Treatment Area Station RPC name and return type.
create or replace function public.treatment_create_walkin_incident(
  p_treatment_area_id uuid,
  p_call_type text default 'Walk-In Medical',
  p_priority text default 'Standard',
  p_notes text default null
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  incident_id_value uuid;
  incident_number_value text;
begin
  incident_id_value:=public.create_treatment_walkin_incident_v2(
    p_treatment_area_id,
    p_call_type,
    p_priority,
    p_notes
  );

  select incident_number
  into incident_number_value
  from public.incidents
  where id=incident_id_value;

  return incident_number_value;
end;
$$;

revoke all on function public.treatment_create_walkin_incident(uuid,text,text,text) from public;
grant execute on function public.treatment_create_walkin_incident(uuid,text,text,text) to authenticated;


-- CommCenter Pro v0.8.4
-- Detailed dispatch reporting.
--
-- Replaces the compact dispatch_log view with a much richer incident summary
-- and adds detailed event activity + unit status views for audit/reporting.
--
-- All views use security_invoker so existing RLS remains the tenant/security
-- boundary.

drop view if exists public.dispatch_log;

create view public.dispatch_log
with (security_invoker=true)
as
with department_summary as (
  select
    idept.incident_id,
    string_agg(distinct d.short_name,', ' order by d.short_name) as departments
  from public.incident_departments idept
  join public.event_departments d on d.id=idept.department_id
  group by idept.incident_id
),
unit_summary as (
  select
    iu.incident_id,
    string_agg(distinct u.name,', ' order by u.name) as units,
    min(iu.assigned_at) as first_unit_assigned,
    max(iu.cleared_at) as last_unit_assignment_cleared
  from public.incident_units iu
  join public.units u on u.id=iu.unit_id
  group by iu.incident_id
),
status_summary as (
  select
    sl.incident_id,
    min(sl.server_time) filter(where sl.new_status='ASSIGNED') as first_assigned_status,
    min(sl.server_time) filter(where sl.new_status='RESPONDING') as first_responding,
    min(sl.server_time) filter(where sl.new_status='EN_ROUTE') as first_enroute,
    min(sl.server_time) filter(where sl.new_status='ON_SCENE') as first_onscene,
    min(sl.server_time) filter(where sl.new_status='WORKING') as first_working,
    min(sl.server_time) filter(where sl.new_status='TRANSPORTING') as first_transporting,
    min(sl.server_time) filter(where sl.new_status='AT_HOSPITAL') as first_at_hospital,
    max(sl.server_time) filter(where sl.new_status in ('AVAILABLE','CLEAR','COMPLETE')) as last_clear,
    count(*) as unit_status_change_count,
    string_agg(
      to_char(sl.server_time,'YYYY-MM-DD HH24:MI:SS')
      || ' ' || coalesce(u.name,'Unit')
      || ': ' || coalesce(sl.old_status,'—')
      || ' -> ' || sl.new_status
      || case
           when sl.transport_destination_text is not null
             then ' (' || sl.transport_destination_text || ')'
           when ta.name is not null
             then ' (' || ta.name || ')'
           else ''
         end,
      ' | ' order by sl.server_time,sl.id
    ) as unit_status_history
  from public.unit_status_log sl
  left join public.units u on u.id=sl.unit_id
  left join public.ems_treatment_areas ta on ta.id=sl.transport_treatment_area_id
  where sl.incident_id is not null
  group by sl.incident_id
),
ems_summary as (
  select
    e.incident_id,
    min(e.created_at) as ems_started_at,
    max(e.transport_started_at) as transport_started_at,
    max(e.transport_completed_at) as transport_completed_at,
    max(e.transport_destination) filter(where e.transport_destination is not null) as transport_destination,
    max(e.final_disposition) filter(where e.final_disposition is not null) as ems_final_disposition,
    max(e.closed_at) as ems_closed_at,
    max(e.current_status) as latest_ems_status,
    max(e.tracking_number) as ems_tracking_number
  from public.ems_encounters e
  where e.incident_id is not null
  group by e.incident_id
),
treatment_history as (
  select
    x.incident_id,
    string_agg(distinct x.area_name,', ' order by x.area_name) as treatment_areas
  from (
    select e.incident_id,ta.name as area_name
    from public.ems_encounters e
    join public.ems_treatment_areas ta on ta.id=e.current_treatment_area_id
    where e.incident_id is not null

    union

    select e.incident_id,ta.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.ems_treatment_areas ta on ta.id=h.from_treatment_area_id
    where e.incident_id is not null

    union

    select e.incident_id,ta.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.ems_treatment_areas ta on ta.id=h.to_treatment_area_id
    where e.incident_id is not null
  ) x
  group by x.incident_id
),
ambulance_history as (
  select
    x.incident_id,
    string_agg(distinct x.unit_name,', ' order by x.unit_name) as ambulances
  from (
    select e.incident_id,u.name as unit_name
    from public.ems_encounters e
    join public.units u on u.id=e.current_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null

    union

    select e.incident_id,u.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.units u on u.id=h.from_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null

    union

    select e.incident_id,u.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.units u on u.id=h.to_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null
  ) x
  group by x.incident_id
),
activity_summary as (
  select
    a.incident_id,
    count(*) as activity_count,
    min(a.created_at) filter(where a.action='TREATMENT_WALKIN_INCIDENT_CREATED') as walkin_created_at,
    min(a.created_at) filter(where a.action in ('EMS_TREATMENT_RECEIVED','UNIT_ARRIVED_TREATMENT_AREA')) as first_treatment_arrival,
    max(a.created_at) as last_activity_at
  from public.cad_activity a
  where a.incident_id is not null
  group by a.incident_id
)
select
  i.event_id,
  i.id as incident_id,
  i.incident_number,
  i.status as incident_status,
  i.created_at as received_time,
  i.closed_at,
  case
    when i.closed_at is not null then extract(epoch from (i.closed_at-i.created_at))::bigint
    else extract(epoch from (now()-i.created_at))::bigint
  end as total_duration_seconds,

  coalesce(ds.departments,'') as departments,
  i.call_type,
  i.priority,

  p.name as poi_name,
  p.category as poi_category,
  i.landmark,
  ml.name as map_layer,
  z.name as zone,
  i.latitude,
  i.longitude,
  i.notes,

  coalesce(us.units,'') as units,
  us.first_unit_assigned,
  ss.first_assigned_status,
  ss.first_responding,
  ss.first_enroute,
  ss.first_onscene,
  ss.first_working,
  ss.first_transporting,
  ss.first_at_hospital,
  coalesce(ss.last_clear,us.last_unit_assignment_cleared) as last_clear,

  case
    when ss.first_enroute is not null
      then extract(epoch from (ss.first_enroute-i.created_at))::bigint
  end as dispatch_to_enroute_seconds,
  case
    when ss.first_onscene is not null
      then extract(epoch from (ss.first_onscene-i.created_at))::bigint
  end as received_to_onscene_seconds,
  case
    when ss.first_transporting is not null and ss.first_onscene is not null
      then extract(epoch from (ss.first_transporting-ss.first_onscene))::bigint
  end as onscene_to_transport_seconds,

  coalesce(ss.unit_status_change_count,0) as unit_status_change_count,
  ss.unit_status_history,

  es.ems_tracking_number,
  es.ems_started_at,
  es.latest_ems_status,
  th.treatment_areas,
  ah.ambulances,
  es.transport_destination,
  es.transport_started_at,
  es.transport_completed_at,
  es.ems_final_disposition,
  es.ems_closed_at,
  (asum.walkin_created_at is not null) as walk_in,
  asum.walkin_created_at,
  asum.first_treatment_arrival,

  i.disposition,
  coalesce(asum.activity_count,0) as activity_count,
  asum.last_activity_at,
  i.created_by
from public.incidents i
left join department_summary ds on ds.incident_id=i.id
left join unit_summary us on us.incident_id=i.id
left join status_summary ss on ss.incident_id=i.id
left join ems_summary es on es.incident_id=i.id
left join treatment_history th on th.incident_id=i.id
left join ambulance_history ah on ah.incident_id=i.id
left join activity_summary asum on asum.incident_id=i.id
left join public.event_pois p on p.id=i.poi_id
left join public.event_map_layers ml on ml.id=i.map_layer_id
left join public.event_zones z on z.id=i.zone_id;

create or replace view public.dispatch_activity_log
with (security_invoker=true)
as
select
  a.event_id,
  a.incident_id,
  i.incident_number,
  i.created_at as received_time,
  a.id as activity_id,
  a.created_at as activity_time,
  extract(epoch from (a.created_at-i.created_at))::bigint as elapsed_seconds,
  a.action,
  a.actor_kind,
  a.actor_user_id,
  a.unit_id,
  u.name as unit_name,
  d.short_name as unit_department,
  a.detail,
  a.detail->>'destination' as destination,
  a.detail->>'treatment_area_name' as treatment_area_name,
  a.detail->>'disposition' as activity_disposition,
  a.detail->>'reason' as reason,
  a.detail->>'from' as status_from,
  a.detail->>'to' as status_to
from public.cad_activity a
join public.incidents i on i.id=a.incident_id
left join public.units u on u.id=a.unit_id
left join public.event_departments d on d.id=u.department_id;

create or replace view public.dispatch_unit_status_log
with (security_invoker=true)
as
select
  sl.event_id,
  sl.incident_id,
  i.incident_number,
  sl.id as status_log_id,
  sl.server_time,
  sl.client_time,
  extract(epoch from (sl.server_time-i.created_at))::bigint as elapsed_seconds,
  sl.unit_id,
  u.name as unit_name,
  d.short_name as unit_department,
  sl.old_status,
  sl.new_status,
  sl.transport_destination_text,
  sl.transport_treatment_area_id,
  ta.name as transport_treatment_area,
  sl.actor_kind,
  sl.actor_user_id
from public.unit_status_log sl
join public.incidents i on i.id=sl.incident_id
join public.units u on u.id=sl.unit_id
left join public.event_departments d on d.id=u.department_id
left join public.ems_treatment_areas ta on ta.id=sl.transport_treatment_area_id
where sl.incident_id is not null;

grant select on public.dispatch_log to authenticated;
grant select on public.dispatch_activity_log to authenticated;
grant select on public.dispatch_unit_status_log to authenticated;
