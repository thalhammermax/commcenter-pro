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


-- CommCenter Pro v0.8.7
-- Explicit EMS-enabled departments + safe administrative removal workflow.
--
-- "Delete" in the operational UI is deliberately implemented as ARCHIVE for
-- events, departments, units, and treatment areas. Historical CAD/EMS records
-- remain intact and resources can be restored by an Event Admin.
--
-- Every destructive action is validated server-side and requires an exact
-- typed confirmation string from the UI.

-- ============================================================
-- EXPLICIT EMS DEPARTMENT FLAG
-- ============================================================

alter table public.event_departments
  add column if not exists ems_enabled boolean not null default false;

-- Deliberately DO NOT infer/backfill ems_enabled from old EMS resource rows.
-- v0.8.5 inferred EMS from treatment areas / unit configuration, which could
-- make the Walk-In button appear because of stale configuration. From v0.8.7
-- forward, EMS visibility is controlled only by this explicit department flag.

-- ============================================================
-- ACTIVE / ARCHIVED EVENT LISTS
-- ============================================================

create or replace function public.staff_events_for_org(p_organization_id uuid)
returns table(id uuid,name text,event_code text,active boolean,staff_role text)
language sql stable security definer set search_path=public
as $$
select e.id,e.name,e.event_code,e.active,
  case when om.role is not null then om.role else es.role end
from public.events e
left join public.organization_members om
  on om.organization_id=e.organization_id
 and om.user_id=auth.uid()
left join public.event_staff es
  on es.event_id=e.id
 and es.user_id=auth.uid()
where e.organization_id=p_organization_id
  and e.active=true
  and (om.user_id is not null or es.user_id is not null)
order by e.starts_at desc nulls last,e.name;
$$;

create or replace function public.staff_archived_events_for_org(p_organization_id uuid)
returns table(id uuid,name text,event_code text,active boolean,staff_role text)
language sql stable security definer set search_path=public
as $$
select e.id,e.name,e.event_code,e.active,
  case when om.role is not null then om.role else es.role end
from public.events e
left join public.organization_members om
  on om.organization_id=e.organization_id
 and om.user_id=auth.uid()
left join public.event_staff es
  on es.event_id=e.id
 and es.user_id=auth.uid()
where e.organization_id=p_organization_id
  and e.active=false
  and (
    om.role in ('owner','admin')
    or es.role='event_admin'
  )
order by e.starts_at desc nulls last,e.name;
$$;

-- ============================================================
-- UNIT ARCHIVE / RESTORE
-- ============================================================

