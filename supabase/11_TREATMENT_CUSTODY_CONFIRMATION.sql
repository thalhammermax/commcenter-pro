-- CommCenter Pro v0.5.2
-- Treatment-area custody confirmation from Dispatch or Treatment Area Station.
--
-- Operational rule:
-- * The CAD incident number remains the patient reference.
-- * Dispatch can mark that an incident/patient was handed off to a treatment area.
-- * A treatment-area station can independently mark that the patient was received.
-- * Either action reconciles CURRENT custody to the treatment area.
-- * Existing pending handoff requests to that treatment area are completed.
-- * Conflicting pending handoffs are cancelled.
-- * All manual reconciliation is recorded in cad_activity.

create or replace function private.place_incident_in_treatment(
  p_incident_id uuid,
  p_treatment_area_id uuid,
  p_note text,
  p_actor_kind text
) returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  ta public.ems_treatment_areas;
  e public.ems_encounters;
  matching_handoff public.ems_handoffs;
  new_handoff_id uuid;
  old_unit uuid;
  old_area uuid;
  already_here boolean:=false;
begin
  select * into i
  from public.incidents
  where id=p_incident_id
    and status<>'CLOSED';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select * into ta
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and event_id=i.event_id
    and active=true;

  if ta.id is null then
    raise exception 'Active treatment area not found for this event';
  end if;

  select *
  into e
  from public.ems_encounters
  where event_id=i.event_id
    and incident_id=i.id
    and current_status<>'CLOSED'
  order by created_at
  limit 1;

  if e.id is null then
    insert into public.ems_encounters(
      event_id,
      incident_id,
      tracking_number,
      current_status,
      current_unit_id,
      current_treatment_area_id,
      origin_unit_id,
      operational_note,
      created_by
    ) values(
      i.event_id,
      i.id,
      i.incident_number,
      'IN_TREATMENT',
      null,
      ta.id,
      null,
      nullif(trim(p_note),''),
      auth.uid()
    )
    returning * into e;

    insert into public.cad_activity(
      event_id,incident_id,action,detail,actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,'EMS_TREATMENT_RECEIVED',
      jsonb_build_object(
        'encounter_id',e.id,
        'incident_number',i.incident_number,
        'treatment_area_id',ta.id,
        'treatment_area_name',ta.name,
        'confirmation_source',p_actor_kind,
        'created_ems_flow',true,
        'note',nullif(trim(p_note),'')
      ),
      auth.uid(),p_actor_kind
    );

    return 'RECEIVED';
  end if;

  if e.current_treatment_area_id=ta.id and e.current_status='IN_TREATMENT' then
    already_here:=true;
  end if;

  old_unit:=e.current_unit_id;
  old_area:=e.current_treatment_area_id;

  -- If the sender already requested exactly this handoff, complete that request.
  select *
  into matching_handoff
  from public.ems_handoffs h
  where h.encounter_id=e.id
    and h.status='PENDING'
    and h.to_treatment_area_id=ta.id
  order by h.requested_at
  limit 1;

  if matching_handoff.id is not null then
    update public.ems_handoffs
    set status='COMPLETED',
        responded_by=auth.uid(),
        responded_at=now(),
        completed_at=now(),
        note=coalesce(nullif(trim(p_note),''),note)
    where id=matching_handoff.id;

    new_handoff_id:=matching_handoff.id;
  elsif not already_here and (old_unit is not null or old_area is not null) then
    insert into public.ems_handoffs(
      event_id,encounter_id,
      from_unit_id,from_treatment_area_id,
      to_unit_id,to_treatment_area_id,
      status,note,
      requested_by,requested_at,
      responded_by,responded_at,completed_at
    ) values(
      i.event_id,e.id,
      old_unit,old_area,
      null,ta.id,
      'COMPLETED',nullif(trim(p_note),''),
      auth.uid(),now(),
      auth.uid(),now(),now()
    )
    returning id into new_handoff_id;
  end if;

  -- A confirmed real-world custody state supersedes other pending requests.
  update public.ems_handoffs
  set status='CANCELLED',
      responded_by=auth.uid(),
      responded_at=now(),
      note=coalesce(note,'Cancelled when treatment-area custody was confirmed')
  where encounter_id=e.id
    and status='PENDING'
    and (new_handoff_id is null or id<>new_handoff_id);

  update public.ems_encounters
  set current_unit_id=null,
      current_treatment_area_id=ta.id,
      current_status='IN_TREATMENT',
      operational_note=coalesce(nullif(trim(p_note),''),operational_note)
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,old_unit,'EMS_TREATMENT_RECEIVED',
    jsonb_build_object(
      'encounter_id',e.id,
      'incident_number',i.incident_number,
      'handoff_id',new_handoff_id,
      'from_unit_id',old_unit,
      'from_treatment_area_id',old_area,
      'treatment_area_id',ta.id,
      'treatment_area_name',ta.name,
      'confirmation_source',p_actor_kind,
      'already_here',already_here,
      'note',nullif(trim(p_note),'')
    ),
    auth.uid(),p_actor_kind
  );

  if already_here then
    return 'ALREADY_HERE';
  end if;

  return 'RECEIVED';
end;
$$;

revoke all on function private.place_incident_in_treatment(uuid,uuid,text,text) from public;

create or replace function public.ems_dispatch_mark_treatment_handoff(
  p_incident_id uuid,
  p_treatment_area_id uuid,
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

  return private.place_incident_in_treatment(
    p_incident_id,
    p_treatment_area_id,
    p_note,
    'staff'
  );
end;
$$;

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

  return private.place_incident_in_treatment(
    p_incident_id,
    p_treatment_area_id,
    p_note,
    'treatment'
  );
end;
$$;

create or replace function public.treatment_search_open_incidents(
  p_treatment_area_id uuid,
  p_query text default null
) returns table(
  incident_id uuid,
  incident_number text,
  call_type text,
  priority text,
  landmark text,
  created_at timestamptz,
  current_ems_status text,
  current_treatment_area_id uuid
)
language sql
stable
security definer
set search_path=public
as $$
  select
    i.id,
    i.incident_number,
    i.call_type,
    i.priority,
    i.landmark,
    i.created_at,
    e.current_status,
    e.current_treatment_area_id
  from public.ems_treatment_areas ta
  join public.incidents i
    on i.event_id=ta.event_id
   and i.status<>'CLOSED'
  left join lateral (
    select ee.current_status,ee.current_treatment_area_id
    from public.ems_encounters ee
    where ee.event_id=i.event_id
      and ee.incident_id=i.id
      and ee.current_status<>'CLOSED'
    order by ee.created_at
    limit 1
  ) e on true
  where ta.id=p_treatment_area_id
    and ta.active=true
    and private.current_treatment_area()=ta.id
    and (
      trim(coalesce(p_query,''))=''
      or i.incident_number ilike '%'||trim(p_query)||'%'
      or i.call_type ilike '%'||trim(p_query)||'%'
      or coalesce(i.landmark,'') ilike '%'||trim(p_query)||'%'
    )
  order by i.created_at desc
  limit 15;
$$;

grant execute on function public.ems_dispatch_mark_treatment_handoff(uuid,uuid,text) to authenticated;
grant execute on function public.treatment_receive_incident(uuid,uuid,text) to authenticated;
grant execute on function public.treatment_search_open_incidents(uuid,text) to authenticated;
