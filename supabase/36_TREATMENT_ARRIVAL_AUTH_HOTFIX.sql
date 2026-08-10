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