create or replace function public.admin_archive_unit(
  p_unit_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  u public.units;
  dept_name text;
begin
  select * into u
  from public.units
  where id=p_unit_id;

  if u.id is null then
    raise exception 'Unit not found';
  end if;

  if not public.can_admin_event(u.event_id) then
    raise exception 'Event admin access required';
  end if;

  if trim(coalesce(p_confirmation,''))<>u.name then
    raise exception 'Confirmation text does not match the unit name';
  end if;

  if exists(
    select 1
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.unit_id=u.id
      and iu.cleared_at is null
      and i.status='OPEN'
  ) then
    raise exception 'Unit is still committed to an open incident. Clear it before removing the unit.';
  end if;

  if exists(
    select 1
    from public.ems_encounters e
    where e.current_unit_id=u.id
      and e.current_status<>'CLOSED'
  ) then
    raise exception 'Unit still has active EMS patient custody. Resolve the EMS patient flow before removing the unit.';
  end if;

  select d.name into dept_name
  from public.event_departments d
  where d.id=u.department_id;

  update public.field_sessions
  set active=false,
      ended_at=coalesce(ended_at,now())
  where unit_id=u.id
    and active=true;

  delete from public.unit_locations
  where unit_id=u.id;

  -- Keep any EMS role configuration intact for historical reporting.
  -- The unit itself is inactive, so it cannot be selected for live operations.
  update public.units
  set
    active=false,
    status='OUT_OF_SERVICE',
    current_transport_destination_text=null,
    current_transport_treatment_area_id=null
  where id=u.id;

  insert into public.cad_activity(
    event_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    u.event_id,u.id,'ADMIN_UNIT_ARCHIVED',
    jsonb_build_object(
      'unit_id',u.id,
      'unit_name',u.name,
      'department_id',u.department_id,
      'department_name',dept_name,
      'reversible',true
    ),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.admin_restore_unit(p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  u public.units;
  dept_active boolean;
begin
  select * into u
  from public.units
  where id=p_unit_id;

  if u.id is null then
    raise exception 'Unit not found';
  end if;

  if not public.can_admin_event(u.event_id) then
    raise exception 'Event admin access required';
  end if;

  select active into dept_active
  from public.event_departments
  where id=u.department_id;

  if not coalesce(dept_active,false) then
    raise exception 'Restore the unit department before restoring this unit';
  end if;

  update public.units
  set active=true,status='AVAILABLE'
  where id=u.id;

  insert into public.cad_activity(
    event_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    u.event_id,u.id,'ADMIN_UNIT_RESTORED',
    jsonb_build_object('unit_id',u.id,'unit_name',u.name),
    auth.uid(),'staff'
  );
end;
$$;

-- ============================================================
-- DEPARTMENT ARCHIVE / RESTORE
-- ============================================================

create or replace function public.admin_archive_department(
  p_department_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  d public.event_departments;
begin
  select * into d
  from public.event_departments
  where id=p_department_id;

  if d.id is null then
    raise exception 'Department not found';
  end if;

  if not public.can_admin_event(d.event_id) then
    raise exception 'Event admin access required';
  end if;

  if trim(coalesce(p_confirmation,''))<>d.name then
    raise exception 'Confirmation text does not match the department name';
  end if;

  if exists(
    select 1
    from public.units u
    where u.department_id=d.id
      and u.active=true
  ) then
    raise exception 'Department still has active units. Remove or move those units first.';
  end if;

  if exists(
    select 1
    from public.ems_treatment_areas ta
    where ta.department_id=d.id
      and ta.active=true
  ) then
    raise exception 'Department still has an active EMS treatment area. Remove that treatment area first.';
  end if;

  if exists(
    select 1
    from public.incident_departments idept
    join public.incidents i on i.id=idept.incident_id
    where idept.department_id=d.id
      and i.status='OPEN'
  ) then
    raise exception 'Department is attached to an open incident. Close or reassign that incident first.';
  end if;

  update public.event_departments
  set active=false,
      ems_enabled=false
  where id=d.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    d.event_id,'ADMIN_DEPARTMENT_ARCHIVED',
    jsonb_build_object(
      'department_id',d.id,
      'department_name',d.name,
      'short_name',d.short_name,
      'reversible',true
    ),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.admin_restore_department(p_department_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  d public.event_departments;
begin
  select * into d
  from public.event_departments
  where id=p_department_id;

  if d.id is null then
    raise exception 'Department not found';
  end if;

  if not public.can_admin_event(d.event_id) then
    raise exception 'Event admin access required';
  end if;

  update public.event_departments
  set active=true
  where id=d.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    d.event_id,'ADMIN_DEPARTMENT_RESTORED',
    jsonb_build_object(
      'department_id',d.id,
      'department_name',d.name
    ),
    auth.uid(),'staff'
  );
end;
$$;

-- ============================================================
-- EVENT ARCHIVE / RESTORE
-- ============================================================

create or replace function public.admin_archive_event(
  p_event_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
begin
  select * into e
  from public.events
  where id=p_event_id;

  if e.id is null then
    raise exception 'Event not found';
  end if;

  if not public.can_admin_event(e.id) then
    raise exception 'Event admin access required';
  end if;

  if trim(coalesce(p_confirmation,''))<>e.event_code then
    raise exception 'Confirmation text does not match the Event ID';
  end if;

  if exists(
    select 1
    from public.incidents i
    where i.event_id=e.id
      and i.status='OPEN'
  ) then
    raise exception 'Event still has open incidents. Close all incidents before archiving the event.';
  end if;

  if exists(
    select 1
    from public.ems_encounters ee
    where ee.event_id=e.id
      and ee.current_status<>'CLOSED'
  ) then
    raise exception 'Event still has active EMS patient flow. Resolve all EMS encounters before archiving the event.';
  end if;

  update public.field_sessions
  set active=false,
      ended_at=coalesce(ended_at,now())
  where event_id=e.id
    and active=true;

  update public.treatment_area_sessions
  set active=false,
      ended_at=coalesce(ended_at,now())
  where event_id=e.id
    and active=true;

  delete from public.unit_locations
  where event_id=e.id;

  update public.events
  set
    active=false,
    field_access_enabled=false,
    field_location_enabled=false
  where id=e.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.id,'ADMIN_EVENT_ARCHIVED',
    jsonb_build_object(
      'event_id',e.id,
      'event_name',e.name,
      'event_code',e.event_code,
      'reversible',true
    ),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.admin_restore_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
begin
  select * into e
  from public.events
  where id=p_event_id;

  if e.id is null then
    raise exception 'Event not found';
  end if;

  if not public.can_admin_event(e.id) then
    raise exception 'Event admin access required';
  end if;

  update public.events
  set active=true
  where id=e.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.id,'ADMIN_EVENT_RESTORED',
    jsonb_build_object(
      'event_id',e.id,
      'event_name',e.name,
      'event_code',e.event_code
    ),
    auth.uid(),'staff'
  );
end;
$$;

-- ============================================================
-- TREATMENT AREA ARCHIVE / RESTORE
-- ============================================================

create or replace function public.admin_archive_treatment_area(
  p_treatment_area_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  ta public.ems_treatment_areas;
begin
  select * into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id;

  if ta.id is null then
    raise exception 'Treatment area not found';
  end if;

  if not public.can_admin_event(ta.event_id) then
    raise exception 'Event admin access required';
  end if;

  if trim(coalesce(p_confirmation,''))<>ta.name then
    raise exception 'Confirmation text does not match the treatment-area name';
  end if;

  if exists(
    select 1
    from public.ems_encounters e
    where e.current_treatment_area_id=ta.id
      and e.current_status<>'CLOSED'
  ) then
    raise exception 'Treatment area still has active patient custody. Resolve those patients before removing it.';
  end if;

  update public.treatment_area_sessions
  set active=false,
      ended_at=coalesce(ended_at,now())
  where treatment_area_id=ta.id
    and active=true;

  update public.ems_treatment_areas
  set active=false,
      accepting_patients=false,
      status='CLOSED'
  where id=ta.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    ta.event_id,'ADMIN_TREATMENT_AREA_ARCHIVED',
    jsonb_build_object(
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'reversible',true
    ),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.admin_restore_treatment_area(p_treatment_area_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  ta public.ems_treatment_areas;
begin
  select * into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id;

  if ta.id is null then
    raise exception 'Treatment area not found';
  end if;

  if not public.can_admin_event(ta.event_id) then
    raise exception 'Event admin access required';
  end if;

  if ta.department_id is not null and not exists(
    select 1
    from public.event_departments d
    where d.id=ta.department_id
      and d.active=true
  ) then
    raise exception 'Restore the linked department before restoring this treatment area';
  end if;

  update public.ems_treatment_areas
  set active=true,
      accepting_patients=true,
      status='OPEN'
  where id=ta.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    ta.event_id,'ADMIN_TREATMENT_AREA_RESTORED',
    jsonb_build_object(
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name
    ),
    auth.uid(),'staff'
  );
end;
$$;

-- ============================================================
-- GRANTS
-- ============================================================

revoke all on function public.staff_archived_events_for_org(uuid) from public;
revoke all on function public.admin_archive_unit(uuid,text) from public;
revoke all on function public.admin_restore_unit(uuid) from public;
revoke all on function public.admin_archive_department(uuid,text) from public;
revoke all on function public.admin_restore_department(uuid) from public;
revoke all on function public.admin_archive_event(uuid,text) from public;
revoke all on function public.admin_restore_event(uuid) from public;
revoke all on function public.admin_archive_treatment_area(uuid,text) from public;
revoke all on function public.admin_restore_treatment_area(uuid) from public;

grant execute on function public.staff_archived_events_for_org(uuid) to authenticated;
grant execute on function public.admin_archive_unit(uuid,text) to authenticated;
grant execute on function public.admin_restore_unit(uuid) to authenticated;
grant execute on function public.admin_archive_department(uuid,text) to authenticated;
grant execute on function public.admin_restore_department(uuid) to authenticated;
grant execute on function public.admin_archive_event(uuid,text) to authenticated;
grant execute on function public.admin_restore_event(uuid) to authenticated;
grant execute on function public.admin_archive_treatment_area(uuid,text) to authenticated;
grant execute on function public.admin_restore_treatment_area(uuid) to authenticated;


-- CommCenter Pro v0.9.0
-- Multi-day events / ICS Operational Periods.
--
-- One CommCenter event can span many Operational Periods. Each Operational
-- Period owns its own configurable incident prefix and sequence counter.
--
-- Example:
--   Event: Wisconsin State Fair 2026
--   Operational Period: Sunday August 9
--   Prefix: SF20260809
--   Incidents: SF20260809-001, SF20260809-002, ...
--
-- Only one Operational Period may be ACTIVE for an event. Existing calls may
-- remain open across a period change; the period is fixed at incident creation.

-- ============================================================
-- OPERATIONAL PERIODS
-- ============================================================

create table if not exists public.operational_periods (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  incident_prefix text not null,
  next_incident_number integer not null default 1 check(next_incident_number >= 1),
  status text not null default 'PLANNED'
    check(status in ('PLANNED','ACTIVE','COMPLETE','CANCELLED')),
  starts_at timestamptz,
  ends_at timestamptz,
  activated_at timestamptz,
  completed_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(ends_at is null or starts_at is null or ends_at > starts_at)
);

create unique index if not exists operational_periods_live_name_idx
  on public.operational_periods(event_id,name)
  where status<>'CANCELLED';

create unique index if not exists operational_periods_live_prefix_idx
  on public.operational_periods(event_id,incident_prefix)
  where status<>'CANCELLED';

create unique index if not exists operational_periods_one_active_per_event_idx
  on public.operational_periods(event_id)
  where status='ACTIVE';

create index if not exists operational_periods_event_status_idx
  on public.operational_periods(event_id,status,starts_at);

alter table public.incidents
  add column if not exists operational_period_id uuid
  references public.operational_periods(id) on delete restrict;

create index if not exists incidents_operational_period_idx
  on public.incidents(operational_period_id,created_at);

-- ============================================================
-- RLS
-- ============================================================

alter table public.operational_periods enable row level security;

drop policy if exists operational_periods_select_access on public.operational_periods;
create policy operational_periods_select_access
on public.operational_periods
for select
to authenticated
using (
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
);

drop policy if exists operational_periods_admin_insert on public.operational_periods;
create policy operational_periods_admin_insert
on public.operational_periods
for insert
to authenticated
with check (public.can_admin_event(event_id));

drop policy if exists operational_periods_admin_update on public.operational_periods;
create policy operational_periods_admin_update
on public.operational_periods
for update
to authenticated
using (public.can_admin_event(event_id))
with check (public.can_admin_event(event_id));

drop policy if exists operational_periods_admin_delete on public.operational_periods;
create policy operational_periods_admin_delete
on public.operational_periods
for delete
to authenticated
using (public.can_admin_event(event_id));

grant select,insert,update,delete on public.operational_periods to authenticated;

-- ============================================================
-- BACKFILL EXISTING EVENTS
-- ============================================================
-- Existing events become a single Operational Period using their current
-- incident prefix and counter. No incident numbers change.

insert into public.operational_periods(
  event_id,
  name,
  incident_prefix,
  next_incident_number,
  status,
  starts_at,
  ends_at,
  activated_at,
  completed_at,
  created_at
)
select
  e.id,
  'Operational Period 1',
  e.incident_prefix,
  greatest(e.next_incident_number,1),
  case when e.active then 'ACTIVE' else 'COMPLETE' end,
  e.starts_at,
  e.ends_at,
  case when e.active then coalesce(e.starts_at,e.created_at) else null end,
  case when e.active then null else coalesce(e.ends_at,now()) end,
  e.created_at
from public.events e
where not exists(
  select 1
  from public.operational_periods op
  where op.event_id=e.id
);

update public.incidents i
set operational_period_id=op.id
from public.operational_periods op
where i.operational_period_id is null
  and op.event_id=i.event_id
  and op.name='Operational Period 1';

-- ============================================================
-- NUMBER GENERATOR
-- ============================================================

create or replace function private.next_incident_number_for_event(p_event_id uuid)
returns table(
  operational_period_id uuid,
  operational_period_name text,
  incident_prefix text,
  sequence_number integer,
  incident_number text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  op public.operational_periods;
  n integer;
begin
  select *
  into op
  from public.operational_periods
  where event_id=p_event_id
    and status='ACTIVE'
  for update;

  if op.id is null then
    raise exception 'No active Operational Period. Activate an Operational Period before creating a new incident.';
  end if;

  n:=op.next_incident_number;

  update public.operational_periods
  set next_incident_number=n+1
  where id=op.id;

  -- Keep the legacy event fields synchronized for older integrations / screens.
  update public.events
  set
    incident_prefix=op.incident_prefix,
    next_incident_number=n+1
  where id=p_event_id;

  return query
  select
    op.id,
    op.name,
    op.incident_prefix,
    n,
    op.incident_prefix||'-'||lpad(n::text,3,'0');
end;
$$;

revoke all on function private.next_incident_number_for_event(uuid) from public;

-- ============================================================
-- INCIDENT CREATION
-- ============================================================

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
language plpgsql
security definer
set search_path=public
as $$
declare
  number_info record;
  iid uuid;
  d uuid;
begin
  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatch access required';
  end if;

  if array_length(p_department_ids,1) is null then
    raise exception 'At least one department is required';
  end if;

  if p_map_layer_id is not null and not exists(
    select 1
    from public.event_map_layers
    where id=p_map_layer_id
      and event_id=p_event_id
      and active=true
  ) then
    raise exception 'Map layer is not part of this event';
  end if;

  if p_zone_id is not null and not exists(
    select 1
    from public.event_zones
    where id=p_zone_id
      and event_id=p_event_id
      and active=true
  ) then
    raise exception 'Zone is not part of this event';
  end if;

  select *
  into number_info
  from private.next_incident_number_for_event(p_event_id);

  insert into public.incidents(
    event_id,
    operational_period_id,
    incident_number,
    call_type,
    priority,
    poi_id,
    map_layer_id,
    zone_id,
    latitude,
    longitude,
    map_x,
    map_y,
    w3w,
    landmark,
    notes,
    created_by
  ) values(
    p_event_id,
    number_info.operational_period_id,
    number_info.incident_number,
    p_call_type,
    p_priority,
    p_poi_id,
    p_map_layer_id,
    p_zone_id,
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    p_w3w,
    p_landmark,
    p_notes,
    auth.uid()
  )
  returning id into iid;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    select iid,d
    where exists(
      select 1
      from public.event_departments
      where id=d
        and event_id=p_event_id
        and active=true
    );
  end loop;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    iid,
    'INCIDENT_CREATED',
    jsonb_build_object(
      'incident_number',number_info.incident_number,
      'call_type',p_call_type,
      'map_layer_id',p_map_layer_id,
      'zone_id',p_zone_id,
      'operational_period_id',number_info.operational_period_id,
      'operational_period_name',number_info.operational_period_name,
      'incident_prefix',number_info.incident_prefix,
      'sequence_number',number_info.sequence_number
    ),
    auth.uid(),
    'staff'
  );

  return iid;
end;
$$;

-- Preserve the original create_incident RPC as an Operational-Period-aware
-- compatibility wrapper for any older cached client.
create or replace function public.create_incident(
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
  p_poi_id uuid default null
)
returns uuid
language sql
security definer
set search_path=public
as $$
  select public.create_incident_v2(
    p_event_id,
    p_department_ids,
    p_call_type,
    p_priority,
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    p_w3w,
    p_landmark,
    p_notes,
    p_poi_id,
    null,
    null
  );
$$;

-- create_incident_v3 and create_incident_v4 already flow through v2, so they
-- automatically receive Operational Period numbering without signature changes.

-- ============================================================
-- TREATMENT AREA WALK-INS
-- ============================================================

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
  number_info record;
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

  select *
  into number_info
  from private.next_incident_number_for_event(ta.event_id);

  insert into public.incidents(
    event_id,
    operational_period_id,
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
    number_info.operational_period_id,
    number_info.incident_number,
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
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    ta.event_id,
    incident_id_value,
    'TREATMENT_WALKIN_INCIDENT_CREATED',
    jsonb_build_object(
      'incident_number',number_info.incident_number,
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'encounter_id',encounter_id_value,
      'source',case
        when actor_kind_value='staff' then 'dispatch'
        else 'treatment_area_station'
      end,
      'operational_period_id',number_info.operational_period_id,
      'operational_period_name',number_info.operational_period_name,
      'incident_prefix',number_info.incident_prefix,
      'sequence_number',number_info.sequence_number
    ),
    auth.uid(),
    actor_kind_value
  );

  return incident_id_value;
end;
$$;

-- ============================================================
-- EVENT CREATION
-- ============================================================

create or replace function public.create_event_v2(
  p_organization_id uuid,
  p_name text,
  p_event_code text,
  p_pin text,
  p_operational_period_name text,
  p_incident_prefix text
)
returns uuid
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  eid uuid;
  slug text;
  period_name_value text;
  prefix_value text;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'Organization admin access required';
  end if;

  if trim(p_name)='' then
    raise exception 'Event name is required';
  end if;

  if trim(p_event_code)='' then
    raise exception 'Event ID is required';
  end if;

  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'Field PIN must be exactly 4 digits';
  end if;

  period_name_value:=coalesce(
    nullif(trim(p_operational_period_name),''),
    'Operational Period 1'
  );
  prefix_value:=upper(trim(coalesce(p_incident_prefix,'')));

  if prefix_value='' then
    raise exception 'Operational Period incident prefix is required';
  end if;

  if prefix_value ~ '\s' then
    raise exception 'Incident prefix cannot contain spaces';
  end if;

  slug:=trim(both '-' from regexp_replace(lower(trim(p_name)),'[^a-z0-9]+','-','g'));

  insert into public.events(
    organization_id,
    name,
    slug,
    event_code,
    field_pin_hash,
    field_access_enabled,
    incident_prefix,
    next_incident_number
  ) values(
    p_organization_id,
    trim(p_name),
    slug,
    upper(trim(p_event_code)),
    crypt(p_pin,gen_salt('bf')),
    true,
    prefix_value,
    1
  )
  returning id into eid;

  insert into public.operational_periods(
    event_id,
    name,
    incident_prefix,
    next_incident_number,
    status,
    activated_at,
    created_by
  ) values(
    eid,
    period_name_value,
    prefix_value,
    1,
    'ACTIVE',
    now(),
    auth.uid()
  );

  return eid;
end;
$$;

-- Preserve the old RPC signature for older clients.
create or replace function public.create_event(
  p_organization_id uuid,
  p_name text,
  p_event_code text,
  p_pin text,
  p_incident_prefix text
)
returns uuid
language sql
security definer
set search_path=public
as $$
  select public.create_event_v2(
    p_organization_id,
    p_name,
    p_event_code,
    p_pin,
    'Operational Period 1',
    p_incident_prefix
  );
$$;

-- ============================================================
-- OPERATIONAL PERIOD ADMIN
-- ============================================================

create or replace function public.admin_create_operational_period(
  p_event_id uuid,
  p_name text,
  p_incident_prefix text,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  op_id uuid;
  name_value text;
  prefix_value text;
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  name_value:=trim(coalesce(p_name,''));
  prefix_value:=upper(trim(coalesce(p_incident_prefix,'')));

  if name_value='' then
    raise exception 'Operational Period name is required';
  end if;

  if prefix_value='' then
    raise exception 'Incident prefix is required';
  end if;

  if prefix_value ~ '\s' then
    raise exception 'Incident prefix cannot contain spaces';
  end if;

  if p_starts_at is not null
     and p_ends_at is not null
     and p_ends_at<=p_starts_at then
    raise exception 'Operational Period end must be after its start';
  end if;

  insert into public.operational_periods(
    event_id,
    name,
    incident_prefix,
    status,
    starts_at,
    ends_at,
    created_by
  ) values(
    p_event_id,
    name_value,
    prefix_value,
    'PLANNED',
    p_starts_at,
    p_ends_at,
    auth.uid()
  )
  returning id into op_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    'OPERATIONAL_PERIOD_CREATED',
    jsonb_build_object(
      'operational_period_id',op_id,
      'operational_period_name',name_value,
      'incident_prefix',prefix_value,
      'status','PLANNED'
    ),
    auth.uid(),
    'staff'
  );

  return op_id;
end;
$$;

create or replace function public.admin_update_operational_period(
  p_operational_period_id uuid,
  p_name text,
  p_incident_prefix text,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  op public.operational_periods;
  name_value text;
  prefix_value text;
begin
  select *
  into op
  from public.operational_periods
  where id=p_operational_period_id;

  if op.id is null then
    raise exception 'Operational Period not found';
  end if;

  if not public.can_admin_event(op.event_id) then
    raise exception 'Event admin access required';
  end if;

  if op.status<>'PLANNED' then
    raise exception 'Only a PLANNED Operational Period can be edited';
  end if;

  name_value:=trim(coalesce(p_name,''));
  prefix_value:=upper(trim(coalesce(p_incident_prefix,'')));

  if name_value='' then
    raise exception 'Operational Period name is required';
  end if;

  if prefix_value='' then
    raise exception 'Incident prefix is required';
  end if;

  if prefix_value ~ '\s' then
    raise exception 'Incident prefix cannot contain spaces';
  end if;

  if p_starts_at is not null
     and p_ends_at is not null
     and p_ends_at<=p_starts_at then
    raise exception 'Operational Period end must be after its start';
  end if;

  update public.operational_periods
  set
    name=name_value,
    incident_prefix=prefix_value,
    starts_at=p_starts_at,
    ends_at=p_ends_at
  where id=op.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    op.event_id,
    'OPERATIONAL_PERIOD_UPDATED',
    jsonb_build_object(
      'operational_period_id',op.id,
      'operational_period_name',name_value,
      'incident_prefix',prefix_value
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

create or replace function public.admin_activate_operational_period(
  p_operational_period_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  op public.operational_periods;
  previous_op public.operational_periods;
begin
  select *
  into op
  from public.operational_periods
  where id=p_operational_period_id
  for update;

  if op.id is null then
    raise exception 'Operational Period not found';
  end if;

  if not public.can_admin_event(op.event_id) then
    raise exception 'Event admin access required';
  end if;

  if op.status<>'PLANNED' then
    raise exception 'Only a PLANNED Operational Period can be activated';
  end if;

  if trim(coalesce(p_confirmation,''))<>op.incident_prefix then
    raise exception 'Confirmation text does not match the new incident prefix';
  end if;

  select *
  into previous_op
  from public.operational_periods
  where event_id=op.event_id
    and status='ACTIVE'
  for update;

  if previous_op.id is not null then
    update public.operational_periods
    set
      status='COMPLETE',
      completed_at=now()
    where id=previous_op.id;
  end if;

  update public.operational_periods
  set
    status='ACTIVE',
    activated_at=now(),
    completed_at=null
  where id=op.id;

  update public.events
  set
    incident_prefix=op.incident_prefix,
    next_incident_number=op.next_incident_number
  where id=op.event_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    op.event_id,
    'OPERATIONAL_PERIOD_ACTIVATED',
    jsonb_build_object(
      'operational_period_id',op.id,
      'operational_period_name',op.name,
      'incident_prefix',op.incident_prefix,
      'next_incident_number',op.next_incident_number,
      'previous_operational_period_id',previous_op.id,
      'previous_operational_period_name',previous_op.name,
      'open_incidents_continue',true
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

create or replace function public.admin_complete_operational_period(
  p_operational_period_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  op public.operational_periods;
begin
  select *
  into op
  from public.operational_periods
  where id=p_operational_period_id
  for update;

  if op.id is null then
    raise exception 'Operational Period not found';
  end if;

  if not public.can_admin_event(op.event_id) then
    raise exception 'Event admin access required';
  end if;

  if op.status<>'ACTIVE' then
    raise exception 'Only the ACTIVE Operational Period can be completed';
  end if;

  if trim(coalesce(p_confirmation,''))<>op.incident_prefix then
    raise exception 'Confirmation text does not match the incident prefix';
  end if;

  update public.operational_periods
  set
    status='COMPLETE',
    completed_at=now()
  where id=op.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    op.event_id,
    'OPERATIONAL_PERIOD_COMPLETED',
    jsonb_build_object(
      'operational_period_id',op.id,
      'operational_period_name',op.name,
      'incident_prefix',op.incident_prefix,
      'open_incidents_continue',true
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

create or replace function public.admin_cancel_operational_period(
  p_operational_period_id uuid,
  p_confirmation text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  op public.operational_periods;
begin
  select *
  into op
  from public.operational_periods
  where id=p_operational_period_id
  for update;

  if op.id is null then
    raise exception 'Operational Period not found';
  end if;

  if not public.can_admin_event(op.event_id) then
    raise exception 'Event admin access required';
  end if;

  if op.status<>'PLANNED' then
    raise exception 'Only a PLANNED Operational Period can be removed';
  end if;

  if trim(coalesce(p_confirmation,''))<>op.name then
    raise exception 'Confirmation text does not match the Operational Period name';
  end if;

  if exists(
    select 1
    from public.incidents i
    where i.operational_period_id=op.id
  ) then
    raise exception 'Operational Period already contains incidents and cannot be removed';
  end if;

  update public.operational_periods
  set
    status='CANCELLED',
    completed_at=now()
  where id=op.id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    op.event_id,
    'OPERATIONAL_PERIOD_CANCELLED',
    jsonb_build_object(
      'operational_period_id',op.id,
      'operational_period_name',op.name,
      'incident_prefix',op.incident_prefix
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

-- ============================================================
-- GRANTS
-- ============================================================

revoke all on function public.create_event_v2(uuid,text,text,text,text,text) from public;
revoke all on function public.admin_create_operational_period(uuid,text,text,timestamptz,timestamptz) from public;
revoke all on function public.admin_update_operational_period(uuid,text,text,timestamptz,timestamptz) from public;
revoke all on function public.admin_activate_operational_period(uuid,text) from public;
revoke all on function public.admin_complete_operational_period(uuid,text) from public;
revoke all on function public.admin_cancel_operational_period(uuid,text) from public;

grant execute on function public.create_event_v2(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.admin_create_operational_period(uuid,text,text,timestamptz,timestamptz) to authenticated;
grant execute on function public.admin_update_operational_period(uuid,text,text,timestamptz,timestamptz) to authenticated;
grant execute on function public.admin_activate_operational_period(uuid,text) to authenticated;
grant execute on function public.admin_complete_operational_period(uuid,text) to authenticated;
grant execute on function public.admin_cancel_operational_period(uuid,text) to authenticated;


-- CommCenter Pro v0.9.1
-- Optional dispatch mapping / mapless incidents.
--
-- Events may operate as a board-only CAD without requiring a map point.
-- Existing mapped incidents are unchanged.

alter table public.incidents
  alter column latitude drop not null,
  alter column longitude drop not null;

-- No incident-creation RPC signature change is required. Existing v0.9.0
-- creation functions accept nullable double precision parameters and now may
-- store NULL coordinates when the dispatcher uses a text-only location.


-- CommCenter Pro v0.9.3
-- Field Report Time Reference.
--
-- Field users with an active event session may retrieve CAD times for units in
-- that event without claiming the unit. This supports a report-only QR workflow
-- at EMS treatment areas without interfering with an operational field-device
-- session already controlling the unit.
--
-- The RPC is intentionally read-only and returns operational timestamps only.
-- It does not expose EMS narrative, vitals, medications, procedures, signatures,
-- or other clinical documentation.

create or replace function public.field_report_call_times(
  p_unit_id uuid,
  p_limit integer default 20
)
returns table(
  event_id uuid,
  unit_id uuid,
  unit_name text,
  incident_id uuid,
  incident_number text,
  operational_period_id uuid,
  operational_period_name text,
  call_type text,
  priority text,
  landmark text,
  incident_status text,
  disposition text,
  received_at timestamptz,
  assigned_at timestamptz,
  first_responding_at timestamptz,
  first_enroute_at timestamptz,
  first_onscene_at timestamptz,
  first_working_at timestamptz,
  first_transporting_at timestamptz,
  first_at_hospital_at timestamptz,
  treatment_handoff_at timestamptz,
  treatment_area_name text,
  transport_destination text,
  cleared_at timestamptz,
  incident_closed_at timestamptz,
  status_timeline jsonb
)
language plpgsql
security definer
set search_path=public
as $$
declare
  unit_event_id uuid;
  unit_name_value text;
  limit_value integer;
begin
  select u.event_id,u.name
  into unit_event_id,unit_name_value
  from public.units u
  where u.id=p_unit_id;

  if unit_event_id is null then
    raise exception 'Unit not found';
  end if;

  if not (
    public.field_has_event_access(unit_event_id)
    or public.has_event_staff_access(unit_event_id)
  ) then
    raise exception 'Active field event access is required';
  end if;

  limit_value:=greatest(1,least(coalesce(p_limit,20),100));

  return query
  with assigned_calls as (
    select
      iu.incident_id,
      min(iu.assigned_at) as assigned_at,
      max(iu.cleared_at) as cleared_at
    from public.incident_units iu
    where iu.unit_id=p_unit_id
    group by iu.incident_id
  ),
  status_summary as (
    select
      sl.incident_id,
      min(sl.server_time) filter(where sl.new_status='RESPONDING') as first_responding_at,
      min(sl.server_time) filter(where sl.new_status='EN_ROUTE') as first_enroute_at,
      min(sl.server_time) filter(where sl.new_status='ON_SCENE') as first_onscene_at,
      min(sl.server_time) filter(where sl.new_status='WORKING') as first_working_at,
      min(sl.server_time) filter(where sl.new_status='TRANSPORTING') as first_transporting_at,
      min(sl.server_time) filter(where sl.new_status='AT_HOSPITAL') as first_at_hospital_at,
      (
        array_agg(
          nullif(trim(sl.transport_destination_text),'')
          order by sl.server_time desc,sl.id desc
        ) filter(
          where nullif(trim(sl.transport_destination_text),'') is not null
        )
      )[1] as transport_destination,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'time',sl.server_time,
            'client_time',sl.client_time,
            'from',sl.old_status,
            'to',sl.new_status,
            'destination',sl.transport_destination_text,
            'treatment_area_id',sl.transport_treatment_area_id
          )
          order by sl.server_time,sl.id
        ),
        '[]'::jsonb
      ) as status_timeline
    from public.unit_status_log sl
    where sl.unit_id=p_unit_id
      and sl.incident_id is not null
    group by sl.incident_id
  ),
  treatment_transfer as (
    select
      x.incident_id,
      min(x.handoff_time) as treatment_handoff_at,
      (array_agg(x.treatment_area_name order by x.handoff_time))[1] as treatment_area_name
    from (
      select
        e.incident_id,
        h.completed_at as handoff_time,
        ta.name as treatment_area_name
      from public.ems_handoffs h
      join public.ems_encounters e on e.id=h.encounter_id
      join public.ems_treatment_areas ta on ta.id=h.to_treatment_area_id
      where h.from_unit_id=p_unit_id
        and h.to_treatment_area_id is not null
        and h.status='COMPLETED'
        and h.completed_at is not null

      union all

      select
        a.incident_id,
        a.created_at,
        nullif(a.detail->>'treatment_area_name','')
      from public.cad_activity a
      where a.unit_id=p_unit_id
        and a.action='UNIT_ARRIVED_TREATMENT_AREA'
        and a.incident_id is not null
    ) x
    group by x.incident_id
  )
  select
    i.event_id,
    p_unit_id,
    unit_name_value,
    i.id,
    i.incident_number,
    i.operational_period_id,
    op.name,
    i.call_type,
    i.priority,
    i.landmark,
    i.status,
    i.disposition,
    i.created_at,
    ac.assigned_at,
    ss.first_responding_at,
    ss.first_enroute_at,
    ss.first_onscene_at,
    ss.first_working_at,
    ss.first_transporting_at,
    ss.first_at_hospital_at,
    tt.treatment_handoff_at,
    tt.treatment_area_name,
    ss.transport_destination,
    ac.cleared_at,
    i.closed_at,
    coalesce(ss.status_timeline,'[]'::jsonb)
  from assigned_calls ac
  join public.incidents i on i.id=ac.incident_id
  left join public.operational_periods op on op.id=i.operational_period_id
  left join status_summary ss on ss.incident_id=i.id
  left join treatment_transfer tt on tt.incident_id=i.id
  where i.event_id=unit_event_id
  order by ac.assigned_at desc
  limit limit_value;
end;
$$;

revoke all on function public.field_report_call_times(uuid,integer) from public;
grant execute on function public.field_report_call_times(uuid,integer) to authenticated;


-- CommCenter Pro v0.9.4
-- 24-hour time display is a frontend concern; this migration adds standardized
-- event disposition catalogs and structured CAD / EMS close workflows.

-- ============================================================
-- DISPOSITION CATALOG
-- ============================================================

create table if not exists public.event_dispositions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  scope text not null check(scope in ('GENERAL','EMS')),
  code text not null,
  label text not null,
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  unique(event_id,scope,code)
);

create index if not exists event_dispositions_event_scope_idx
  on public.event_dispositions(event_id,scope,active,sort_order,label);

alter table public.event_dispositions enable row level security;

drop policy if exists event_dispositions_read on public.event_dispositions;
create policy event_dispositions_read
on public.event_dispositions
for select
to authenticated
using (
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.treatment_has_event_access(event_id)
);

drop policy if exists event_dispositions_admin_insert on public.event_dispositions;
create policy event_dispositions_admin_insert
on public.event_dispositions
for insert
to authenticated
with check(public.can_admin_event(event_id));

drop policy if exists event_dispositions_admin_update on public.event_dispositions;
create policy event_dispositions_admin_update
on public.event_dispositions
for update
to authenticated
using(public.can_admin_event(event_id))
with check(public.can_admin_event(event_id));

drop policy if exists event_dispositions_admin_delete on public.event_dispositions;
create policy event_dispositions_admin_delete
on public.event_dispositions
for delete
to authenticated
using(public.can_admin_event(event_id));

grant select,insert,update,delete on public.event_dispositions to authenticated;

-- ============================================================
-- DEFAULT DISPOSITIONS
-- ============================================================

create or replace function public.seed_default_event_dispositions(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.event_dispositions(event_id,scope,code,label,sort_order)
  values
    (p_event_id,'GENERAL','COMPLETED','Completed / Resolved',10),
    (p_event_id,'GENERAL','CANCELLED','Cancelled',20),
    (p_event_id,'GENERAL','NO_ACTION_REQUIRED','No Action Required',30),
    (p_event_id,'GENERAL','UNFOUNDED','Unfounded / No Incident Found',40),
    (p_event_id,'GENERAL','REFERRED','Referred / Turned Over',50),
    (p_event_id,'GENERAL','DUPLICATE','Duplicate Call',60),
    (p_event_id,'GENERAL','STANDBY_COMPLETE','Standby Complete',70),
    (p_event_id,'GENERAL','OTHER','Other',90),

    (p_event_id,'EMS','TREATED_RELEASED','Treated / Released',10),
    (p_event_id,'EMS','REFUSAL','Patient Refusal',20),
    (p_event_id,'EMS','NO_PATIENT','No Patient Found',30),
    (p_event_id,'EMS','NO_TREATMENT_REQUIRED','No Treatment Required',40),
    (p_event_id,'EMS','TRANSFERRED_TO_TREATMENT','Transferred to Treatment Area',50),
    (p_event_id,'EMS','TRANSPORTED','Transported by Event Ambulance',60),
    (p_event_id,'EMS','TRANSPORTED_OUTSIDE','Transported by Outside Ambulance',70),
    (p_event_id,'EMS','RELEASED_FROM_TREATMENT','Released from Treatment Area',80),
    (p_event_id,'EMS','LEFT_BEFORE_EVALUATION','Left Before Evaluation / Completion',90),
    (p_event_id,'EMS','TRANSFERRED_TO_OTHER_PROVIDER','Transferred to Other Provider',100),
    (p_event_id,'EMS','DECEASED','Deceased',110),
    (p_event_id,'EMS','OTHER','Other EMS Disposition',120)
  on conflict(event_id,scope,code) do nothing;
end;
$$;

revoke all on function public.seed_default_event_dispositions(uuid) from public;

-- Backfill every current event.
do $$
declare
  event_rec record;
begin
  for event_rec in select id from public.events loop
    perform public.seed_default_event_dispositions(event_rec.id);
  end loop;
end $$;

-- Automatically seed future events.
create or replace function private.seed_event_dispositions_after_insert()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.seed_default_event_dispositions(new.id);
  return new;
end;
$$;

drop trigger if exists seed_event_dispositions_after_insert on public.events;
create trigger seed_event_dispositions_after_insert
after insert on public.events
for each row
execute function private.seed_event_dispositions_after_insert();

-- ============================================================
-- STRUCTURED INCIDENT CLOSE
-- ============================================================

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
  released_count integer:=0;
  ems_context boolean:=false;
  general_code text;
  ems_code text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id
    and status='OPEN';

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

  -- Do not allow the generic close workflow to bypass the transport-outcome
  -- confirmation for an event ambulance that is actively transporting.
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

  -- Apply the final EMS disposition to the incident's EMS encounter record(s).
  -- An EMS flow may have been closed by the field/treatment user before Dispatch
  -- closes the CAD incident, so preserve its original close time while storing
  -- the final selected disposition consistently.
  if ems_code is not null then
    update public.ems_encounters
    set
      current_status='CLOSED',
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

  -- Release every unit still committed to the incident.
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
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
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
      'released_units',released_count
    ),
    auth.uid(),'staff'
  );
end;
$$;

revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;

-- ============================================================
-- STANDARDIZED EMS RELEASE
-- ============================================================

create or replace function public.ems_release_encounter(
  p_encounter_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  disposition_code text;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
    or e.current_treatment_area_id=private.current_treatment_area()
  ) then
    raise exception 'Only the current holder can close this encounter';
  end if;

  disposition_code:=upper(trim(coalesce(p_disposition,'')));

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=e.event_id
      and d.scope='EMS'
      and d.code=disposition_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  update public.ems_handoffs
  set status='CANCELLED',responded_at=now()
  where encounter_id=e.id
    and status='PENDING';

  update public.ems_encounters
  set
    current_status='CLOSED',
    final_disposition=disposition_code,
    transport_completed_at=case
      when disposition_code='TRANSPORTED'
        and transport_started_at is not null
        then coalesce(transport_completed_at,now())
      else transport_completed_at
    end,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,
    e.incident_id,
    e.current_unit_id,
    'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object(
      'encounter_id',e.id,
      'ems_disposition',disposition_code
    ),
    auth.uid(),
    case
      when public.can_dispatch_event(e.event_id) then 'staff'
      when e.current_treatment_area_id=private.current_treatment_area() then 'treatment'
      else 'field'
    end
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;

-- ============================================================
-- AMBULANCE OUTCOME NOW STORES GENERAL + EMS DISPOSITIONS
-- ============================================================

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
  ems_disposition_value text;
  general_disposition_value text:='COMPLETED';
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

  ems_disposition_value:=case
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
    final_disposition=ems_disposition_value,
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
      'ems_disposition',ems_disposition_value,
      'general_disposition',general_disposition_value,
      'destination',destination_value,
      'incident_will_close',true
    ),
    auth.uid(),actor_kind_value
  );

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

  update public.incidents
  set
    status='CLOSED',
    closed_at=now(),
    disposition=general_disposition_value
  where id=p_incident_id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_disposition_value,
      'general_disposition',general_disposition_value,
      'ems_disposition',ems_disposition_value,
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


-- CommCenter Pro v0.9.5
-- Dispatch close must terminate EMS treatment-center custody as part of the
-- same database transaction.
--
-- When Dispatch closes a CAD incident, any patient still assigned to a
-- Treatment Area is removed from that treatment area's active census,
-- the EMS encounter is closed with the selected EMS disposition, pending
-- handoffs are cancelled, and the action is written to CAD activity.

-- ============================================================
-- STRUCTURED INCIDENT CLOSE + TREATMENT-CENTER RELEASE
-- ============================================================

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
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
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

revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;

-- ============================================================
-- LEGACY CLOSE SAFETY
-- ============================================================
-- Older cached clients may still call close_incident(). Never let that legacy
-- path orphan a patient in EMS / Treatment. EMS calls are rejected and must be
-- closed with the current structured close workflow.

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
  i public.incidents;
  mapped_general_code text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id;

  if i.id is null then
    raise exception 'Incident not found';
  end if;

  if not public.can_dispatch_event(i.event_id) then
    raise exception 'Dispatch access required';
  end if;

  if exists(
    select 1
    from public.ems_encounters e
    where e.event_id=i.event_id
      and e.incident_id=i.id
  ) then
    raise exception 'This incident has EMS patient flow. Refresh CommCenter and use the current Close Incident workflow so treatment custody and EMS disposition are cleared safely.';
  end if;

  mapped_general_code:=case
    when upper(trim(coalesce(p_disposition,''))) in ('','COMPLETE','COMPLETED','RESOLVED')
      then 'COMPLETED'
    when upper(trim(coalesce(p_disposition,''))) in ('CANCELLED','CANCELED')
      then 'CANCELLED'
    when upper(trim(coalesce(p_disposition,'')))='NO ACTION REQUIRED'
      then 'NO_ACTION_REQUIRED'
    when upper(trim(coalesce(p_disposition,'')))='UNFOUNDED'
      then 'UNFOUNDED'
    else 'OTHER'
  end;

  perform public.close_incident_v2(
    p_incident_id,
    mapped_general_code,
    null
  );
end;
$$;

revoke all on function public.close_incident(uuid,text) from public;
grant execute on function public.close_incident(uuid,text) to authenticated;

-- ============================================================
-- CONSISTENT EMS ENCOUNTER RELEASE
-- ============================================================
-- Normal Field / Treatment closure now also clears current custody fields.
-- Historical custody remains available in EMS handoffs and CAD activity.

create or replace function public.ems_release_encounter(
  p_encounter_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  disposition_code text;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED'
  for update;

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
    or e.current_treatment_area_id=private.current_treatment_area()
  ) then
    raise exception 'Only the current holder can close this encounter';
  end if;

  disposition_code:=upper(trim(coalesce(p_disposition,'')));

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=e.event_id
      and d.scope='EMS'
      and d.code=disposition_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now())
  where encounter_id=e.id
    and status='PENDING';

  update public.ems_encounters
  set
    current_status='CLOSED',
    current_unit_id=null,
    current_treatment_area_id=null,
    final_disposition=disposition_code,
    transport_completed_at=case
      when disposition_code='TRANSPORTED'
        and transport_started_at is not null
        then coalesce(transport_completed_at,now())
      else transport_completed_at
    end,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,
    e.incident_id,
    e.current_unit_id,
    'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object(
      'encounter_id',e.id,
      'ems_disposition',disposition_code,
      'released_from_unit_id',e.current_unit_id,
      'released_from_treatment_area_id',e.current_treatment_area_id
    ),
    auth.uid(),
    case
      when public.can_dispatch_event(e.event_id) then 'staff'
      when e.current_treatment_area_id=private.current_treatment_area() then 'treatment'
      else 'field'
    end
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;


-- CommCenter Pro v0.10.0
-- Guest Logistics / Special Guest Movement module.
--
-- Prescheduled transportation is kept separate from CAD incidents so a
-- convention can manage hundreds of airport/hotel/venue movements without
-- filling the emergency/operations CAD board with scheduled trips.
--
-- Guest Logistics uses the SAME CommCenter event, departments, units,
-- Operational Periods, field sessions and Realtime infrastructure. Ad-hoc
-- errands and operational requests remain normal CAD incidents.

-- ============================================================
-- DEPARTMENT MODULE FLAG
-- ============================================================

alter table public.event_departments
  add column if not exists guest_logistics_enabled boolean not null default false;

-- ============================================================
-- TABLES
-- ============================================================

create table if not exists public.guest_logistics_settings (
  event_id uuid primary key references public.events(id) on delete cascade,
  next_movement_number integer not null default 1 check(next_movement_number>=1)
);

create table if not exists public.guest_logistics_movements (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  department_id uuid not null references public.event_departments(id) on delete restrict,
  operational_period_id uuid references public.operational_periods(id) on delete set null,

  movement_number text not null,
  movement_type text not null default 'OTHER'
    check(movement_type in (
      'AIRPORT_ARRIVAL',
      'AIRPORT_DEPARTURE',
      'HOTEL_TRANSFER',
      'VENUE_TRANSFER',
      'LOCAL_TRANSFER',
      'OTHER'
    )),
  status text not null default 'SCHEDULED'
    check(status in (
      'SCHEDULED',
      'READY',
      'ASSIGNED',
      'EN_ROUTE_PICKUP',
      'AT_PICKUP',
      'PASSENGER_ONBOARD',
      'EN_ROUTE_DESTINATION',
      'COMPLETE',
      'NO_SHOW',
      'CANCELLED'
    )),

  guest_name text not null,
  guest_group text,
  party_size integer not null default 1 check(party_size>=1 and party_size<=500),
  contact_phone text,
  contact_email text,

  scheduled_at timestamptz not null,
  origin text not null,
  destination text not null,

  airline text,
  flight_number text,
  airport text,
  terminal text,

  assigned_unit_id uuid references public.units(id) on delete set null,
  assigned_at timestamptz,
  driver_acknowledged_at timestamptz,
  en_route_pickup_at timestamptz,
  at_pickup_at timestamptz,
  passenger_onboard_at timestamptz,
  en_route_destination_at timestamptz,
  completed_at timestamptz,
  no_show_at timestamptz,
  cancelled_at timestamptz,

  external_reference text,
  import_source text,
  notes text,

  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique(event_id,movement_number)
);

create index if not exists guest_logistics_movements_event_schedule_idx
  on public.guest_logistics_movements(event_id,scheduled_at,status);

create index if not exists guest_logistics_movements_department_idx
  on public.guest_logistics_movements(department_id,status,scheduled_at);

create index if not exists guest_logistics_movements_unit_idx
  on public.guest_logistics_movements(assigned_unit_id,status);

drop index if exists public.guest_logistics_one_active_movement_per_unit_idx;
create unique index guest_logistics_one_active_movement_per_unit_idx
  on public.guest_logistics_movements(assigned_unit_id)
  where assigned_unit_id is not null
    and status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION');

create table if not exists public.guest_logistics_activity (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  movement_id uuid not null references public.guest_logistics_movements(id) on delete cascade,
  unit_id uuid references public.units(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  actor_user_id uuid references auth.users(id),
  actor_kind text not null default 'staff'
    check(actor_kind in ('staff','field','system')),
  created_at timestamptz not null default now()
);

create index if not exists guest_logistics_activity_movement_idx
  on public.guest_logistics_activity(movement_id,created_at);

-- ============================================================
-- SECURITY HELPERS
-- ============================================================

create or replace function private.staff_can_access_department(
  p_event_id uuid,
  p_department_id uuid
)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists(
    select 1
    from public.event_departments d
    join public.events e on e.id=d.event_id
    left join public.organization_members om
      on om.organization_id=e.organization_id
     and om.user_id=(select auth.uid())
    left join public.event_staff es
      on es.event_id=e.id
     and es.user_id=(select auth.uid())
    where d.id=p_department_id
      and d.event_id=p_event_id
      and (
        public.is_platform_admin()
        or om.role in ('owner','admin','dispatcher')
        or es.role in ('event_admin','dispatcher','supervisor')
      )
      and (
        public.is_platform_admin()
        or om.role in ('owner','admin')
        or es.role='event_admin'
        or not exists(
          select 1
          from public.staff_department_access sda
          where sda.event_id=p_event_id
            and sda.user_id=(select auth.uid())
        )
        or exists(
          select 1
          from public.staff_department_access sda
          where sda.event_id=p_event_id
            and sda.user_id=(select auth.uid())
            and sda.department_id=p_department_id
        )
      )
  );
$$;

revoke all on function private.staff_can_access_department(uuid,uuid) from public;
grant execute on function private.staff_can_access_department(uuid,uuid) to authenticated;

create or replace function private.guest_logistics_staff_access(
  p_event_id uuid,
  p_department_id uuid
)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists(
    select 1
    from public.event_departments d
    where d.id=p_department_id
      and d.event_id=p_event_id
      and d.active=true
      and d.guest_logistics_enabled=true
      and private.staff_can_access_department(p_event_id,p_department_id)
  );
$$;

revoke all on function private.guest_logistics_staff_access(uuid,uuid) from public;
grant execute on function private.guest_logistics_staff_access(uuid,uuid) to authenticated;

-- ============================================================
-- RLS
-- ============================================================

alter table public.guest_logistics_settings enable row level security;
alter table public.guest_logistics_movements enable row level security;
alter table public.guest_logistics_activity enable row level security;

drop policy if exists guest_logistics_settings_staff_read on public.guest_logistics_settings;
create policy guest_logistics_settings_staff_read
on public.guest_logistics_settings
for select
to authenticated
using(public.has_event_staff_access(event_id));

drop policy if exists guest_logistics_movements_read on public.guest_logistics_movements;
create policy guest_logistics_movements_read
on public.guest_logistics_movements
for select
to authenticated
using(
  private.staff_can_access_department(event_id,department_id)
  or assigned_unit_id=private.current_field_unit()
);

drop policy if exists guest_logistics_activity_read on public.guest_logistics_activity;
create policy guest_logistics_activity_read
on public.guest_logistics_activity
for select
to authenticated
using(
  exists(
    select 1
    from public.guest_logistics_movements m
    where m.id=movement_id
      and (
        private.staff_can_access_department(m.event_id,m.department_id)
        or m.assigned_unit_id=private.current_field_unit()
      )
  )
);

grant select on public.guest_logistics_settings to authenticated;
grant select on public.guest_logistics_movements to authenticated;
grant select on public.guest_logistics_activity to authenticated;
grant usage,select on sequence public.guest_logistics_activity_id_seq to authenticated;

-- ============================================================
-- NUMBERING
-- ============================================================

create or replace function private.next_guest_movement_number(p_event_id uuid)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  n integer;
begin
  insert into public.guest_logistics_settings(event_id,next_movement_number)
  values(p_event_id,1)
  on conflict(event_id) do nothing;

  select next_movement_number
  into n
  from public.guest_logistics_settings
  where event_id=p_event_id
  for update;

  update public.guest_logistics_settings
  set next_movement_number=n+1
  where event_id=p_event_id;

  return 'MOVE-'||lpad(n::text,4,'0');
end;
$$;

revoke all on function private.next_guest_movement_number(uuid) from public;

-- ============================================================
-- CREATE / UPDATE
-- ============================================================

create or replace function public.guest_logistics_create_movement(
  p_event_id uuid,
  p_department_id uuid,
  p_operational_period_id uuid,
  p_guest_name text,
  p_guest_group text,
  p_party_size integer,
  p_scheduled_at timestamptz,
  p_movement_type text,
  p_origin text,
  p_destination text,
  p_airline text default null,
  p_flight_number text default null,
  p_airport text default null,
  p_terminal text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_external_reference text default null,
  p_import_source text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  movement_id_value uuid;
  movement_number_value text;
  movement_type_value text;
  op_id uuid;
begin
  if not private.guest_logistics_staff_access(p_event_id,p_department_id) then
    raise exception 'Guest Logistics access required for this department';
  end if;

  if nullif(trim(coalesce(p_guest_name,'')),'') is null then
    raise exception 'Guest / party name is required';
  end if;

  if p_scheduled_at is null then
    raise exception 'Scheduled movement time is required';
  end if;

  if nullif(trim(coalesce(p_origin,'')),'') is null
     or nullif(trim(coalesce(p_destination,'')),'') is null then
    raise exception 'Origin and destination are required';
  end if;

  movement_type_value:=upper(trim(coalesce(p_movement_type,'OTHER')));
  if movement_type_value not in (
    'AIRPORT_ARRIVAL',
    'AIRPORT_DEPARTURE',
    'HOTEL_TRANSFER',
    'VENUE_TRANSFER',
    'LOCAL_TRANSFER',
    'OTHER'
  ) then
    raise exception 'Invalid movement type';
  end if;

  if p_operational_period_id is not null then
    select id into op_id
    from public.operational_periods
    where id=p_operational_period_id
      and event_id=p_event_id;
    if op_id is null then
      raise exception 'Operational Period is not part of this event';
    end if;
  else
    select id into op_id
    from public.operational_periods
    where event_id=p_event_id
      and status='ACTIVE'
    limit 1;
  end if;

  movement_number_value:=private.next_guest_movement_number(p_event_id);

  insert into public.guest_logistics_movements(
    event_id,
    department_id,
    operational_period_id,
    movement_number,
    movement_type,
    status,
    guest_name,
    guest_group,
    party_size,
    contact_phone,
    contact_email,
    scheduled_at,
    origin,
    destination,
    airline,
    flight_number,
    airport,
    terminal,
    external_reference,
    import_source,
    notes,
    created_by
  ) values(
    p_event_id,
    p_department_id,
    op_id,
    movement_number_value,
    movement_type_value,
    'SCHEDULED',
    trim(p_guest_name),
    nullif(trim(coalesce(p_guest_group,'')),''),
    greatest(1,coalesce(p_party_size,1)),
    nullif(trim(coalesce(p_contact_phone,'')),''),
    nullif(trim(coalesce(p_contact_email,'')),''),
    p_scheduled_at,
    trim(p_origin),
    trim(p_destination),
    nullif(trim(coalesce(p_airline,'')),''),
    nullif(trim(coalesce(p_flight_number,'')),''),
    nullif(trim(coalesce(p_airport,'')),''),
    nullif(trim(coalesce(p_terminal,'')),''),
    nullif(trim(coalesce(p_external_reference,'')),''),
    nullif(trim(coalesce(p_import_source,'')),''),
    nullif(trim(coalesce(p_notes,'')),''),
    auth.uid()
  )
  returning id into movement_id_value;

  insert into public.guest_logistics_activity(
    event_id,movement_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    movement_id_value,
    'MOVEMENT_CREATED',
    jsonb_build_object(
      'movement_number',movement_number_value,
      'scheduled_at',p_scheduled_at,
      'origin',trim(p_origin),
      'destination',trim(p_destination),
      'import_source',nullif(trim(coalesce(p_import_source,'')),'')
    ),
    auth.uid(),
    'staff'
  );

  return movement_id_value;
end;
$$;

create or replace function public.guest_logistics_update_movement(
  p_movement_id uuid,
  p_operational_period_id uuid,
  p_guest_name text,
  p_guest_group text,
  p_party_size integer,
  p_scheduled_at timestamptz,
  p_movement_type text,
  p_origin text,
  p_destination text,
  p_airline text default null,
  p_flight_number text default null,
  p_airport text default null,
  p_terminal text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_external_reference text default null,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
  movement_type_value text;
begin
  select * into m
  from public.guest_logistics_movements
  where id=p_movement_id
  for update;

  if m.id is null then
    raise exception 'Movement not found';
  end if;

  if not private.guest_logistics_staff_access(m.event_id,m.department_id) then
    raise exception 'Guest Logistics access required';
  end if;

  if m.status in ('COMPLETE','NO_SHOW','CANCELLED') then
    raise exception 'Completed / cancelled movements cannot be edited';
  end if;

  if nullif(trim(coalesce(p_guest_name,'')),'') is null then
    raise exception 'Guest / party name is required';
  end if;

  if p_scheduled_at is null then
    raise exception 'Scheduled movement time is required';
  end if;

  if nullif(trim(coalesce(p_origin,'')),'') is null
     or nullif(trim(coalesce(p_destination,'')),'') is null then
    raise exception 'Origin and destination are required';
  end if;

  movement_type_value:=upper(trim(coalesce(p_movement_type,'OTHER')));
  if movement_type_value not in (
    'AIRPORT_ARRIVAL',
    'AIRPORT_DEPARTURE',
    'HOTEL_TRANSFER',
    'VENUE_TRANSFER',
    'LOCAL_TRANSFER',
    'OTHER'
  ) then
    raise exception 'Invalid movement type';
  end if;

  if p_operational_period_id is not null and not exists(
    select 1
    from public.operational_periods op
    where op.id=p_operational_period_id
      and op.event_id=m.event_id
  ) then
    raise exception 'Operational Period is not part of this event';
  end if;

  update public.guest_logistics_movements
  set
    operational_period_id=p_operational_period_id,
    guest_name=trim(p_guest_name),
    guest_group=nullif(trim(coalesce(p_guest_group,'')),''),
    party_size=greatest(1,coalesce(p_party_size,1)),
    scheduled_at=p_scheduled_at,
    movement_type=movement_type_value,
    origin=trim(p_origin),
    destination=trim(p_destination),
    airline=nullif(trim(coalesce(p_airline,'')),''),
    flight_number=nullif(trim(coalesce(p_flight_number,'')),''),
    airport=nullif(trim(coalesce(p_airport,'')),''),
    terminal=nullif(trim(coalesce(p_terminal,'')),''),
    contact_phone=nullif(trim(coalesce(p_contact_phone,'')),''),
    contact_email=nullif(trim(coalesce(p_contact_email,'')),''),
    external_reference=nullif(trim(coalesce(p_external_reference,'')),''),
    notes=nullif(trim(coalesce(p_notes,'')),''),
    updated_at=now()
  where id=m.id;

  insert into public.guest_logistics_activity(
    event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,m.id,m.assigned_unit_id,'MOVEMENT_UPDATED',
    jsonb_build_object('scheduled_at',p_scheduled_at),
    auth.uid(),'staff'
  );
end;
$$;

-- ============================================================
-- BULK CSV IMPORT
-- ============================================================

create or replace function public.guest_logistics_import_movements(
  p_event_id uuid,
  p_department_id uuid,
  p_rows jsonb,
  p_source text default 'CSV Import'
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  item jsonb;
  imported_count integer:=0;
  movement_id_value uuid;
  op_id uuid;
  scheduled_value timestamptz;
begin
  if not private.guest_logistics_staff_access(p_event_id,p_department_id) then
    raise exception 'Guest Logistics access required for this department';
  end if;

  if jsonb_typeof(p_rows)<>'array' then
    raise exception 'Import rows must be a JSON array';
  end if;

  for item in select value from jsonb_array_elements(p_rows)
  loop
    begin
      scheduled_value:=(item->>'scheduled_at')::timestamptz;
    exception when others then
      raise exception 'Invalid scheduled_at for guest %',coalesce(item->>'guest_name','(unknown)');
    end;

    op_id:=null;
    if nullif(item->>'operational_period_id','') is not null then
      op_id:=(item->>'operational_period_id')::uuid;
    end if;

    movement_id_value:=public.guest_logistics_create_movement(
      p_event_id,
      p_department_id,
      op_id,
      item->>'guest_name',
      item->>'guest_group',
      greatest(1,coalesce(nullif(item->>'party_size','')::integer,1)),
      scheduled_value,
      coalesce(nullif(item->>'movement_type',''),'OTHER'),
      item->>'origin',
      item->>'destination',
      item->>'airline',
      item->>'flight_number',
      item->>'airport',
      item->>'terminal',
      item->>'contact_phone',
      item->>'contact_email',
      item->>'external_reference',
      p_source,
      item->>'notes'
    );

    imported_count:=imported_count+1;
  end loop;

  return imported_count;
end;
$$;

-- ============================================================
-- DRIVER ASSIGNMENT
-- ============================================================

create or replace function public.guest_logistics_assign_unit(
  p_movement_id uuid,
  p_unit_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  m public.guest_logistics_movements;
  u public.units;
  previous_unit_id uuid;
begin
  select * into m
  from public.guest_logistics_movements
  where id=p_movement_id
  for update;

  if m.id is null then
    raise exception 'Movement not found';
  end if;

  if not private.guest_logistics_staff_access(m.event_id,m.department_id) then
    raise exception 'Guest Logistics dispatch access required';
  end if;

  if m.status not in ('SCHEDULED','READY','ASSIGNED') then
    raise exception 'Driver assignment can only be changed before the movement is underway';
  end if;

  select * into u
  from public.units
  where id=p_unit_id
    and event_id=m.event_id
    and active=true;

  if u.id is null then
    raise exception 'Driver unit is not active in this event';
  end if;

  if not exists(
    select 1
    from public.event_departments d
    where d.id=u.department_id
      and d.event_id=m.event_id
      and d.active=true
      and d.guest_logistics_enabled=true
  ) then
    raise exception 'Driver unit must belong to a Guest Logistics enabled department';
  end if;

  if not private.staff_can_access_department(m.event_id,u.department_id) then
    raise exception 'You do not have access to dispatch that driver unit';
  end if;

  previous_unit_id:=m.assigned_unit_id;

  -- Preassignment is scheduling metadata. A driver may be preassigned to
  -- multiple future trips and may still handle CAD work until they actually
  -- begin EN_ROUTE_PICKUP.
  update public.guest_logistics_movements
  set
    assigned_unit_id=u.id,
    assigned_at=now(),
    status='ASSIGNED',
    updated_at=now()
  where id=m.id;

  insert into public.guest_logistics_activity(
    event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,m.id,u.id,
    case when previous_unit_id is null then 'DRIVER_ASSIGNED' else 'DRIVER_REASSIGNED' end,
    jsonb_build_object(
      'unit_name',u.name,
      'previous_unit_id',previous_unit_id
    ),
    auth.uid(),'staff'
  );

  insert into public.cad_activity(
    event_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,u.id,'LOGISTICS_MOVEMENT_ASSIGNED',
    jsonb_build_object(
      'movement_id',m.id,
      'movement_number',m.movement_number,
      'guest_name',m.guest_name,
      'scheduled_at',m.scheduled_at,
      'preassigned',true
    ),
    auth.uid(),'staff'
  );
end;
$$;

create or replace function public.guest_logistics_unassign_unit(
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

  if not private.guest_logistics_staff_access(m.event_id,m.department_id) then
    raise exception 'Guest Logistics dispatch access required';
  end if;

  if m.assigned_unit_id is null then
    return;
  end if;

  if m.status not in ('ASSIGNED','READY','SCHEDULED') then
    raise exception 'An underway movement cannot be unassigned. Complete or cancel the movement instead.';
  end if;

  insert into public.guest_logistics_activity(
    event_id,movement_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    m.event_id,m.id,m.assigned_unit_id,'DRIVER_UNASSIGNED','{}'::jsonb,auth.uid(),'staff'
  );

  update public.guest_logistics_movements
  set
    assigned_unit_id=null,
    assigned_at=null,
    status='READY',
    updated_at=now()
  where id=m.id;
end;
$$;

-- ============================================================
-- DRIVER ACKNOWLEDGEMENT
-- ============================================================

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

  if m.status not in ('ASSIGNED','READY') then
    raise exception 'Movement cannot be acknowledged in its current status';
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

-- ============================================================
-- MOVEMENT STATUS
-- ============================================================

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
  mapped_unit_status text;
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
      from public.incident_units iu
      join public.incidents i on i.id=iu.incident_id
      where iu.unit_id=m.assigned_unit_id
        and iu.cleared_at is null
        and i.status='OPEN'
    ) then
      raise exception 'Driver unit is still assigned to an active CAD incident';
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

  mapped_unit_status:=case target_status
    when 'EN_ROUTE_PICKUP' then 'RESPONDING'
    when 'AT_PICKUP' then 'ON_SCENE'
    when 'PASSENGER_ONBOARD' then 'TRANSPORTING'
    when 'EN_ROUTE_DESTINATION' then 'TRANSPORTING'
    when 'COMPLETE' then 'AVAILABLE'
    when 'NO_SHOW' then 'AVAILABLE'
    when 'CANCELLED' then 'AVAILABLE'
    else null
  end;

  -- Preassignment / READY does not alter the shared CAD unit status. Once
  -- underway, Guest Logistics owns the status until the movement terminates.
  if m.assigned_unit_id is not null
     and mapped_unit_status is not null
     and (old_was_underway or target_is_underway)
  then
    select status into old_unit_status
    from public.units
    where id=m.assigned_unit_id
    for update;

    update public.units
    set
      status=mapped_unit_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=m.assigned_unit_id;

    if old_unit_status is distinct from mapped_unit_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind
      ) values(
        m.event_id,null,m.assigned_unit_id,
        old_unit_status,mapped_unit_status,
        auth.uid(),actor_kind_value
      );
    end if;
  end if;

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

-- ============================================================
-- CAD / ARCHIVE CONFLICT GUARDS
-- ============================================================

-- Prevent CAD from assigning a unit that is already committed to a Guest
-- Logistics movement. Guest errands themselves should be normal CAD incidents;
-- scheduled guest transportation remains in this module.
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
  movement_number_value text;
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

  select movement_number
  into movement_number_value
  from public.guest_logistics_movements
  where assigned_unit_id=p_unit_id
    and status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION')
  order by scheduled_at
  limit 1;

  if movement_number_value is not null then
    raise exception 'Unit is already assigned to Guest Logistics movement %',movement_number_value;
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
    ) values(
      eid,p_incident_id,p_unit_id,old_s,'ASSIGNED',auth.uid(),'staff'
    );
  end if;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,'UNIT_ASSIGNED',auth.uid(),'staff'
  );
end;
$$;

create or replace function private.guard_guest_logistics_unit_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true and new.active=false and exists(
    select 1
    from public.guest_logistics_movements m
    where m.assigned_unit_id=old.id
      and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
  ) then
    raise exception 'Unit has an active Guest Logistics movement. Complete, cancel, or reassign the movement first.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_guest_logistics_unit_archive on public.units;
create trigger guard_guest_logistics_unit_archive
before update of active on public.units
for each row
execute function private.guard_guest_logistics_unit_archive();



create or replace function private.guard_guest_logistics_event_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true
     and new.active=false
     and exists(
       select 1
       from public.guest_logistics_movements m
       where m.event_id=old.id
         and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
     )
  then
    raise exception 'Event has open Guest Logistics movements. Complete or cancel them before archiving the event.';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_guest_logistics_event_archive on public.events;
create trigger guard_guest_logistics_event_archive
before update of active on public.events
for each row
execute function private.guard_guest_logistics_event_archive();

create or replace function private.guard_guest_logistics_department_disable()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.guest_logistics_enabled=true
     and new.guest_logistics_enabled=false
     and exists(
       select 1
       from public.guest_logistics_movements m
       where m.department_id=old.id
         and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
     )
  then
    raise exception 'Department has open Guest Logistics movements. Complete or cancel them before disabling Guest Logistics.';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_guest_logistics_department_disable on public.event_departments;
create trigger guard_guest_logistics_department_disable
before update of guest_logistics_enabled on public.event_departments
for each row
execute function private.guard_guest_logistics_department_disable();

create or replace function private.guard_guest_logistics_department_archive()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.active=true and new.active=false and exists(
    select 1
    from public.guest_logistics_movements m
    where m.department_id=old.id
      and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
  ) then
    raise exception 'Department has active Guest Logistics movements. Complete or cancel them first.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_guest_logistics_department_archive on public.event_departments;
create trigger guard_guest_logistics_department_archive
before update of active on public.event_departments
for each row
execute function private.guard_guest_logistics_department_archive();

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
      and tablename='guest_logistics_movements'
  ) then
    alter publication supabase_realtime add table public.guest_logistics_movements;
  end if;
end $$;

-- ============================================================
-- GRANTS
-- ============================================================

revoke all on function public.guest_logistics_create_movement(
  uuid,uuid,uuid,text,text,integer,timestamptz,text,text,text,text,text,text,text,text,text,text,text,text
) from public;

revoke all on function public.guest_logistics_update_movement(
  uuid,uuid,text,text,integer,timestamptz,text,text,text,text,text,text,text,text,text,text,text
) from public;

revoke all on function public.guest_logistics_import_movements(uuid,uuid,jsonb,text) from public;
revoke all on function public.guest_logistics_assign_unit(uuid,uuid) from public;
revoke all on function public.guest_logistics_unassign_unit(uuid) from public;
revoke all on function public.guest_logistics_set_status(uuid,text) from public;
revoke all on function public.guest_logistics_acknowledge_movement(uuid) from public;

grant execute on function public.guest_logistics_create_movement(
  uuid,uuid,uuid,text,text,integer,timestamptz,text,text,text,text,text,text,text,text,text,text,text,text
) to authenticated;

grant execute on function public.guest_logistics_update_movement(
  uuid,uuid,text,text,integer,timestamptz,text,text,text,text,text,text,text,text,text,text,text
) to authenticated;

grant execute on function public.guest_logistics_import_movements(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.guest_logistics_assign_unit(uuid,uuid) to authenticated;
grant execute on function public.guest_logistics_unassign_unit(uuid) to authenticated;
grant execute on function public.guest_logistics_set_status(uuid,text) to authenticated;
grant execute on function public.guest_logistics_acknowledge_movement(uuid) to authenticated;


-- ============================================================
-- STATUS API GUARDS
-- ============================================================
-- While a unit is assigned to an active guest movement, its operational unit
-- status is driven by the movement workflow. Generic staff/field status buttons
-- are blocked so CAD and Guest Logistics cannot silently diverge.

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

  if exists(
    select 1
    from public.guest_logistics_movements m
    where m.assigned_unit_id=p_unit_id
      and m.status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION')
  ) then
    raise exception 'Unit status is controlled by an underway Guest Logistics movement. Update the movement from Guest Logistics instead.';
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

  if exists(
    select 1
    from public.guest_logistics_movements m
    where m.assigned_unit_id=p_unit_id
      and m.status in ('EN_ROUTE_PICKUP','AT_PICKUP','PASSENGER_ONBOARD','EN_ROUTE_DESTINATION')
  ) then
    raise exception 'Unit status is controlled by an underway Guest Logistics movement. Use the Guest Logistics movement controls instead.';
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

revoke all on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) from public;
grant execute on function public.field_set_unit_status_v2(uuid,text,uuid,timestamptz,text,uuid) to authenticated;
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

-- CommCenter Pro v0.12.0
-- Operational Period-bound Field sessions + event-wide Field Layout Builder.
--
-- 1. Every new Field session is bound to the ACTIVE Operational Period.
-- 2. Ending / replacing an Operational Period immediately ends every Field
--    session created for that period and clears live GPS locations.
-- 3. Field access helpers refuse stale sessions whose Operational Period is no
--    longer ACTIVE, even if a client somehow misses the Realtime kick-out.
-- 4. Each event receives one global field_layout_config used by every Field
--    unit in that event.

-- ============================================================
-- EVENT-WIDE FIELD LAYOUT CONFIGURATION
-- ============================================================

alter table public.events
  add column if not exists field_layout_config jsonb not null default
  '{
    "version":1,
    "blocks":[
      {"id":"unit_identity","enabled":true},
      {"id":"current_call","enabled":true},
      {"id":"guest_logistics","enabled":true},
      {"id":"ems_patient_flow","enabled":true},
      {"id":"status_controls","enabled":true},
      {"id":"transport_destination","enabled":true},
      {"id":"run_times","enabled":true},
      {"id":"live_location","enabled":true},
      {"id":"connectivity_offline","enabled":true},
      {"id":"session_controls","enabled":true}
    ]
  }'::jsonb;

create or replace function public.admin_save_field_layout(
  p_event_id uuid,
  p_layout jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  blocks jsonb;
  item jsonb;
  block_id text;
  seen text[]:=array[]::text[];
  normalized jsonb:='[]'::jsonb;
  required_id text;
  allowed_ids constant text[]:=array[
    'unit_identity',
    'status_controls',
    'run_times',
    'current_call',
    'guest_logistics',
    'ems_patient_flow',
    'live_location',
    'transport_destination',
    'connectivity_offline',
    'session_controls'
  ];
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  if jsonb_typeof(p_layout)<>'object' then
    raise exception 'Field layout must be a JSON object';
  end if;

  blocks:=p_layout->'blocks';
  if jsonb_typeof(blocks)<>'array' then
    raise exception 'Field layout blocks must be an array';
  end if;

  for item in select value from jsonb_array_elements(blocks)
  loop
    block_id:=nullif(trim(item->>'id'),'');

    if block_id is null or not (block_id=any(allowed_ids)) then
      raise exception 'Unknown Field layout block: %',coalesce(block_id,'(blank)');
    end if;

    if block_id=any(seen) then
      raise exception 'Duplicate Field layout block: %',block_id;
    end if;

    seen:=array_append(seen,block_id);
    normalized:=normalized||jsonb_build_array(
      jsonb_build_object(
        'id',block_id,
        'enabled',case
          when block_id in ('unit_identity','status_controls','current_call','guest_logistics','ems_patient_flow','transport_destination','session_controls') then true
          else coalesce((item->>'enabled')::boolean,true)
        end
      )
    );
  end loop;

  -- Required operational blocks must be present. Context-specific blocks such as
  -- EMS, Guest Logistics, and Transport render no content when they do not apply,
  -- but cannot be globally disabled when they are operationally needed.
  foreach required_id in array array['unit_identity','status_controls','current_call','guest_logistics','ems_patient_flow','transport_destination','session_controls']
  loop
    if not required_id=any(seen) then
      raise exception 'Required Field layout block is missing: %',required_id;
    end if;
  end loop;

  -- Append any newly introduced optional block that an older client omitted.
  foreach block_id in array allowed_ids
  loop
    if not block_id=any(seen) then
      normalized:=normalized||jsonb_build_array(
        jsonb_build_object('id',block_id,'enabled',true)
      );
    end if;
  end loop;

  p_layout:=jsonb_build_object('version',1,'blocks',normalized);

  update public.events
  set field_layout_config=p_layout
  where id=p_event_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    'FIELD_LAYOUT_UPDATED',
    jsonb_build_object('layout',p_layout),
    auth.uid(),
    'staff'
  );

  return p_layout;
end;
$$;

revoke all on function public.admin_save_field_layout(uuid,jsonb) from public;
grant execute on function public.admin_save_field_layout(uuid,jsonb) to authenticated;

-- ============================================================
-- FIELD SESSIONS BELONG TO AN OPERATIONAL PERIOD
-- ============================================================

alter table public.field_sessions
  add column if not exists operational_period_id uuid
    references public.operational_periods(id) on delete set null,
  add column if not exists end_reason text;

create index if not exists field_sessions_operational_period_active_idx
  on public.field_sessions(operational_period_id,active);

-- Best-effort backfill for sessions that were active during this migration.
update public.field_sessions fs
set operational_period_id=op.id
from public.operational_periods op
where fs.operational_period_id is null
  and fs.active=true
  and op.event_id=fs.event_id
  and op.status='ACTIVE';

-- Any older active Field session that cannot be associated with a currently
-- ACTIVE Operational Period is no longer valid under the v0.12.0 model.
update public.field_sessions
set
  active=false,
  ended_at=now(),
  last_seen_at=now(),
  end_reason='MIGRATION_REQUIRES_OPERATIONAL_PERIOD_LOGIN'
where active=true
  and operational_period_id is null;

-- ============================================================
-- DEFENSIVE FIELD ACCESS HELPERS
-- ============================================================

create or replace function public.field_has_event_access(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.field_sessions fs
    join public.operational_periods op
      on op.id=fs.operational_period_id
     and op.event_id=fs.event_id
    where fs.event_id=p_event
      and fs.auth_user_id=auth.uid()
      and fs.active=true
      and op.status='ACTIVE'
  );
$$;

create or replace function private.current_field_unit()
returns uuid
language sql
stable
security definer
set search_path=''
as $$
  select fs.unit_id
  from public.field_sessions fs
  join public.operational_periods op
    on op.id=fs.operational_period_id
   and op.event_id=fs.event_id
  where fs.auth_user_id=(select auth.uid())
    and fs.active=true
    and fs.unit_id is not null
    and op.status='ACTIVE'
  order by fs.started_at desc
  limit 1;
$$;

-- ============================================================
-- FIELD LOGIN / UNIT CLAIM
-- ============================================================

create or replace function public.field_enter_event(
  p_event_code text,
  p_pin text,
  p_operator_name text default null
)
returns public.field_sessions
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.events;
  op public.operational_periods;
  fs public.field_sessions;
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

  select * into op
  from public.operational_periods
  where event_id=e.id
    and status='ACTIVE'
  limit 1;

  if op.id is null then
    raise exception 'No ACTIVE Operational Period. Field units can sign in after an Operational Period is activated.';
  end if;

  update public.field_sessions
  set
    active=false,
    ended_at=now(),
    last_seen_at=now(),
    end_reason='REPLACED_BY_NEW_FIELD_LOGIN'
  where auth_user_id=auth.uid()
    and active=true;

  -- Preserve the longstanding rule that one anonymous device session cannot
  -- simultaneously act as a Treatment Area Station and Field Unit.
  update public.treatment_area_sessions
  set active=false,ended_at=now()
  where auth_user_id=auth.uid()
    and active=true;

  insert into public.field_sessions(
    event_id,
    operational_period_id,
    auth_user_id,
    operator_name
  ) values(
    e.id,
    op.id,
    auth.uid(),
    nullif(trim(p_operator_name),'')
  )
  returning * into fs;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.id,
    'FIELD_SESSION_STARTED',
    jsonb_build_object(
      'field_session_id',fs.id,
      'operational_period_id',op.id,
      'operational_period_name',op.name,
      'incident_prefix',op.incident_prefix
    ),
    auth.uid(),
    'field'
  );

  return fs;
end;
$$;

create or replace function public.field_claim_unit(
  p_field_session_id uuid,
  p_unit_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions;
begin
  select * into fs
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true
  for update;

  if fs.id is null then
    raise exception 'Field session not found';
  end if;

  if not exists(
    select 1
    from public.operational_periods op
    where op.id=fs.operational_period_id
      and op.event_id=fs.event_id
      and op.status='ACTIVE'
  ) then
    raise exception 'This Field session expired when its Operational Period ended. Sign in again for the current Operational Period.';
  end if;

  if not exists(
    select 1
    from public.units
    where id=p_unit_id
      and event_id=fs.event_id
      and active=true
  ) then
    raise exception 'Invalid unit';
  end if;

  update public.field_sessions
  set unit_id=p_unit_id,last_seen_at=now()
  where id=fs.id;
end;
$$;

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
  set
    active=false,
    ended_at=now(),
    last_seen_at=now(),
    end_reason='USER_EXIT'
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

revoke all on function public.field_enter_event(text,text,text) from public;
revoke all on function public.field_claim_unit(uuid,uuid) from public;
revoke all on function public.field_release_unit(uuid) from public;
revoke all on function public.field_end_session(uuid) from public;

grant execute on function public.field_enter_event(text,text,text) to authenticated;
grant execute on function public.field_claim_unit(uuid,uuid) to authenticated;
grant execute on function public.field_release_unit(uuid) to authenticated;
grant execute on function public.field_end_session(uuid) to authenticated;

-- ============================================================
-- FORCE-END FIELD SESSIONS WHEN AN OPERATIONAL PERIOD ENDS
-- ============================================================

create or replace function private.end_field_sessions_for_operational_period()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  ended_count integer:=0;
begin
  if old.status='ACTIVE' and new.status<>'ACTIVE' then
    -- Remove current GPS positions first while the sessions still tell us which
    -- unit each device was controlling.
    delete from public.unit_locations ul
    where exists(
      select 1
      from public.field_sessions fs
      where fs.operational_period_id=old.id
        and fs.active=true
        and fs.unit_id=ul.unit_id
    );

    update public.field_sessions
    set
      active=false,
      ended_at=now(),
      last_seen_at=now(),
      end_reason='OPERATIONAL_PERIOD_ENDED'
    where operational_period_id=old.id
      and active=true;

    get diagnostics ended_count=row_count;

    insert into public.cad_activity(
      event_id,action,detail,actor_user_id,actor_kind
    ) values(
      old.event_id,
      'FIELD_SESSIONS_ENDED_OPERATIONAL_PERIOD',
      jsonb_build_object(
        'operational_period_id',old.id,
        'operational_period_name',old.name,
        'incident_prefix',old.incident_prefix,
        'field_sessions_ended',ended_count,
        'requires_new_field_login',true
      ),
      auth.uid(),
      case when auth.uid() is null then 'system' else 'staff' end
    );
  end if;

  return new;
end;
$$;

drop trigger if exists end_field_sessions_for_operational_period on public.operational_periods;
create trigger end_field_sessions_for_operational_period
after update of status on public.operational_periods
for each row
execute function private.end_field_sessions_for_operational_period();

-- ============================================================
-- REALTIME
-- ============================================================

-- Field devices need the field_sessions UPDATE immediately so an OP-end kick
-- is visible without waiting for the next user action. Event updates are used
-- so a saved Field Layout is also applied live to connected Field devices.
do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='field_sessions'
  ) then
    alter publication supabase_realtime add table public.field_sessions;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='events'
  ) then
    alter publication supabase_realtime add table public.events;
  end if;
end $$;


-- CommCenter Pro v0.13.0
-- Treatment Area Inbound Board + event-wide Treatment Area Layout Builder.
--
-- 1. A patient becomes INBOUND when an assigned non-ambulance Field unit is
--    TRANSPORTING to a configured Treatment Area.
-- 2. Inbound is derived from live unit transport state and is not counted in
--    Treatment Area census until custody is actually handed off.
-- 3. Treatment Area, Dispatch, or the transporting Field unit can complete the
--    same arrival/handoff workflow. Once complete, the unit clears and the
--    patient moves from INBOUND to the Treatment Area census through Realtime.
-- 4. Each event receives one global treatment_layout_config used by every
--    Treatment Area Station in that event.

-- ============================================================
-- EVENT-WIDE TREATMENT AREA LAYOUT CONFIGURATION
-- ============================================================

alter table public.events
  add column if not exists treatment_layout_config jsonb not null default
  '{
    "version":1,
    "blocks":[
      {"id":"station_summary","enabled":true},
      {"id":"inbound_patients","enabled":true},
      {"id":"census","enabled":true},
      {"id":"station_status","enabled":true},
      {"id":"walkin","enabled":true},
      {"id":"receive_existing","enabled":true},
      {"id":"report_qr","enabled":true},
      {"id":"session_controls","enabled":true}
    ]
  }'::jsonb;

create or replace function public.admin_save_treatment_layout(
  p_event_id uuid,
  p_layout jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  blocks jsonb;
  item jsonb;
  block_id text;
  seen text[]:=array[]::text[];
  normalized jsonb:='[]'::jsonb;
  required_id text;
  allowed_ids constant text[]:=array[
    'station_summary',
    'inbound_patients',
    'census',
    'station_status',
    'walkin',
    'receive_existing',
    'report_qr',
    'session_controls'
  ];
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  if jsonb_typeof(p_layout)<>'object' then
    raise exception 'Treatment layout must be a JSON object';
  end if;

  blocks:=p_layout->'blocks';
  if jsonb_typeof(blocks)<>'array' then
    raise exception 'Treatment layout blocks must be an array';
  end if;

  for item in select value from jsonb_array_elements(blocks)
  loop
    block_id:=nullif(trim(item->>'id'),'');

    if block_id is null or not (block_id=any(allowed_ids)) then
      raise exception 'Unknown Treatment layout block: %',coalesce(block_id,'(blank)');
    end if;

    if block_id=any(seen) then
      raise exception 'Duplicate Treatment layout block: %',block_id;
    end if;

    seen:=array_append(seen,block_id);
    normalized:=normalized||jsonb_build_array(
      jsonb_build_object(
        'id',block_id,
        'enabled',case
          when block_id in ('station_summary','inbound_patients','census','session_controls') then true
          else coalesce((item->>'enabled')::boolean,true)
        end
      )
    );
  end loop;

  foreach required_id in array array['station_summary','inbound_patients','census','session_controls']
  loop
    if not required_id=any(seen) then
      raise exception 'Required Treatment layout block is missing: %',required_id;
    end if;
  end loop;

  foreach block_id in array allowed_ids
  loop
    if not block_id=any(seen) then
      normalized:=normalized||jsonb_build_array(
        jsonb_build_object('id',block_id,'enabled',true)
      );
    end if;
  end loop;

  p_layout:=jsonb_build_object('version',1,'blocks',normalized);

  update public.events
  set treatment_layout_config=p_layout
  where id=p_event_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    'TREATMENT_LAYOUT_UPDATED',
    jsonb_build_object('layout',p_layout),
    auth.uid(),
    'staff'
  );

  return p_layout;
end;
$$;

revoke all on function public.admin_save_treatment_layout(uuid,jsonb) from public;
grant execute on function public.admin_save_treatment_layout(uuid,jsonb) to authenticated;

-- ============================================================
-- TREATMENT AREA INBOUND PATIENTS
-- ============================================================

create or replace function public.treatment_inbound_patients(
  p_treatment_area_id uuid
)
returns table(
  event_id uuid,
  treatment_area_id uuid,
  incident_id uuid,
  incident_number text,
  call_type text,
  priority text,
  landmark text,
  unit_id uuid,
  unit_name text,
  transport_started_at timestamptz,
  encounter_id uuid,
  current_ems_status text,
  operational_note text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  area_rec public.ems_treatment_areas;
begin
  select * into area_rec
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and active=true;

  if area_rec.id is null then
    raise exception 'Active Treatment Area not found';
  end if;

  if not (
    private.current_treatment_area()=area_rec.id
    or public.can_dispatch_event(area_rec.event_id)
  ) then
    raise exception 'Treatment Area access required';
  end if;

  return query
  select
    area_rec.event_id,
    area_rec.id,
    i.id,
    i.incident_number,
    i.call_type,
    i.priority,
    i.landmark,
    u.id,
    u.name,
    coalesce(
      (
        select max(usl.server_time)
        from public.unit_status_log usl
        where usl.event_id=area_rec.event_id
          and usl.incident_id=i.id
          and usl.unit_id=u.id
          and usl.new_status='TRANSPORTING'
      ),
      iu.assigned_at
    ) as transport_started_at,
    e.id,
    e.current_status,
    e.operational_note
  from public.units u
  join public.incident_units iu
    on iu.unit_id=u.id
   and iu.cleared_at is null
  join public.incidents i
    on i.id=iu.incident_id
   and i.event_id=area_rec.event_id
   and i.status='OPEN'
  left join lateral(
    select x.id,x.current_status,x.current_treatment_area_id,x.operational_note
    from public.ems_encounters x
    where x.event_id=area_rec.event_id
      and x.incident_id=i.id
      and x.current_status<>'CLOSED'
    order by x.created_at
    limit 1
  ) e on true
  where u.event_id=area_rec.event_id
    and u.active=true
    and u.status='TRANSPORTING'
    and u.current_transport_treatment_area_id=area_rec.id
    and not (
      e.id is not null
      and e.current_treatment_area_id=area_rec.id
      and e.current_status='IN_TREATMENT'
    )
  order by transport_started_at nulls last,i.incident_number;
end;
$$;

revoke all on function public.treatment_inbound_patients(uuid) from public;
grant execute on function public.treatment_inbound_patients(uuid) to authenticated;

-- ============================================================
-- TREATMENT STATION MAY COMPLETE THE SAME ARRIVAL/HANDOFF
-- ============================================================

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
  elsif treatment_area_id_value is not null
        and private.current_treatment_area()=treatment_area_id_value then
    actor_kind_value:='treatment';
  else
    raise exception 'Not authorized to complete this treatment-area arrival';
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

-- ============================================================
-- REALTIME
-- ============================================================
-- events is already added by v0.12.0. Add units defensively because inbound
-- state appears as soon as a unit becomes TRANSPORTING to this Treatment Area.

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='units'
  ) then
    alter publication supabase_realtime add table public.units;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='events'
  ) then
    alter publication supabase_realtime add table public.events;
  end if;
