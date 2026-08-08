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
  actor_kind text not null default 'staff' check(actor_kind in ('staff','field','system')),
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
language plpgsql security definer set search_path=public
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
language plpgsql security definer set search_path=public
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

create or replace function public.assign_unit(p_incident_id uuid,p_unit_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
declare eid uuid; old_s text;
begin
  select event_id into eid from public.incidents where id=p_incident_id;
  if not public.can_dispatch_event(eid) then raise exception 'Dispatch access required'; end if;
  if not exists(select 1 from public.units where id=p_unit_id and event_id=eid) then raise exception 'Unit is not part of this event'; end if;

  select status into old_s from public.units where id=p_unit_id;
  insert into public.incident_units(incident_id,unit_id) values(p_incident_id,p_unit_id)
  on conflict(incident_id,unit_id) do update set assigned_at=now(),cleared_at=null;
  update public.units set status='ASSIGNED' where id=p_unit_id;

  insert into public.unit_status_log(event_id,incident_id,unit_id,old_status,new_status,actor_user_id,actor_kind)
  values(eid,p_incident_id,p_unit_id,old_s,'ASSIGNED',auth.uid(),'staff');
  insert into public.cad_activity(event_id,incident_id,unit_id,action,actor_user_id,actor_kind)
  values(eid,p_incident_id,p_unit_id,'UNIT_ASSIGNED',auth.uid(),'staff');
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
language plpgsql security definer set search_path=public
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

create policy "incidents read" on public.incidents for select using(
  public.has_event_staff_access(event_id) or exists(
    select 1 from public.incident_units iu
    join public.field_sessions fs on fs.unit_id=iu.unit_id
    where iu.incident_id=incidents.id and iu.cleared_at is null and fs.auth_user_id=auth.uid() and fs.active=true
  )
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
grant execute on function public.close_incident(uuid,text) to authenticated;
grant execute on function public.w3w_for_coordinate(uuid,double precision,double precision) to authenticated;
grant execute on function public.w3w_squares_in_bounds(uuid,double precision,double precision,double precision,double precision,integer) to authenticated;
grant execute on function public.field_enter_event(text,text,text) to authenticated;
grant execute on function public.field_claim_unit(uuid,uuid) to authenticated;
grant execute on function public.field_release_unit(uuid) to authenticated;
grant execute on function public.field_end_session(uuid) to authenticated;
grant execute on function public.field_set_unit_status(uuid,text,uuid,timestamptz) to authenticated;
grant select on public.dispatch_log to authenticated;
