-- CommCenter Pro v0.15.8
-- Editable event-level CAD status templates + terminal CAD status closes the incident.

alter table public.events
  add column if not exists cad_status_template jsonb,
  add column if not exists guest_logistics_cad_status_template jsonb,
  add column if not exists ems_status_template jsonb;

alter table public.event_departments
  alter column status_profile set default
    '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb;

alter table public.events
  alter column cad_status_template set default
    '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb,
  alter column guest_logistics_cad_status_template set default
    '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb,
  alter column ems_status_template set default
    '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","TRANSPORTING","AT_HOSPITAL","CLEAR","OUT_OF_SERVICE"]'::jsonb;

create or replace function private.normalize_cad_status_template(
  p_template jsonb,
  p_kind text
)
returns jsonb
language plpgsql
immutable
as $$
declare
  source jsonb;
  result jsonb:='[]'::jsonb;
  status_value text;
  required_values text[];
  default_values jsonb;
  catalog text[]:=array[
    'AVAILABLE','RESPONDING','EN_ROUTE','ON_SCENE','WORKING',
    'TRANSPORTING','AT_HOSPITAL','RETURNING','CLEAR','COMPLETE','OUT_OF_SERVICE'
  ];
begin
  if upper(coalesce(p_kind,''))='EMS' then
    required_values:=array['AVAILABLE','EN_ROUTE','ON_SCENE','TRANSPORTING','AT_HOSPITAL','OUT_OF_SERVICE'];
    default_values:='["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","TRANSPORTING","AT_HOSPITAL","CLEAR","OUT_OF_SERVICE"]'::jsonb;
  else
    required_values:=array['AVAILABLE','EN_ROUTE','ON_SCENE','OUT_OF_SERVICE'];
    default_values:='["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb;
  end if;

  if p_template is null or jsonb_typeof(p_template)<>'array' or jsonb_array_length(p_template)=0 then
    source:=default_values;
  else
    source:=p_template;
  end if;

  foreach status_value in array catalog loop
    if source ? status_value or status_value=any(required_values) then
      result:=result||jsonb_build_array(status_value);
    end if;
  end loop;

  return result;
end;
$$;

revoke all on function private.normalize_cad_status_template(jsonb,text) from public;

create or replace function private.enforce_event_status_templates()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  new.cad_status_template:=private.normalize_cad_status_template(new.cad_status_template,'STANDARD');
  new.guest_logistics_cad_status_template:=private.normalize_cad_status_template(new.guest_logistics_cad_status_template,'GUEST_LOGISTICS');
  new.ems_status_template:=private.normalize_cad_status_template(new.ems_status_template,'EMS');
  return new;
end;
$$;

revoke all on function private.enforce_event_status_templates() from public;

drop trigger if exists enforce_event_status_templates on public.events;
create trigger enforce_event_status_templates
before insert or update of cad_status_template,guest_logistics_cad_status_template,ems_status_template
on public.events
for each row
execute function private.enforce_event_status_templates();

-- Normalize/backfill every existing event before departments inherit templates.
update public.events
set
  cad_status_template=private.normalize_cad_status_template(cad_status_template,'STANDARD'),
  guest_logistics_cad_status_template=private.normalize_cad_status_template(guest_logistics_cad_status_template,'GUEST_LOGISTICS'),
  ems_status_template=private.normalize_cad_status_template(ems_status_template,'EMS');

create or replace function private.enforce_department_module_status_profile()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  event_cad_template jsonb;
  event_guest_template jsonb;
  event_ems_template jsonb;
begin
  select
    e.cad_status_template,
    e.guest_logistics_cad_status_template,
    e.ems_status_template
  into
    event_cad_template,
    event_guest_template,
    event_ems_template
  from public.events e
  where e.id=new.event_id;

  if coalesce(new.ems_enabled,false) then
    new.status_profile:=private.normalize_cad_status_template(event_ems_template,'EMS');
  elsif coalesce(new.guest_logistics_enabled,false) then
    new.status_profile:=private.normalize_cad_status_template(event_guest_template,'GUEST_LOGISTICS');
  elsif new.status_profile is null
     or jsonb_typeof(new.status_profile)<>'array'
     or jsonb_array_length(new.status_profile)=0
  then
    new.status_profile:=private.normalize_cad_status_template(event_cad_template,'STANDARD');
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_department_module_status_profile() from public;

