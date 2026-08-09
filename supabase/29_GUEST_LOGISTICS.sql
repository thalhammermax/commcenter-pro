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
