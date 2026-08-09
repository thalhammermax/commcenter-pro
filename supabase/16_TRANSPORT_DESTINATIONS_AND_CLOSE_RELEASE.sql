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
