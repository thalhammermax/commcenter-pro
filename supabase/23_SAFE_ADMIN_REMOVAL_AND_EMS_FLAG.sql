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
