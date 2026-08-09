-- CommCenter Pro v0.9.4
-- 24-hour time display is a frontend concern; this migration adds standardized
-- event disposition catalogs and structured CAD / EMS close workflows.

-- ============================================================
-- DISPOSITION CATALOG
-- ============================================================

create table if not exists public.event_dispositions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  scope text not null check(scope in ('GENERAL','EMS')),
  code text not null,
  label text not null,
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  unique(event_id,scope,code)
);

create index if not exists event_dispositions_event_scope_idx
  on public.event_dispositions(event_id,scope,active,sort_order,label);

alter table public.event_dispositions enable row level security;

drop policy if exists event_dispositions_read on public.event_dispositions;
create policy event_dispositions_read
on public.event_dispositions
for select
to authenticated
using (
  public.has_event_staff_access(event_id)
  or public.field_has_event_access(event_id)
  or private.treatment_has_event_access(event_id)
);

drop policy if exists event_dispositions_admin_insert on public.event_dispositions;
create policy event_dispositions_admin_insert
on public.event_dispositions
for insert
to authenticated
with check(public.can_admin_event(event_id));

drop policy if exists event_dispositions_admin_update on public.event_dispositions;
create policy event_dispositions_admin_update
on public.event_dispositions
for update
to authenticated
using(public.can_admin_event(event_id))
with check(public.can_admin_event(event_id));

drop policy if exists event_dispositions_admin_delete on public.event_dispositions;
create policy event_dispositions_admin_delete
on public.event_dispositions
for delete
to authenticated
using(public.can_admin_event(event_id));

grant select,insert,update,delete on public.event_dispositions to authenticated;

-- ============================================================
-- DEFAULT DISPOSITIONS
-- ============================================================

create or replace function public.seed_default_event_dispositions(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.event_dispositions(event_id,scope,code,label,sort_order)
  values
    (p_event_id,'GENERAL','COMPLETED','Completed / Resolved',10),
    (p_event_id,'GENERAL','CANCELLED','Cancelled',20),
    (p_event_id,'GENERAL','NO_ACTION_REQUIRED','No Action Required',30),
    (p_event_id,'GENERAL','UNFOUNDED','Unfounded / No Incident Found',40),
    (p_event_id,'GENERAL','REFERRED','Referred / Turned Over',50),
    (p_event_id,'GENERAL','DUPLICATE','Duplicate Call',60),
    (p_event_id,'GENERAL','STANDBY_COMPLETE','Standby Complete',70),
    (p_event_id,'GENERAL','OTHER','Other',90),

    (p_event_id,'EMS','TREATED_RELEASED','Treated / Released',10),
    (p_event_id,'EMS','REFUSAL','Patient Refusal',20),
    (p_event_id,'EMS','NO_PATIENT','No Patient Found',30),
    (p_event_id,'EMS','NO_TREATMENT_REQUIRED','No Treatment Required',40),
    (p_event_id,'EMS','TRANSFERRED_TO_TREATMENT','Transferred to Treatment Area',50),
    (p_event_id,'EMS','TRANSPORTED','Transported by Event Ambulance',60),
    (p_event_id,'EMS','TRANSPORTED_OUTSIDE','Transported by Outside Ambulance',70),
    (p_event_id,'EMS','RELEASED_FROM_TREATMENT','Released from Treatment Area',80),
    (p_event_id,'EMS','LEFT_BEFORE_EVALUATION','Left Before Evaluation / Completion',90),
    (p_event_id,'EMS','TRANSFERRED_TO_OTHER_PROVIDER','Transferred to Other Provider',100),
    (p_event_id,'EMS','DECEASED','Deceased',110),
    (p_event_id,'EMS','OTHER','Other EMS Disposition',120)
  on conflict(event_id,scope,code) do nothing;
end;
$$;

revoke all on function public.seed_default_event_dispositions(uuid) from public;

-- Backfill every current event.
do $$
declare
  event_rec record;
begin
  for event_rec in select id from public.events loop
    perform public.seed_default_event_dispositions(event_rec.id);
  end loop;
end $$;

-- Automatically seed future events.
create or replace function private.seed_event_dispositions_after_insert()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.seed_default_event_dispositions(new.id);
  return new;
end;
$$;

drop trigger if exists seed_event_dispositions_after_insert on public.events;
create trigger seed_event_dispositions_after_insert
after insert on public.events
for each row
execute function private.seed_event_dispositions_after_insert();

-- ============================================================
-- STRUCTURED INCIDENT CLOSE
-- ============================================================

create or replace function public.close_incident_v2(
  p_incident_id uuid,
  p_disposition text,
  p_ems_disposition text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  i public.incidents;
  unit_rec record;
  released_count integer:=0;
  ems_context boolean:=false;
  general_code text;
  ems_code text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id
    and status='OPEN';

  if i.id is null then
    raise exception 'Open incident not found';
  end if;

  if not public.can_dispatch_event(i.event_id) then
    raise exception 'Dispatch access required';
  end if;

  general_code:=upper(trim(coalesce(p_disposition,'')));
  ems_code:=nullif(upper(trim(coalesce(p_ems_disposition,''))),'');

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=i.event_id
      and d.scope='GENERAL'
      and d.code=general_code
      and d.active=true
  ) then
    raise exception 'Choose a valid general disposition';
  end if;

  select (
    exists(
      select 1
      from public.incident_departments idept
      join public.event_departments dept on dept.id=idept.department_id
      where idept.incident_id=i.id
        and dept.active=true
        and dept.ems_enabled=true
    )
    or exists(
      select 1
      from public.ems_encounters e
      where e.incident_id=i.id
        and e.event_id=i.event_id
    )
  )
  into ems_context;

  if ems_context and ems_code is null then
    raise exception 'Choose an EMS patient disposition';
  end if;

  if ems_code is not null and not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=i.event_id
      and d.scope='EMS'
      and d.code=ems_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  -- Do not allow the generic close workflow to bypass the transport-outcome
  -- confirmation for an event ambulance that is actively transporting.
  if exists(
    select 1
    from public.ems_encounters e
    join public.ems_unit_config c on c.unit_id=e.current_unit_id
    where e.incident_id=i.id
      and e.event_id=i.event_id
      and e.current_status='TRANSPORTING'
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'An event ambulance is actively transporting this patient. Complete the Delivered / Refusal transport outcome before closing the call.';
  end if;

  -- Apply the final EMS disposition to the incident's EMS encounter record(s).
  -- An EMS flow may have been closed by the field/treatment user before Dispatch
  -- closes the CAD incident, so preserve its original close time while storing
  -- the final selected disposition consistently.
  if ems_code is not null then
    update public.ems_encounters
    set
      current_status='CLOSED',
      final_disposition=ems_code,
      transport_completed_at=case
        when ems_code='TRANSPORTED'
          and transport_started_at is not null
          then coalesce(transport_completed_at,now())
        else transport_completed_at
      end,
      closed_at=coalesce(closed_at,now())
    where incident_id=i.id
      and event_id=i.event_id;
  end if;

  -- Release every unit still committed to the incident.
  for unit_rec in
    select u.id as unit_id,u.status
    from public.incident_units iu
    join public.units u on u.id=iu.unit_id
    where iu.incident_id=i.id
      and iu.cleared_at is null
  loop
    update public.incident_units
    set cleared_at=now()
    where incident_id=i.id
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
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,'AVAILABLE',
        auth.uid(),'staff',null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
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
    disposition=general_code
  where id=i.id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,actor_user_id,actor_kind
  ) values(
    i.event_id,i.id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_code,
      'general_disposition',general_code,
      'ems_disposition',ems_code,
      'released_units',released_count
    ),
    auth.uid(),'staff'
  );
