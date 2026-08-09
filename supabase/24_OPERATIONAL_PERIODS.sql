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