drop trigger if exists enforce_department_module_status_profile on public.event_departments;
create trigger enforce_department_module_status_profile
before insert or update of status_profile,ems_enabled,guest_logistics_enabled
on public.event_departments
for each row
execute function private.enforce_department_module_status_profile();

create or replace function private.sync_event_status_templates_to_departments()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if old.guest_logistics_cad_status_template is distinct from new.guest_logistics_cad_status_template then
    update public.event_departments
    set status_profile=new.guest_logistics_cad_status_template
    where event_id=new.id
      and guest_logistics_enabled=true
      and coalesce(ems_enabled,false)=false;
  end if;

  if old.ems_status_template is distinct from new.ems_status_template then
    update public.event_departments
    set status_profile=new.ems_status_template
    where event_id=new.id
      and ems_enabled=true;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_event_status_templates_to_departments() from public;

drop trigger if exists sync_event_status_templates_to_departments on public.events;
create trigger sync_event_status_templates_to_departments
after update of guest_logistics_cad_status_template,ems_status_template
on public.events
for each row
execute function private.sync_event_status_templates_to_departments();

create or replace function public.admin_update_event_status_templates(
  p_event_id uuid,
  p_cad_template jsonb,
  p_guest_logistics_template jsonb,
  p_ems_template jsonb
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event Admin access required';
  end if;

  update public.events
  set
    cad_status_template=p_cad_template,
    guest_logistics_cad_status_template=p_guest_logistics_template,
    ems_status_template=p_ems_template
  where id=p_event_id;

  if not found then
    raise exception 'Event not found';
  end if;
end;
$$;

revoke all on function public.admin_update_event_status_templates(uuid,jsonb,jsonb,jsonb) from public;
grant execute on function public.admin_update_event_status_templates(uuid,jsonb,jsonb,jsonb) to authenticated;

-- Normalize current module-enabled departments against the newly editable templates.
update public.event_departments d
set status_profile=case
  when d.ems_enabled then e.ems_status_template
  when d.guest_logistics_enabled then e.guest_logistics_cad_status_template
  else d.status_profile
end
from public.events e
where e.id=d.event_id
  and (d.ems_enabled=true or d.guest_logistics_enabled=true);

-- Terminal assignment statuses must close the incident. Never allow a status RPC
-- to leave the incident OPEN while merely clearing one assignment.
create or replace function private.prevent_terminal_open_cad_assignment_status()
returns trigger
language plpgsql
as $$
begin
  if new.cleared_at is null
     and new.cad_status in ('AVAILABLE','CLEAR','COMPLETE')
     and old.cad_status is distinct from new.cad_status
  then
    raise exception 'Available / Clear / Complete closes the CAD incident. Use the incident close workflow.';
  end if;
  return new;
end;
$$;

revoke all on function private.prevent_terminal_open_cad_assignment_status() from public;

drop trigger if exists prevent_terminal_open_cad_assignment_status on public.incident_units;
create trigger prevent_terminal_open_cad_assignment_status
before update of cad_status,cleared_at
on public.incident_units
for each row
execute function private.prevent_terminal_open_cad_assignment_status();

-- Allow the field unit currently assigned to an incident to complete the same
-- authoritative close transaction Dispatch uses. The caller still must supply
-- valid event dispositions, and active ambulance transport remains protected by
-- the Delivered / Refusal workflow.
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
  encounter_rec record;
  released_count integer:=0;
  treatment_released_count integer:=0;
  ems_context boolean:=false;
  general_code text;
  ems_code text;
  treatment_name text;
  effective_status text;
  field_unit_value uuid;
  actor_kind_value text;
begin
  select *
  into i
  from public.incidents
  where id=p_incident_id
    and status='OPEN'
  for update;

  if i.id is null then
    raise exception 'Open incident not found';
  end if;

  field_unit_value:=private.current_field_unit();

  if public.can_dispatch_event(i.event_id) then
    actor_kind_value:='staff';
  elsif field_unit_value is not null and exists(
    select 1
    from public.incident_units iu
    where iu.incident_id=i.id
      and iu.unit_id=field_unit_value
      and iu.cleared_at is null
  ) then
    actor_kind_value:='field';
  else
    raise exception 'Dispatch access or an active Field Unit assignment is required';
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

  -- Do not allow generic Dispatch close to bypass the event-ambulance
  -- Delivered / Refusal workflow.
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

  -- Log every patient that Dispatch is removing from an active Treatment Area
  -- before custody fields are cleared. This gives the detailed dispatch log an
  -- explicit treatment-center release record.
  for encounter_rec in
    select
      e.id,
      e.current_treatment_area_id,
      e.current_status,
      ta.name as treatment_area_name
    from public.ems_encounters e
    left join public.ems_treatment_areas ta
      on ta.id=e.current_treatment_area_id
    where e.incident_id=i.id
      and e.event_id=i.event_id
      and e.current_treatment_area_id is not null
      and e.current_status<>'CLOSED'
    for update of e
  loop
    treatment_name:=coalesce(encounter_rec.treatment_area_name,'Treatment Area');

    insert into public.cad_activity(
      event_id,
      incident_id,
      action,
      detail,
      actor_user_id,
      actor_kind
    ) values(
      i.event_id,
      i.id,
      case when actor_kind_value='field' then 'EMS_TREATMENT_CLEARED_BY_FIELD' else 'EMS_TREATMENT_CLEARED_BY_DISPATCH' end,
      jsonb_build_object(
        'encounter_id',encounter_rec.id,
        'treatment_area_id',encounter_rec.current_treatment_area_id,
        'treatment_area_name',treatment_name,
        'previous_ems_status',encounter_rec.current_status,
        'ems_disposition',ems_code,
        'reason',case when actor_kind_value='field' then 'INCIDENT_CLOSED_BY_FIELD' else 'INCIDENT_CLOSED_BY_DISPATCH' end
      ),
      auth.uid(),
      actor_kind_value
    );

    treatment_released_count:=treatment_released_count+1;
  end loop;

  -- Any outstanding EMS handoff request for this patient is no longer valid
  -- once Dispatch closes the incident.
  update public.ems_handoffs h
  set
    status='CANCELLED',
    responded_at=coalesce(h.responded_at,now())
  where h.event_id=i.event_id
    and h.status='PENDING'
    and exists(
      select 1
      from public.ems_encounters e
      where e.id=h.encounter_id
        and e.incident_id=i.id
    );

  -- Apply the final EMS disposition to every EMS encounter attached to the
  -- incident and explicitly clear current custody. Clearing
  -- current_treatment_area_id is what removes the patient from treatment-area
  -- census/state, while current_status='CLOSED' makes the release unambiguous.
  if ems_code is not null then
    update public.ems_encounters
    set
      current_status='CLOSED',
      current_unit_id=null,
      current_treatment_area_id=null,
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

  -- Release every operational unit still committed to the incident.
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

    effective_status:=private.guest_logistics_primary_unit_status(unit_rec.unit_id,'AVAILABLE');

    update public.units
    set
      status=effective_status,
      current_transport_destination_text=null,
      current_transport_treatment_area_id=null
    where id=unit_rec.unit_id;

    if unit_rec.status is distinct from effective_status then
      insert into public.unit_status_log(
        event_id,incident_id,unit_id,old_status,new_status,
        actor_user_id,actor_kind,
        transport_destination_text,transport_treatment_area_id
      ) values(
        i.event_id,i.id,unit_rec.unit_id,
        unit_rec.status,effective_status,
        auth.uid(),actor_kind_value,null,null
      );
    end if;

    insert into public.cad_activity(
      event_id,incident_id,unit_id,action,detail,
      actor_user_id,actor_kind
    ) values(
      i.event_id,i.id,unit_rec.unit_id,'UNIT_UNASSIGNED',
      jsonb_build_object(
        'new_status',effective_status,
        'reason','INCIDENT_CLOSED',
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
      'released_units',released_count,
      'treatment_patients_released',treatment_released_count
    ),
    auth.uid(),actor_kind_value
  );
end;
$$;

revoke all on function public.assign_unit(uuid,uuid) from public;
grant execute on function public.assign_unit(uuid,uuid) to authenticated;
revoke all on function public.unassign_unit(uuid,uuid,text) from public;
grant execute on function public.unassign_unit(uuid,uuid,text) to authenticated;
revoke all on function public.guest_logistics_set_status(uuid,text) from public;
grant execute on function public.guest_logistics_set_status(uuid,text) to authenticated;
revoke all on function public.close_incident_v2(uuid,text,text) from public;
grant execute on function public.close_incident_v2(uuid,text,text) to authenticated;

