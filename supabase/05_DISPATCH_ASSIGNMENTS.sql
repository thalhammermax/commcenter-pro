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

grant execute on function public.assign_unit(uuid,uuid) to authenticated;
grant execute on function public.unassign_unit(uuid,uuid,text) to authenticated;
grant execute on function public.staff_set_unit_status(uuid,text,uuid) to authenticated;
