-- CommCenter Pro v0.12.0
-- Operational Period-bound Field sessions + event-wide Field Layout Builder.
--
-- 1. Every new Field session is bound to the ACTIVE Operational Period.
-- 2. Ending / replacing an Operational Period immediately ends every Field
--    session created for that period and clears live GPS locations.
-- 3. Field access helpers refuse stale sessions whose Operational Period is no
--    longer ACTIVE, even if a client somehow misses the Realtime kick-out.
-- 4. Each event receives one global field_layout_config used by every Field
--    unit in that event.

-- ============================================================
-- EVENT-WIDE FIELD LAYOUT CONFIGURATION
-- ============================================================

alter table public.events
  add column if not exists field_layout_config jsonb not null default
  '{
    "version":1,
    "blocks":[
      {"id":"unit_identity","enabled":true},
      {"id":"current_call","enabled":true},
      {"id":"guest_logistics","enabled":true},
      {"id":"ems_patient_flow","enabled":true},
      {"id":"status_controls","enabled":true},
      {"id":"transport_destination","enabled":true},
      {"id":"run_times","enabled":true},
      {"id":"live_location","enabled":true},
      {"id":"connectivity_offline","enabled":true},
      {"id":"session_controls","enabled":true}
    ]
  }'::jsonb;

create or replace function public.admin_save_field_layout(
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
    'unit_identity',
    'status_controls',
    'run_times',
    'current_call',
    'guest_logistics',
    'ems_patient_flow',
    'live_location',
    'transport_destination',
    'connectivity_offline',
    'session_controls'
  ];
begin
  if not public.can_admin_event(p_event_id) then
    raise exception 'Event admin access required';
  end if;

  if jsonb_typeof(p_layout)<>'object' then
    raise exception 'Field layout must be a JSON object';
  end if;

  blocks:=p_layout->'blocks';
  if jsonb_typeof(blocks)<>'array' then
    raise exception 'Field layout blocks must be an array';
  end if;

  for item in select value from jsonb_array_elements(blocks)
  loop
    block_id:=nullif(trim(item->>'id'),'');

    if block_id is null or not (block_id=any(allowed_ids)) then
      raise exception 'Unknown Field layout block: %',coalesce(block_id,'(blank)');
    end if;

    if block_id=any(seen) then
      raise exception 'Duplicate Field layout block: %',block_id;
    end if;

    seen:=array_append(seen,block_id);
    normalized:=normalized||jsonb_build_array(
      jsonb_build_object(
        'id',block_id,
        'enabled',case
          when block_id in ('unit_identity','status_controls','current_call','guest_logistics','ems_patient_flow','transport_destination','session_controls') then true
          else coalesce((item->>'enabled')::boolean,true)
        end
      )
    );
  end loop;

  -- Required operational blocks must be present. Context-specific blocks such as
  -- EMS, Guest Logistics, and Transport render no content when they do not apply,
  -- but cannot be globally disabled when they are operationally needed.
  foreach required_id in array array['unit_identity','status_controls','current_call','guest_logistics','ems_patient_flow','transport_destination','session_controls']
  loop
    if not required_id=any(seen) then
      raise exception 'Required Field layout block is missing: %',required_id;
    end if;
  end loop;

  -- Append any newly introduced optional block that an older client omitted.
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
  set field_layout_config=p_layout
  where id=p_event_id;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    p_event_id,
    'FIELD_LAYOUT_UPDATED',
    jsonb_build_object('layout',p_layout),
    auth.uid(),
    'staff'
  );

  return p_layout;
end;
$$;

revoke all on function public.admin_save_field_layout(uuid,jsonb) from public;
grant execute on function public.admin_save_field_layout(uuid,jsonb) to authenticated;

-- ============================================================
-- FIELD SESSIONS BELONG TO AN OPERATIONAL PERIOD
-- ============================================================

alter table public.field_sessions
  add column if not exists operational_period_id uuid
    references public.operational_periods(id) on delete set null,
  add column if not exists end_reason text;