end $$;

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


-- CommCenter Pro v0.13.2
-- Editable Unit and EMS Treatment Area details.
--
-- Adds guarded Event Admin RPCs for changing resource configuration without
-- deleting/recreating the resource and losing historical references.

-- ============================================================
-- UNIT DETAILS
-- ============================================================

create or replace function public.admin_update_unit_details(
  p_unit_id uuid,
  p_name text,
  p_department_id uuid,
  p_home_landmark text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  u public.units;
  new_name text;
  new_home text;
begin
  select * into u
  from public.units
  where id=p_unit_id
  for update;

  if u.id is null then
    raise exception 'Unit not found';
  end if;

  if not public.can_admin_event(u.event_id) then
    raise exception 'Event Admin access required';
  end if;

  if u.active=false then
    raise exception 'Restore this unit before editing it';
  end if;

  new_name:=nullif(trim(coalesce(p_name,'')),'');
  new_home:=nullif(trim(coalesce(p_home_landmark,'')),'');

  if new_name is null then
    raise exception 'Unit name is required';
  end if;

  if not exists(
    select 1
    from public.event_departments d
    where d.id=p_department_id
      and d.event_id=u.event_id
      and d.active=true
  ) then
    raise exception 'Choose an active department from this event';
  end if;

  if exists(
    select 1
    from public.units other
    where other.event_id=u.event_id
      and lower(other.name)=lower(new_name)
      and other.id<>u.id
  ) then
    raise exception 'Another unit already uses that name';
  end if;

  -- Renaming or changing the home/staging location is harmless while a unit is
  -- operating. Changing departments is not: department changes affect scope,
  -- Field status profiles, EMS/Guest Logistics visibility, and command boards.
  if p_department_id<>u.department_id then
    if exists(
      select 1
      from public.field_sessions fs
      where fs.unit_id=u.id
        and fs.active=true
    ) then
      raise exception 'Unit has an active Field session. End the Field session before changing departments.';
    end if;

    if exists(
      select 1
      from public.incident_units iu
      join public.incidents i on i.id=iu.incident_id
      where iu.unit_id=u.id
        and iu.cleared_at is null
        and i.status='OPEN'
    ) then
      raise exception 'Unit is assigned to an active CAD incident. Clear the unit before changing departments.';
    end if;

    if exists(
      select 1
      from public.ems_encounters e
      where e.current_unit_id=u.id
        and e.current_status<>'CLOSED'
    ) then
      raise exception 'Unit currently has active EMS patient custody. Resolve the EMS encounter before changing departments.';
    end if;

    if exists(
      select 1
      from public.guest_logistics_movements m
      where m.assigned_unit_id=u.id
        and m.status not in ('COMPLETE','NO_SHOW','CANCELLED')
    ) then
      raise exception 'Unit has an open Guest Logistics movement. Complete, cancel, or reassign it before changing departments.';
    end if;
  end if;

  update public.units
  set
    name=new_name,
    department_id=p_department_id,
    home_landmark=new_home
  where id=u.id;

  insert into public.cad_activity(
    event_id,
    unit_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    u.event_id,
    u.id,
    'UNIT_DETAILS_UPDATED',
    jsonb_build_object(
      'previous_name',u.name,
      'new_name',new_name,
      'previous_department_id',u.department_id,
      'new_department_id',p_department_id,
      'previous_home_landmark',u.home_landmark,
      'new_home_landmark',new_home
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

revoke all on function public.admin_update_unit_details(uuid,text,uuid,text) from public;
grant execute on function public.admin_update_unit_details(uuid,text,uuid,text) to authenticated;

-- ============================================================
-- TREATMENT AREA DETAILS
-- ============================================================

create or replace function public.admin_update_treatment_area_details(
  p_treatment_area_id uuid,
  p_name text,
  p_capacity integer,
  p_department_id uuid default null,
  p_poi_id uuid default null,
  p_notes text default null,
  p_status text default null,
  p_accepting_patients boolean default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  a public.ems_treatment_areas;
  new_name text;
  new_notes text;
  new_status text;
  new_accepting boolean;
  census_count integer:=0;
begin
  select * into a
  from public.ems_treatment_areas
  where id=p_treatment_area_id
  for update;

  if a.id is null then
    raise exception 'Treatment Area not found';
  end if;

  if not public.can_admin_event(a.event_id) then
    raise exception 'Event Admin access required';
  end if;

  if a.active=false then
    raise exception 'Restore this Treatment Area before editing it';
  end if;

  new_name:=nullif(trim(coalesce(p_name,'')),'');
  new_notes:=nullif(trim(coalesce(p_notes,'')),'');
  new_status:=upper(trim(coalesce(p_status,a.status)));
  new_accepting:=coalesce(p_accepting_patients,a.accepting_patients);

  if new_name is null then
    raise exception 'Treatment Area name is required';
  end if;

  if p_capacity is null or p_capacity<1 then
    raise exception 'Treatment Area capacity must be at least 1';
  end if;

  if new_status not in ('OPEN','LIMITED','FULL','CLOSED') then
    raise exception 'Invalid Treatment Area status';
  end if;

  if exists(
    select 1
    from public.ems_treatment_areas other
    where other.event_id=a.event_id
      and lower(other.name)=lower(new_name)
      and other.id<>a.id
  ) then
    raise exception 'Another Treatment Area already uses that name';
  end if;

  if p_department_id is not null and not exists(
    select 1
    from public.event_departments d
    where d.id=p_department_id
      and d.event_id=a.event_id
      and d.active=true
  ) then
    raise exception 'Choose an active department from this event';
  end if;

  if p_poi_id is not null and not exists(
    select 1
    from public.event_pois p
    where p.id=p_poi_id
      and p.event_id=a.event_id
      and p.active=true
  ) then
    raise exception 'Choose an active POI from this event';
  end if;

  select count(*)::integer
  into census_count
  from public.ems_encounters e
  where e.current_treatment_area_id=a.id
    and e.current_status<>'CLOSED';

  if p_capacity<census_count then
    raise exception 'Capacity cannot be lower than the current census of %',census_count;
  end if;

  -- Department changes affect dispatcher scope and Treatment Area access. Do
  -- not move an operational station between departments while it has active
  -- patient flow or an active station session.
  if p_department_id is distinct from a.department_id then
    if census_count>0 then
      raise exception 'Treatment Area currently has patients in census. Clear the census before changing departments.';
    end if;

    if exists(
      select 1
      from public.units u
      where u.event_id=a.event_id
        and u.active=true
        and u.status='TRANSPORTING'
        and u.current_transport_treatment_area_id=a.id
    ) then
      raise exception 'Treatment Area currently has inbound patients. Complete or redirect those transports before changing departments.';
    end if;

    if exists(
      select 1
      from public.ems_handoffs h
      where h.event_id=a.event_id
        and h.to_treatment_area_id=a.id
        and h.status='PENDING'
    ) then
      raise exception 'Treatment Area has a pending EMS handoff. Resolve it before changing departments.';
    end if;

    if exists(
      select 1
      from public.treatment_area_sessions ts
      where ts.treatment_area_id=a.id
        and ts.active=true
    ) then
      raise exception 'Treatment Area Station is currently signed in. End the station session before changing departments.';
    end if;
  end if;

  if new_status='CLOSED' then
    new_accepting:=false;
  end if;

  update public.ems_treatment_areas
  set
    name=new_name,
    capacity=p_capacity,
    department_id=p_department_id,
    poi_id=p_poi_id,
    notes=new_notes,
    status=new_status,
    accepting_patients=new_accepting
  where id=a.id;

  insert into public.cad_activity(
    event_id,
    action,
    detail,
    actor_user_id,
    actor_kind
  ) values(
    a.event_id,
    'TREATMENT_AREA_DETAILS_UPDATED',
    jsonb_build_object(
      'treatment_area_id',a.id,
      'previous_name',a.name,
      'new_name',new_name,
      'previous_capacity',a.capacity,
      'new_capacity',p_capacity,
      'previous_department_id',a.department_id,
      'new_department_id',p_department_id,
      'previous_poi_id',a.poi_id,
      'new_poi_id',p_poi_id,
      'previous_status',a.status,
      'new_status',new_status,
      'previous_accepting_patients',a.accepting_patients,
      'new_accepting_patients',new_accepting
    ),
    auth.uid(),
    'staff'
  );
end;
$$;

revoke all on function public.admin_update_treatment_area_details(uuid,text,integer,uuid,uuid,text,text,boolean) from public;
grant execute on function public.admin_update_treatment_area_details(uuid,text,integer,uuid,uuid,text,text,boolean) to authenticated;

-- ============================================================
-- EVENT SLUG COLLISION HOTFIX
-- ============================================================
-- Archived events retain their history and therefore retain their slug. Reusing
-- a visible event name must not fail simply because an older/archived event has
-- the same name. Generate a deterministic collision-safe internal slug while
-- preserving the user-facing event name and globally unique Event ID.

create or replace function public.create_event_v2(
  p_organization_id uuid,
  p_name text,
  p_event_code text,
  p_pin text,
  p_operational_period_name text,
  p_incident_prefix text
)
returns uuid
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  eid uuid;
  base_slug text;
  slug text;
  suffix_slug text;
  slug_counter integer:=2;
  period_name_value text;
  prefix_value text;
  event_code_value text;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'Organization admin access required';
  end if;

  if trim(p_name)='' then
    raise exception 'Event name is required';
  end if;

  if trim(p_event_code)='' then
    raise exception 'Event ID is required';
  end if;

  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'Field PIN must be exactly 4 digits';
  end if;

  event_code_value:=upper(trim(p_event_code));
  period_name_value:=coalesce(
    nullif(trim(p_operational_period_name),''),
    'Operational Period 1'
  );
  prefix_value:=upper(trim(coalesce(p_incident_prefix,'')));

  if prefix_value='' then
    raise exception 'Operational Period incident prefix is required';
  end if;

  if prefix_value ~ '\s' then
    raise exception 'Incident prefix cannot contain spaces';
  end if;

  base_slug:=trim(
    both '-'
    from regexp_replace(lower(trim(p_name)),'[^a-z0-9]+','-','g')
  );

  if base_slug='' then
    base_slug:='event';
  end if;

  slug:=base_slug;

  if exists(
    select 1
    from public.events e
    where e.organization_id=p_organization_id
      and e.slug=slug
  ) then
    suffix_slug:=trim(
      both '-'
      from regexp_replace(lower(event_code_value),'[^a-z0-9]+','-','g')
    );

    if suffix_slug='' then
      suffix_slug:='event';
    end if;

    slug:=base_slug||'-'||suffix_slug;

    while exists(
      select 1
      from public.events e
      where e.organization_id=p_organization_id
        and e.slug=slug
    ) loop
      slug:=base_slug||'-'||suffix_slug||'-'||slug_counter::text;
      slug_counter:=slug_counter+1;
    end loop;
  end if;

  insert into public.events(
    organization_id,
    name,
    slug,
    event_code,
    field_pin_hash,
    field_access_enabled,
    incident_prefix,
    next_incident_number
  ) values(
    p_organization_id,
    trim(p_name),
    slug,
    event_code_value,
    crypt(p_pin,gen_salt('bf')),
    true,
    prefix_value,
    1
  )
  returning id into eid;

  insert into public.operational_periods(
    event_id,
    name,
    incident_prefix,
    next_incident_number,
    status,
    activated_at,
    created_by
  ) values(
    eid,
    period_name_value,
    prefix_value,
    1,
    'ACTIVE',
    now(),
    auth.uid()
  );

  return eid;
end;
$$;

revoke all on function public.create_event_v2(uuid,text,text,text,text,text) from public;
grant execute on function public.create_event_v2(uuid,text,text,text,text,text) to authenticated;


-- CommCenter Pro v0.13.4
-- Read-only Treatment Center census summary for Command Board.
--
-- The standalone Command Board intentionally does not receive EMS encounter or
-- patient-level rows. This aggregate RPC exposes only operational Treatment
-- Center status: census, capacity, inbound count, and accepting state.

create or replace function public.command_treatment_center_summary(
  p_event_id uuid
)
returns table(
  treatment_area_id uuid,
  name text,
  status text,
  capacity integer,
  accepting_patients boolean,
  census_count integer,
  inbound_count integer
)
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if not (
    public.has_event_staff_access(p_event_id)
    or private.command_has_event_access(p_event_id)
  ) then
    raise exception 'Command Board access required';
  end if;

  return query
  select
    ta.id,
    ta.name,
    ta.status,
    ta.capacity,
    ta.accepting_patients,
    coalesce(c.census_count,0)::integer,
    coalesce(ib.inbound_count,0)::integer
  from public.ems_treatment_areas ta
  left join lateral(
    select count(*)::integer as census_count
    from public.ems_encounters e
    where e.event_id=p_event_id
      and e.current_treatment_area_id=ta.id
      and e.current_status<>'CLOSED'
  ) c on true
  left join lateral(
    select count(distinct u.id)::integer as inbound_count
    from public.units u
    where u.event_id=p_event_id
      and u.active=true
      and u.status='TRANSPORTING'
      and u.current_transport_treatment_area_id=ta.id
      and exists(
        select 1
        from public.incident_units iu
        join public.incidents i on i.id=iu.incident_id
        where iu.unit_id=u.id
          and iu.cleared_at is null
          and i.event_id=p_event_id
          and i.status='OPEN'
      )
      and not exists(
        select 1
        from public.incident_units iu2
        join public.ems_encounters e2
          on e2.incident_id=iu2.incident_id
         and e2.event_id=p_event_id
         and e2.current_treatment_area_id=ta.id
         and e2.current_status='IN_TREATMENT'
        where iu2.unit_id=u.id
          and iu2.cleared_at is null
      )
  ) ib on true
  where ta.event_id=p_event_id
    and ta.active=true
  order by ta.name;
end;
$$;

revoke all on function public.command_treatment_center_summary(uuid) from public;
grant execute on function public.command_treatment_center_summary(uuid) to authenticated;
-- CommCenter Pro v0.13.5
-- Treatment Area inbound-arrival authorization hotfix.
--
-- Problem:
-- unit_arrive_treatment_area() correctly permits the destination Treatment Area
-- Station to complete an inbound arrival, but when the incident did not yet have
-- an EMS encounter it called ems_create_encounter() with the transporting unit as
-- the source. ems_create_encounter() only recognized Dispatch or the Field Unit as
-- authorized for a unit source, causing the Treatment Area UI to receive:
--   "Not authorized for this unit"
--
-- Fix:
-- 1. Permit the CURRENT destination Treatment Area Station to establish the EMS
--    encounter for a unit that is actively TRANSPORTING that exact incident to
--    that exact Treatment Area.
-- 2. Preserve the audit actor as "treatment" for that path.
-- 3. Treat an already-committed inbound transport as receivable even if the
--    Treatment Area becomes FULL / not accepting after transport began. This
--    does NOT allow new handoffs to select a closed/full/non-accepting center.

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
  current_area_id uuid;
  treatment_arrival_authorized boolean:=false;
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

    current_area_id:=private.current_treatment_area();

    if current_area_id is not null then
      select exists(
        select 1
        from public.units u
        join public.incident_units iu
          on iu.unit_id=u.id
         and iu.incident_id=p_incident_id
         and iu.cleared_at is null
        where u.id=p_source_unit_id
          and u.event_id=p_event_id
          and u.active=true
          and u.status='TRANSPORTING'
          and u.current_transport_treatment_area_id=current_area_id
      ) into treatment_arrival_authorized;
    end if;

    if not (
      public.can_dispatch_event(p_event_id)
      or public.field_has_unit_access(p_source_unit_id)
      or treatment_arrival_authorized
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
    when treatment_arrival_authorized then 'treatment'
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
      'treatment_area_id',p_source_treatment_area_id,
      'created_during_treatment_arrival',treatment_arrival_authorized
    ),
    auth.uid(),actor_kind_value
  );

  return encounter_id;
end;
$$;

revoke all on function public.ems_create_encounter(uuid,uuid,uuid,uuid,text) from public;
grant execute on function public.ems_create_encounter(uuid,uuid,uuid,uuid,text) to authenticated;


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
  already_committed_inbound boolean:=false;
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

    -- If the current EMS custodian is already physically committed as an
    -- inbound transport to this exact Treatment Area, reception must remain
    -- possible even if the center becomes FULL / not accepting after transport
    -- began. Eligibility checks still apply to every NEW destination selection.
    if e.current_unit_id is not null then
      select exists(
        select 1
        from public.units u
        where u.id=e.current_unit_id
          and u.event_id=e.event_id
          and u.active=true
          and u.status='TRANSPORTING'
          and u.current_transport_treatment_area_id=p_to_treatment_area_id
          and exists(
            select 1
            from public.incident_units iu
            where iu.incident_id=e.incident_id
              and iu.unit_id=u.id
              and iu.cleared_at is null
          )
      ) into already_committed_inbound;
    end if;

    if not already_committed_inbound then
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
    end if;

    new_status:='IN_TREATMENT';
  end if;

  old_unit:=e.current_unit_id;
  old_area:=e.current_treatment_area_id;

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
      'already_committed_inbound',already_committed_inbound,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  return 'TRANSFERRED';
end;
$$;

revoke all on function private.ems_direct_transfer(uuid,uuid,uuid,text,text) from public;

-- ============================================================
-- MIGRATION 37: TREATMENT RELEASE CLOSES INCIDENT (v0.13.6)
-- ============================================================
-- CommCenter Pro v0.13.6
-- Treatment Area patient release closes the associated CAD incident.
--
-- Problem:
-- The Treatment Area UI's "Release / Close Patient" button called
-- ems_release_encounter(). That closed EMS custody and removed the patient from
-- Treatment Area census, but intentionally left the CAD incident OPEN. The call
-- therefore remained on Dispatch / Command after the patient had completed care.
--
-- Fix:
-- When the CURRENT Treatment Area Station is the actor releasing the patient,
-- ems_release_encounter() now also closes the associated open CAD incident and
-- releases any remaining unit assignments atomically. Field-unit and Dispatch
-- uses of ems_release_encounter() retain their previous behavior.

create or replace function public.ems_release_encounter(
  p_encounter_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  i public.incidents;
  unit_rec record;
  disposition_code text;
  general_code text;
  actor_kind_value text;
  released_count integer:=0;
  other_open_ems boolean:=false;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED'
  for update;

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if public.can_dispatch_event(e.event_id) then
    actor_kind_value:='staff';
  elsif e.current_unit_id is not null
        and e.current_unit_id=private.current_field_unit() then
    actor_kind_value:='field';
  elsif e.current_treatment_area_id is not null
        and e.current_treatment_area_id=private.current_treatment_area() then
    actor_kind_value:='treatment';
  else
    raise exception 'Only the current holder can close this encounter';
  end if;

  disposition_code:=upper(trim(coalesce(p_disposition,'')));

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=e.event_id
      and d.scope='EMS'
      and d.code=disposition_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  -- Cancel any stale/pending handoff before final patient disposition.
  update public.ems_handoffs
  set
    status='CANCELLED',
    responded_at=coalesce(responded_at,now())
  where encounter_id=e.id
    and status='PENDING';

  -- Close the patient-flow record and remove it from live custody/census.
  update public.ems_encounters
  set
    current_status='CLOSED',
    current_unit_id=null,
    current_treatment_area_id=null,
    final_disposition=disposition_code,
    transport_completed_at=case
      when disposition_code='TRANSPORTED'
        and transport_started_at is not null
        then coalesce(transport_completed_at,now())
      else transport_completed_at
    end,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,
    e.incident_id,
    e.current_unit_id,
    'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object(
      'encounter_id',e.id,
      'ems_disposition',disposition_code,
      'released_from_unit_id',e.current_unit_id,
      'released_from_treatment_area_id',e.current_treatment_area_id
    ),
    auth.uid(),
    actor_kind_value
  );

  -- A field-side EMS release remains an EMS-only workflow; Dispatch can still
  -- decide how/when to close the CAD call. The Treatment Area button, however,
  -- is explicitly "Release / Close Patient", and completion of care there is
  -- the terminal event for the one-patient-per-incident treatment workflow.
  if actor_kind_value<>'treatment' or e.incident_id is null then
    return;
  end if;

  select *
  into i
  from public.incidents
  where id=e.incident_id
    and event_id=e.event_id
  for update;

  -- If Dispatch already closed the incident there is nothing further to do.
  if i.id is null or i.status='CLOSED' then
    return;
  end if;

  -- CommCenter's normal EMS model is one patient per CAD incident. Do not
  -- silently close a call if legacy/corrupt data contains a second active EMS
  -- encounter attached to the same incident.
  select exists(
    select 1
    from public.ems_encounters x
    where x.event_id=e.event_id
      and x.incident_id=e.incident_id
      and x.id<>e.id
      and x.current_status<>'CLOSED'
  ) into other_open_ems;

  if other_open_ems then
    insert into public.cad_activity(
      event_id,incident_id,action,detail,actor_user_id,actor_kind
    ) values(
      e.event_id,e.incident_id,'EMS_TREATMENT_RELEASE_CALL_LEFT_OPEN',
      jsonb_build_object(
        'encounter_id',e.id,
        'reason','ANOTHER_ACTIVE_EMS_ENCOUNTER_EXISTS'
      ),
      auth.uid(),'treatment'
    );
    return;
  end if;

  -- Prefer the standard Completed / Resolved general disposition. If an event
  -- admin disabled it, use the first remaining active GENERAL disposition so
  -- the incident can still close cleanly.
  select d.code
  into general_code
  from public.event_dispositions d
  where d.event_id=e.event_id
    and d.scope='GENERAL'
    and d.active=true
  order by
    case when d.code='COMPLETED' then 0 else 1 end,
    d.sort_order,
    d.code
  limit 1;

  general_code:=coalesce(general_code,'COMPLETED');

  -- Release any unit that somehow remains committed to the call. Normally the
  -- transporting field unit was already cleared at Treatment Area handoff, but
  -- this keeps the terminal close path safe for multi-unit incidents.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=i.id
      and iu.cleared_at is null
    for update of iu,u
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=i.id
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
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'treatment',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','PATIENT_RELEASED_FROM_TREATMENT',
        'automatic',true
      ),
      auth.uid(),'treatment'
    );

    released_count:=released_count+1;
  end loop;

  update public.incidents
  set
    status='CLOSED',
    closed_at=coalesce(closed_at,now()),
    disposition=general_code
  where id=i.id
    and status<>'CLOSED';

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_code,
      'general_disposition',general_code,
      'ems_disposition',disposition_code,
      'released_units',released_count,
      'reason','PATIENT_RELEASED_FROM_TREATMENT',
      'source','TREATMENT_AREA_RELEASE'
    ),
    auth.uid(),'treatment'
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;

