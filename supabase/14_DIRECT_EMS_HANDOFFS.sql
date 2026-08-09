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
