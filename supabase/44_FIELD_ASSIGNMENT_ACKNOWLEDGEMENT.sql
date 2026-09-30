-- CommCenter Pro v0.14.7
-- Field Unit assignment acknowledgement.

alter table public.incident_units
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledged_by uuid references auth.users(id) on delete set null;

create index if not exists incident_units_pending_ack_idx
  on public.incident_units(unit_id,assigned_at desc)
  where cleared_at is null and acknowledged_at is null;

-- Every new/re-activated assignment must require a fresh acknowledgement.
-- Centralizing this in a trigger covers Dispatch, EMS flow helpers, and any
-- future assignment path that reuses the same incident_units row.
create or replace function private.reset_incident_unit_acknowledgement()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op='INSERT' then
    new.acknowledged_at:=null;
    new.acknowledged_by:=null;
  elsif new.cleared_at is null
    and (
      old.cleared_at is not null
      or new.assigned_at is distinct from old.assigned_at
    )
  then
    new.acknowledged_at:=null;
    new.acknowledged_by:=null;
  end if;

  return new;
end;
$$;

drop trigger if exists reset_incident_unit_acknowledgement on public.incident_units;
create trigger reset_incident_unit_acknowledgement
before insert or update of assigned_at,cleared_at
on public.incident_units
for each row
execute function private.reset_incident_unit_acknowledgement();

create or replace function public.field_acknowledge_assignment(
  p_field_session_id uuid,
  p_incident_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions%rowtype;
  assignment_row public.incident_units%rowtype;
  incident_event_id uuid;
  acknowledged_time timestamptz;
begin
  select * into fs
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true
  for update;

  if fs.id is null or fs.unit_id is null then
    raise exception 'Active Field Unit session not found';
  end if;

  if not exists(
    select 1
    from public.operational_periods op
    where op.id=fs.operational_period_id
      and op.event_id=fs.event_id
      and op.status='ACTIVE'
  ) then
    raise exception 'This Field session is no longer active for the current Operational Period';
  end if;

  select i.event_id into incident_event_id
  from public.incidents i
  where i.id=p_incident_id;

  if incident_event_id is null or incident_event_id<>fs.event_id then
    raise exception 'Incident is not part of this Field session event';
  end if;

  select * into assignment_row
  from public.incident_units iu
  where iu.incident_id=p_incident_id
    and iu.unit_id=fs.unit_id
    and iu.cleared_at is null
  for update;

  if assignment_row.id is null then
    raise exception 'This unit is not currently assigned to that incident';
  end if;

  if assignment_row.acknowledged_at is null then
    acknowledged_time:=now();

    update public.incident_units
    set
      acknowledged_at=acknowledged_time,
      acknowledged_by=auth.uid()
    where id=assignment_row.id;

    insert into public.cad_activity(
      event_id,
      incident_id,
      unit_id,
      action,
      detail,
      actor_user_id,
      actor_kind
    ) values(
      fs.event_id,
      p_incident_id,
      fs.unit_id,
      'UNIT_ASSIGNMENT_ACKNOWLEDGED',
      jsonb_build_object(
        'field_session_id',fs.id,
        'assigned_at',assignment_row.assigned_at,
        'acknowledged_at',acknowledged_time,
        'ack_seconds',greatest(
          0,
          extract(epoch from (acknowledged_time-assignment_row.assigned_at))::integer
        )
      ),
      auth.uid(),
      'field'
    );
  else
    acknowledged_time:=assignment_row.acknowledged_at;
  end if;

  update public.field_sessions
  set last_seen_at=now()
  where id=fs.id;

  return acknowledged_time;
end;
$$;

revoke all on function public.field_acknowledge_assignment(uuid,uuid) from public;
grant execute on function public.field_acknowledge_assignment(uuid,uuid) to authenticated;
