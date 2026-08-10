-- CommCenter Pro v0.13.0
-- Treatment Area Inbound Board + event-wide Treatment Area Layout Builder.
--
-- 1. A patient becomes INBOUND when an assigned non-ambulance Field unit is
--    TRANSPORTING to a configured Treatment Area.
-- 2. Inbound is derived from live unit transport state and is not counted in
--    Treatment Area census until custody is actually handed off.
-- 3. Treatment Area, Dispatch, or the transporting Field unit can complete the
--    same arrival/handoff workflow. Once complete, the unit clears and the
--    patient moves from INBOUND to the Treatment Area census through Realtime.
-- 4. Each event receives one global treatment_layout_config used by every
--    Treatment Area Station in that event.

-- ============================================================
-- EVENT-WIDE TREATMENT AREA LAYOUT CONFIGURATION
-- ============================================================

alter table public.events
  add column if not exists treatment_layout_config jsonb not null default
  '{
    "version":1,
    "blocks":[
      {"id":"station_summary","enabled":true},
      {"id":"inbound_patients","enabled":true},
      {"id":"census","enabled":true},
      {"id":"station_status","enabled":true},
      {"id":"walkin","enabled":true},
      {"id":"receive_existing","enabled":true},
      {"id":"report_qr","enabled":true},
      {"id":"session_controls","enabled":true}
    ]
  }'::jsonb;

create or replace function public.admin_save_treatment_layout(
  p_event_id uuid,
  p_layout jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  blocks jsonb;
  item jsonb;
  block_id text;
  seen text[]:=array[]::text[];
  normalized jsonb:='[]'::jsonb;
  required_id text;
  allowed_ids constant text[]:=array[
    'station_summary',
    'inbound_patients',
    'census',
    'station_status',
    'walkin',
    'receive_existing',
    'report_qr',
    'session_controls'
  ];
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  if jsonb_typeof(p_layout)<>'object' then
    raise exception 'Treatment layout must be a JSON object';
  end if;

  blocks:=p_layout->'blocks';
  if jsonb_typeof(blocks)<>'array' then
    raise exception 'Treatment layout blocks must be an array';
  end if;

  for item in select value from jsonb_array_elements(blocks)
  loop
    block_id:=nullif(trim(item->>'id'),'');

    if block_id is null or not (block_id=any(allowed_ids)) then
      raise exception 'Unknown Treatment layout block: %',coalesce(block_id,'(blank)');
    end if;

    if block_id=any(seen) then
      raise exception 'Duplicate Treatment layout block: %',block_id;
    end if;

    seen:=array_append(seen,block_id);
    normalized:=normalized||jsonb_build_array(
      jsonb_build_object(
        'id',block_id,
        'enabled',case
          when block_id in ('station_summary','inbound_patients','census','session_controls') then true
          else coalesce((item->>'enabled')::boolean,true)
        end
      )
    );
  end loop;

  foreach required_id in array array['station_summary','inbound_patients','census','session_controls']
  loop
    if not required_id=any(seen) then
      raise exception 'Required Treatment layout block is missing: %',required_id;
    end if;
  end loop;

  foreach block_id in array allowed_ids
  loop
    if not block_id=any(seen) then
      normalized:=normalized||jsonb_build_array(
        jsonb_build_object('id',block_id,'enabled',true)
      );
    end if;
  end loop;

  p_layout:=jsonb_build_object('version',1,'blocks',normalized);

  update public.events
  set treatment_layout_config=p_layout
  where id=p_event_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    'TREATMENT_LAYOUT_UPDATED',
    jsonb_build_object('layout',p_layout),
    auth.uid(),
    'staff'
  );

  return p_layout;
end;
$$;

revoke all on function public.admin_save_treatment_layout(uuid,jsonb) from public;
grant execute on function public.admin_save_treatment_layout(uuid,jsonb) to authenticated;

-- ============================================================
-- TREATMENT AREA INBOUND PATIENTS
-- ============================================================

