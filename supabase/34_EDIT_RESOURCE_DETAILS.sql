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