end;
$$;

revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;

-- ============================================================
-- STANDARDIZED EMS RELEASE
-- ============================================================

create or replace function public.ems_release_encounter(
  p_encounter_id uuid,
  p_disposition text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  disposition_code text;
begin
  select *
  into e
  from public.ems_encounters
  where id=p_encounter_id
    and current_status<>'CLOSED';

  if e.id is null then
    raise exception 'Active EMS encounter not found';
  end if;

  if not (
    public.can_dispatch_event(e.event_id)
    or e.current_unit_id=private.current_field_unit()
    or e.current_treatment_area_id=private.current_treatment_area()
  ) then
    raise exception 'Only the current holder can close this encounter';
  end if;

  disposition_code:=upper(trim(coalesce(p_disposition,'')));

  if not exists(
    select 1
    from public.event_dispositions d
    where d.event_id=e.event_id
      and d.scope='EMS'
      and d.code=disposition_code
      and d.active=true
  ) then
    raise exception 'Choose a valid EMS patient disposition';
  end if;

  update public.ems_handoffs
  set status='CANCELLED',responded_at=now()
  where encounter_id=e.id
    and status='PENDING';

  update public.ems_encounters
  set
    current_status='CLOSED',
    final_disposition=disposition_code,
    transport_completed_at=case
      when disposition_code='TRANSPORTED'
        and transport_started_at is not null
        then coalesce(transport_completed_at,now())
      else transport_completed_at
    end,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.event_id,
    e.incident_id,
    e.current_unit_id,
    'EMS_ENCOUNTER_CLOSED',
    jsonb_build_object(
      'encounter_id',e.id,
      'ems_disposition',disposition_code
    ),
    auth.uid(),
    case
      when public.can_dispatch_event(e.event_id) then 'staff'
      when e.current_treatment_area_id=private.current_treatment_area() then 'treatment'
      else 'field'
    end
  );
end;
$$;