create index if not exists field_sessions_operational_period_active_idx
  on public.field_sessions(operational_period_id,active);

-- Best-effort backfill for sessions that were active during this migration.
update public.field_sessions fs
set operational_period_id=op.id
from public.operational_periods op
where fs.operational_period_id is null
  and fs.active=true
  and op.event_id=fs.event_id
  and op.status='ACTIVE';

-- Any older active Field session that cannot be associated with a currently
-- ACTIVE Operational Period is no longer valid under the v0.12.0 model.
update public.field_sessions
set
  active=false,
  ended_at=now(),
  last_seen_at=now(),
  end_reason='MIGRATION_REQUIRES_OPERATIONAL_PERIOD_LOGIN'
where active=true
  and operational_period_id is null;

-- ============================================================
-- DEFENSIVE FIELD ACCESS HELPERS
-- ============================================================

create or replace function public.field_has_event_access(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.field_sessions fs
    join public.operational_periods op
      on op.id=fs.operational_period_id
     and op.event_id=fs.event_id
    where fs.event_id=p_event
      and fs.auth_user_id=auth.uid()
      and fs.active=true
      and op.status='ACTIVE'
  );
$$;

create or replace function private.current_field_unit()
returns uuid
language sql
stable
security definer
set search_path=''
as $$
  select fs.unit_id
  from public.field_sessions fs
  join public.operational_periods op
    on op.id=fs.operational_period_id
   and op.event_id=fs.event_id
  where fs.auth_user_id=(select auth.uid())
    and fs.active=true
    and fs.unit_id is not null
    and op.status='ACTIVE'
  order by fs.started_at desc
  limit 1;
$$;

-- ============================================================
-- FIELD LOGIN / UNIT CLAIM
-- ============================================================

create or replace function public.field_enter_event(
  p_event_code text,
  p_pin text,
  p_operator_name text default null
)
returns public.field_sessions
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.events;
  op public.operational_periods;
  fs public.field_sessions;
begin
  select * into e
  from public.events
  where upper(event_code)=upper(trim(p_event_code))
    and active=true
    and field_access_enabled=true;

  if e.id is null then
    raise exception 'Event not found or field access is disabled';
  end if;

  if e.field_pin_hash is null or crypt(p_pin,e.field_pin_hash)<>e.field_pin_hash then
    raise exception 'Invalid event access code';
  end if;

  select * into op
  from public.operational_periods
  where event_id=e.id
    and status='ACTIVE'
  limit 1;

  if op.id is null then
    raise exception 'No ACTIVE Operational Period. Field units can sign in after an Operational Period is activated.';
  end if;

  update public.field_sessions
  set
    active=false,
    ended_at=now(),
    last_seen_at=now(),
    end_reason='REPLACED_BY_NEW_FIELD_LOGIN'
  where auth_user_id=auth.uid()
    and active=true;

  -- Preserve the longstanding rule that one anonymous device session cannot
  -- simultaneously act as a Treatment Area Station and Field Unit.
  update public.treatment_area_sessions
  set active=false,ended_at=now()
  where auth_user_id=auth.uid()
    and active=true;

  insert into public.field_sessions(
    event_id,
    operational_period_id,
    auth_user_id,
    operator_name
  ) values(
    e.id,
    op.id,
    auth.uid(),
    nullif(trim(p_operator_name),'')
  )
  returning * into fs;

  insert into public.cad_activity(
    event_id,action,detail,actor_user_id,actor_kind
  ) values(
    e.id,
    'FIELD_SESSION_STARTED',
    jsonb_build_object(
      'field_session_id',fs.id,
      'operational_period_id',op.id,
      'operational_period_name',op.name,
      'incident_prefix',op.incident_prefix
    ),
    auth.uid(),
    'field'
  );

  return fs;
end;
$$;