create or replace function public.treatment_inbound_patients(
  p_treatment_area_id uuid
)
returns table(
  event_id uuid,
  treatment_area_id uuid,
  incident_id uuid,
  incident_number text,
  call_type text,
  priority text,
  landmark text,
  unit_id uuid,
  unit_name text,
  transport_started_at timestamptz,
  encounter_id uuid,
  current_ems_status text,
  operational_note text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  area_rec public.ems_treatment_areas;
begin
  select * into area_rec
  from public.ems_treatment_areas
  where id=p_treatment_area_id
    and active=true;

  if area_rec.id is null then
    raise exception 'Active Treatment Area not found';
  end if;

  if not (
    private.current_treatment_area()=area_rec.id
    or public.can_dispatch_event(area_rec.event_id)
  ) then
    raise exception 'Treatment Area access required';
  end if;

  return query
  select
    area_rec.event_id,
    area_rec.id,
    i.id,
    i.incident_number,
    i.call_type,
    i.priority,
    i.landmark,
    u.id,
    u.name,
    coalesce(
      (
        select max(usl.server_time)
        from public.unit_status_log usl
        where usl.event_id=area_rec.event_id
          and usl.incident_id=i.id
          and usl.unit_id=u.id
          and usl.new_status='TRANSPORTING'
      ),
      iu.assigned_at
    ) as transport_started_at,
    e.id,
    e.current_status,
    e.operational_note
  from public.units u
  join public.incident_units iu
    on iu.unit_id=u.id
   and iu.cleared_at is null
  join public.incidents i
    on i.id=iu.incident_id
   and i.event_id=area_rec.event_id
   and i.status='OPEN'
  left join lateral(
    select x.id,x.current_status,x.current_treatment_area_id,x.operational_note
    from public.ems_encounters x
    where x.event_id=area_rec.event_id
      and x.incident_id=i.id
      and x.current_status<>'CLOSED'
    order by x.created_at
    limit 1
  ) e on true
  where u.event_id=area_rec.event_id
    and u.active=true
    and u.status='TRANSPORTING'
    and u.current_transport_treatment_area_id=area_rec.id
    and not (
      e.id is not null
      and e.current_treatment_area_id=area_rec.id
      and e.current_status='IN_TREATMENT'
    )
  order by transport_started_at nulls last,i.incident_number;
end;
$$;

revoke all on function public.treatment_inbound_patients(uuid) from public;
grant execute on function public.treatment_inbound_patients(uuid) to authenticated;

-- ============================================================
-- TREATMENT STATION MAY COMPLETE THE SAME ARRIVAL/HANDOFF
-- ============================================================

create or replace function public.unit_arrive_treatment_area(
  p_unit_id uuid,
  p_incident_id uuid
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  eid uuid;
  unit_status_value text;
  treatment_area_id_value uuid;
  treatment_area_name_value text;
  encounter_id_value uuid;
  actor_kind_value text;
  still_assigned boolean;
  old_status_value text;
begin
  select
    u.event_id,
    u.status,
    u.current_transport_treatment_area_id
  into
    eid,
    unit_status_value,
    treatment_area_id_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active unit not found';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  elsif treatment_area_id_value is not null
        and private.current_treatment_area()=treatment_area_id_value then
    actor_kind_value:='treatment';
  else
    raise exception 'Not authorized to complete this treatment-area arrival';
  end if;

  if unit_status_value<>'TRANSPORTING' then
    raise exception 'Unit must be TRANSPORTING before it can arrive at a treatment area';
  end if;

  if treatment_area_id_value is null then
    raise exception 'This unit does not have a treatment-area transport destination';
  end if;

  if not exists(
    select 1
    from public.incident_units iu
    join public.incidents i on i.id=iu.incident_id
    where iu.incident_id=p_incident_id
      and iu.unit_id=p_unit_id
      and iu.cleared_at is null
      and i.event_id=eid
      and i.status='OPEN'
  ) then
    raise exception 'Unit is not actively committed to that incident';
  end if;

  select a.name
  into treatment_area_name_value
  from public.ems_treatment_areas a
  where a.id=treatment_area_id_value
    and a.event_id=eid
    and a.active=true;

  if treatment_area_name_value is null then
    raise exception 'Treatment-area destination is no longer active';
  end if;

  -- If the incident has no EMS custody row yet, establish this transporting
  -- unit as the current patient custodian first. ems_create_encounter() returns
  -- the existing open encounter when one already exists.
  select public.ems_create_encounter(
    eid,
    p_incident_id,
    p_unit_id,
    null,
    null
  )
  into encounter_id_value;

  -- Use the same direct-custody transfer primitive as the incident-level
  -- Handoff / Custody workflow. This updates EMS custody, the transfer ledger,
  -- treatment-area census, CAD assignment, and unit status atomically.
  perform private.ems_direct_transfer(
    encounter_id_value,
    null,
    treatment_area_id_value,
    'Arrived at treatment area',
    actor_kind_value
  );

  -- In the normal path, ems_direct_transfer clears p_unit_id because it was the
  -- current EMS custodian. If an older/reconciled encounter had a different
  -- current custodian, make sure the transporting unit is still cleared too.
  select exists(
    select 1
    from public.incident_units
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null
  )
  into still_assigned;

  if still_assigned then
    select status
    into old_status_value
    from public.units
    where id=p_unit_id;

    update public.incident_units
    set cleared_at=now()
    where incident_id=p_incident_id
      and unit_id=p_unit_id
      and cleared_at is null;

    update public.units
    set
      status='AVAILABLE',
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=p_unit_id;

    if old_status_value is distinct from 'AVAILABLE' then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        eid,p_incident_id,p_unit_id,
        old_status_value,'AVAILABLE',
        auth.uid(),actor_kind_value,
        null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,p_unit_id,
      'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason','ARRIVED_TREATMENT_AREA',
        'treatment_area_id',treatment_area_id_value,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );
  end if;

  -- The helper normally clears these fields along with the unit assignment;
  -- explicitly clear them here as a final state guarantee.
  update public.units
  set
    status='AVAILABLE',
    current_transport_destination_text=null,
    current_transport_treatment_area_id=null
  where id=p_unit_id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    'UNIT_ARRIVED_TREATMENT_AREA',
    jsonb_build_object(
      'treatment_area_id',treatment_area_id_value,
      'treatment_area_name',treatment_area_name_value,
      'encounter_id',encounter_id_value,
      'patient_custody_transferred',true
    ),
    auth.uid(),actor_kind_value
  );

  return treatment_area_name_value;
end;
$$;

revoke all on function public.unit_arrive_treatment_area(uuid,uuid) from public;
grant execute on function public.unit_arrive_treatment_area(uuid,uuid) to authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
-- events is already added by v0.12.0. Add units defensively because inbound
-- state appears as soon as a unit becomes TRANSPORTING to this Treatment Area.

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='units'
  ) then
    alter publication supabase_realtime add table public.units;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='events'
  ) then
    alter publication supabase_realtime add table public.events;
  end if;
end $$;
