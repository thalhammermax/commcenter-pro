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