create or replace function public.field_claim_unit(
  p_field_session_id uuid,
  p_unit_id uuid
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  fs public.field_sessions;
begin
  select * into fs
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true
  for update;

  if fs.id is null then
    raise exception 'Field session not found';
  end if;

  if not exists(
    select 1
    from public.operational_periods op
    where op.id=fs.operational_period_id
      and op.event_id=fs.event_id
      and op.status='ACTIVE'
  ) then
    raise exception 'This Field session expired when its Operational Period ended. Sign in again for the current Operational Period.';
  end if;

  if not exists(
    select 1
    from public.units
    where id=p_unit_id
      and event_id=fs.event_id
      and active=true
  ) then
    raise exception 'Invalid unit';
  end if;

  update public.field_sessions
  set unit_id=p_unit_id,last_seen_at=now()
  where id=fs.id;
end;
$$;

create or replace function public.field_release_unit(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set unit_id=null,last_seen_at=now()
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

create or replace function public.field_end_session(p_field_session_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  held_unit uuid;
begin
  select unit_id into held_unit
  from public.field_sessions
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;

  if held_unit is not null then
    delete from public.unit_locations where unit_id=held_unit;
  end if;

  update public.field_sessions
  set
    active=false,
    ended_at=now(),
    last_seen_at=now(),
    end_reason='USER_EXIT'
  where id=p_field_session_id
    and auth_user_id=auth.uid()
    and active=true;
end;
$$;

revoke all on function public.field_enter_event(text,text,text) from public;
revoke all on function public.field_claim_unit(uuid,uuid) from public;
revoke all on function public.field_release_unit(uuid) from public;
revoke all on function public.field_end_session(uuid) from public;

grant execute on function public.field_enter_event(text,text,text) to authenticated;
grant execute on function public.field_claim_unit(uuid,uuid) to authenticated;
grant execute on function public.field_release_unit(uuid) to authenticated;
grant execute on function public.field_end_session(uuid) to authenticated;

-- ============================================================
-- FORCE-END FIELD SESSIONS WHEN AN OPERATIONAL PERIOD ENDS
-- ============================================================

create or replace function private.end_field_sessions_for_operational_period()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  ended_count integer:=0;
begin
  if old.status='ACTIVE' and new.status<>'ACTIVE' then
    -- Remove current GPS positions first while the sessions still tell us which
    -- unit each device was controlling.
    delete from public.unit_locations ul
    where exists(
      select 1
      from public.field_sessions fs
      where fs.operational_period_id=old.id
        and fs.active=true
        and fs.unit_id=ul.unit_id
    );

    update public.field_sessions
    set
      active=false,
      ended_at=now(),
      last_seen_at=now(),
      end_reason='OPERATIONAL_PERIOD_ENDED'
    where operational_period_id=old.id
      and active=true;

    get diagnostics ended_count=row_count;

    insert into public.cad_activity(
      event_id,action,detail,actor_user_id,actor_kind
    ) values(
      old.event_id,
      'FIELD_SESSIONS_ENDED_OPERATIONAL_PERIOD',
      jsonb_build_object(
        'operational_period_id',old.id,
        'operational_period_name',old.name,
        'incident_prefix',old.incident_prefix,
        'field_sessions_ended',ended_count,
        'requires_new_field_login',true
      ),
      auth.uid(),
      case when auth.uid() is null then 'system' else 'staff' end
    );
  end if;

  return new;
end;
$$;

drop trigger if exists end_field_sessions_for_operational_period on public.operational_periods;
create trigger end_field_sessions_for_operational_period
after update of status on public.operational_periods
for each row
execute function private.end_field_sessions_for_operational_period();

-- ============================================================
-- REALTIME
-- ============================================================

-- Field devices need the field_sessions UPDATE immediately so an OP-end kick
-- is visible without waiting for the next user action. Event updates are used
-- so a saved Field Layout is also applied live to connected Field devices.
do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='field_sessions'
  ) then
    alter publication supabase_realtime add table public.field_sessions;
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