revoke all on function public.ems_release_encounter(uuid,text) from public;
grant execute on function public.ems_release_encounter(uuid,text) to authenticated;

-- ============================================================
-- AMBULANCE OUTCOME NOW STORES GENERAL + EMS DISPOSITIONS
-- ============================================================

create or replace function public.ems_finish_ambulance_transport(
  p_unit_id uuid,
  p_incident_id uuid,
  p_outcome text
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.ems_encounters;
  i public.incidents;
  eid uuid;
  unit_status_value text;
  destination_value text;
  outcome_value text;
  ems_disposition_value text;
  general_disposition_value text:='COMPLETED';
  actor_kind_value text;
  unit_rec record;
  released_count integer:=0;
begin
  outcome_value:=upper(trim(coalesce(p_outcome,'')));

  if outcome_value not in ('DELIVERED','REFUSAL') then
    raise exception 'Transport outcome must be DELIVERED or REFUSAL';
  end if;

  select u.event_id,u.status,u.current_transport_destination_text
  into eid,unit_status_value,destination_value
  from public.units u
  where u.id=p_unit_id
    and u.active=true;

  if eid is null then
    raise exception 'Active ambulance not found';
  end if;

  if not exists(
    select 1
    from public.ems_unit_config c
    where c.unit_id=p_unit_id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
  ) then
    raise exception 'Unit is not configured as a transport ambulance';
  end if;

  if public.can_dispatch_event(eid) then
    actor_kind_value:='staff';
  elsif public.field_has_unit_access(p_unit_id) then
    actor_kind_value:='field';
  else
    raise exception 'Not authorized for this ambulance';
  end if;

  select *
  into i
  from public.incidents
  where id=p_incident_id
    and event_id=eid
    and status='OPEN';

  if i.id is null then
    raise exception 'Active incident not found';
  end if;

  select *
  into e
  from public.ems_encounters x
  where x.event_id=eid
    and x.incident_id=p_incident_id
    and x.current_unit_id=p_unit_id
    and x.current_status='TRANSPORTING'
  order by x.created_at desc
  limit 1;

  if e.id is null then
    raise exception 'No active ambulance transport was found for this incident';
  end if;

  destination_value:=coalesce(
    nullif(trim(e.transport_destination),''),
    nullif(trim(destination_value),'')
  );

  if outcome_value='DELIVERED' and destination_value is null then
    raise exception 'Destination facility is required before recording hospital delivery';
  end if;

  ems_disposition_value:=case
    when outcome_value='DELIVERED' then 'TRANSPORTED'
    else 'REFUSAL'
  end;

  update public.ems_encounters
  set
    current_status='CLOSED',
    transport_destination=destination_value,
    transport_completed_at=case
      when outcome_value='DELIVERED' then now()
      else transport_completed_at
    end,
    final_disposition=ems_disposition_value,
    closed_at=now()
  where id=e.id;

  insert into public.cad_activity(
    event_id,incident_id,unit_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,p_unit_id,
    case
      when outcome_value='DELIVERED' then 'EMS_TRANSPORT_COMPLETED'
      else 'EMS_TRANSPORT_REFUSAL'
    end,
    jsonb_build_object(
      'encounter_id',e.id,
      'outcome',outcome_value,
      'ems_disposition',ems_disposition_value,
      'general_disposition',general_disposition_value,
      'destination',destination_value,
      'incident_will_close',true
    ),
    auth.uid(),actor_kind_value
  );

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
        auth.uid(),actor_kind_value,
        case when unit_rec.unit_id=p_unit_id then destination_value else null end,
        null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      eid,p_incident_id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status','AVAILABLE',
        'reason',case
          when outcome_value='DELIVERED' then 'TRANSPORT_DELIVERED_CALL_CLOSED'
          else 'TRANSPORT_REFUSAL_CALL_CLOSED'
        end,
        'automatic',true
      ),
      auth.uid(),actor_kind_value
    );

    released_count:=released_count+1;
  end loop;

  update public.incidents
  set
    status='CLOSED',
    closed_at=now(),
    disposition=general_disposition_value
  where id=p_incident_id;

  insert into public.cad_activity(
    event_id,incident_id,action,detail,
    actor_user_id,actor_kind
  ) values(
    eid,p_incident_id,'INCIDENT_CLOSED',
    jsonb_build_object(
      'disposition',general_disposition_value,
      'general_disposition',general_disposition_value,
      'ems_disposition',ems_disposition_value,
      'transport_outcome',outcome_value,
      'destination',destination_value,
      'released_units',released_count,
      'automatic',true,
      'reason','AMBULANCE_TRANSPORT_OUTCOME'
    ),
    auth.uid(),actor_kind_value
  );

  return outcome_value;
end;
$$;

revoke all on function public.ems_finish_ambulance_transport(uuid,uuid,text) from public;
grant execute on function public.ems_finish_ambulance_transport(uuid,uuid,text) to authenticated;