-- ============================================================
-- v0.13.8 DISPATCH REALTIME STATUS HARDENING
-- ============================================================

-- CommCenter Pro v0.13.8
-- Dispatch live unit status hardening
--
-- Realtime remains the primary update path. This migration defensively verifies
-- that the tables used by Dispatch status synchronization are published to
-- Supabase Realtime and that units sends complete UPDATE row images.

alter table public.units replica identity full;

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='units'
  ) then
    alter publication supabase_realtime add table public.units;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='unit_status_log'
  ) then
    alter publication supabase_realtime add table public.unit_status_log;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='incident_units'
  ) then
    alter publication supabase_realtime add table public.incident_units;
  end if;
end $$;

grant select on public.units, public.unit_status_log, public.incident_units to authenticated;

-- ============================================================
-- v0.14.0 DISPATCH STATUS SNAPSHOT
-- ============================================================

-- CommCenter Pro v0.14.0
-- Authoritative Dispatch unit-state heartbeat.
-- Realtime remains the fast path; this guarded snapshot lets Dispatch repair
-- stale unit badges without a browser refresh even when a websocket event is
-- missed or the channel is temporarily degraded.

create index if not exists units_event_active_idx
  on public.units(event_id,active);

create or replace function public.dispatch_unit_status_snapshot(
  p_event_id uuid
)
returns table(
  id uuid,
  status text,
  current_transport_destination_text text,
  current_transport_treatment_area_id uuid,
  current_map_layer_id uuid,
  current_zone_id uuid,
  current_poi_id uuid
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
    u.id,
    u.status,
    u.current_transport_destination_text,
    u.current_transport_treatment_area_id,
    u.current_map_layer_id,
    u.current_zone_id,
    u.current_poi_id
  from public.units u
  where u.event_id=p_event_id
    and u.active=true
  order by u.name;
end;
$$;

revoke all on function public.dispatch_unit_status_snapshot(uuid) from public;
grant execute on function public.dispatch_unit_status_snapshot(uuid) to authenticated;

-- ============================================================
-- v0.14.2 DISPATCH INCIDENT SNAPSHOT
-- ============================================================

-- CommCenter Pro v0.14.2
-- Authoritative Dispatch active-incident heartbeat.
--
-- This is deliberately small: Dispatch uses it to reconcile the active-call
-- set and map markers every second without depending solely on Realtime.

create index if not exists incidents_event_status_idx
  on public.incidents(event_id,status);

create or replace function public.dispatch_active_incident_snapshot(
  p_event_id uuid
)
returns table(
  id uuid,
  incident_number text,
  status text,
  map_x double precision,
  map_y double precision,
  map_layer_id uuid,
  call_type text,
  priority text,
  landmark text,
  closed_at timestamptz
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
    i.id,
    i.incident_number,
    i.status,
    i.map_x,
    i.map_y,
    i.map_layer_id,
    i.call_type,
    i.priority,
    i.landmark,
    i.closed_at
  from public.incidents i
  where i.event_id=p_event_id
    and i.status<>'CLOSED'
  order by i.created_at desc;
end;
$$;

revoke all on function public.dispatch_active_incident_snapshot(uuid) from public;
grant execute on function public.dispatch_active_incident_snapshot(uuid) to authenticated;

