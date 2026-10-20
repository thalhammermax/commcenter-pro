-- CommCenter Pro v0.19.1
-- Event-level Guest Logistics setting: how many minutes before pickup a
-- scheduled MOVE becomes an active ticket. Per-MOVE overrides are optional;
-- a NULL lead on the incident means "use the event setting", so changing the
-- setting applies to every MOVE still waiting to activate.
-- Run against a v0.19.0 database.

alter table public.events
  add column if not exists move_activation_lead_minutes integer not null default 60
  check(move_activation_lead_minutes between 5 and 1440);

alter table public.incidents
  alter column activate_lead_minutes drop not null,
  alter column activate_lead_minutes drop default;

-- Existing MOVEs created with the old fixed default now follow the setting.
update public.incidents set activate_lead_minutes=null
where incident_kind='MOVE' and status='SCHEDULED' and activate_lead_minutes=60;

create or replace function public.admin_set_move_activation_lead(p_event_id uuid,p_minutes integer)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if p_minutes is null or p_minutes<5 or p_minutes>1440 then
    raise exception 'Activation lead must be between 5 and 1440 minutes';
  end if;
  update public.events set move_activation_lead_minutes=p_minutes where id=p_event_id;
  insert into public.cad_activity(event_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,'MOVE_ACTIVATION_LEAD_CHANGED',jsonb_build_object('minutes',p_minutes),auth.uid(),'staff');
end;
$$;
revoke all on function public.admin_set_move_activation_lead(uuid,integer) from public;
grant execute on function public.admin_set_move_activation_lead(uuid,integer) to authenticated;

create or replace function public.activate_due_move_incidents(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  n integer:=0;
  lead integer;
begin
  if not (public.can_dispatch_event(p_event_id) or public.has_event_staff_access(p_event_id) or private.command_has_event_access(p_event_id)) then
    return 0;
  end if;
  select move_activation_lead_minutes into lead from public.events where id=p_event_id;
  for r in
    select id from public.incidents
    where event_id=p_event_id and incident_kind='MOVE' and status='SCHEDULED'
      and scheduled_at - make_interval(mins=>coalesce(activate_lead_minutes,lead,60))<=now()
    order by scheduled_at
  loop
    if private.activate_incident(r.id,'system') then n:=n+1; end if;
  end loop;
  return n;
end;
$$;

-- create_move_incident: a NULL lead means "use the event setting".
create or replace function public.create_move_incident(
  p_event_id uuid,
  p_department_id uuid,
  p_scheduled_at timestamptz,
  p_guest jsonb,
  p_notes text default null,
  p_priority text default 'Standard',
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_map_x double precision default null,
  p_map_y double precision default null,
  p_activate_lead_minutes integer default null,
  p_assign_unit_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  iid uuid;
  number_value text;
  guest_name_value text;
  origin_value text;
  destination_value text;
  due boolean;
  active_op uuid;
  lead integer;
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if not exists(select 1 from public.event_departments d where d.id=p_department_id and d.event_id=p_event_id and d.active=true and d.guest_logistics_enabled=true) then
    raise exception 'Department is not an active Guest Logistics department';
  end if;
  if p_scheduled_at is null then raise exception 'Scheduled pickup time is required'; end if;

  guest_name_value:=nullif(trim(coalesce(p_guest->>'guest_name','')),'');
  origin_value:=nullif(trim(coalesce(p_guest->>'origin','')),'');
  destination_value:=nullif(trim(coalesce(p_guest->>'destination','')),'');
  if guest_name_value is null then raise exception 'Guest name is required'; end if;
  if origin_value is null or destination_value is null then raise exception 'Pickup and destination are required'; end if;

  select move_activation_lead_minutes into lead from public.events where id=p_event_id;
  number_value:=private.next_move_number(p_event_id);
  due:=(p_scheduled_at - make_interval(mins=>coalesce(p_activate_lead_minutes,lead,60)))<=now();
  select id into active_op from public.operational_periods where event_id=p_event_id and status='ACTIVE' limit 1;

  insert into public.incidents(
    event_id,operational_period_id,incident_number,incident_kind,call_type,priority,status,
    poi_id,map_layer_id,zone_id,latitude,longitude,map_x,map_y,landmark,notes,
    scheduled_at,activate_lead_minutes,activated_at,created_by
  ) values(
    p_event_id,case when due then active_op end,number_value,'MOVE',
    coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),'OTHER')||' · '||guest_name_value,
    coalesce(nullif(trim(coalesce(p_priority,'')),''),'Standard'),
    case when due then 'OPEN' else 'SCHEDULED' end,
    p_poi_id,p_map_layer_id,p_zone_id,p_latitude,p_longitude,p_map_x,p_map_y,
    origin_value,p_notes,
    p_scheduled_at,p_activate_lead_minutes,case when due then now() end,auth.uid()
  ) returning id into iid;

  insert into public.incident_departments(incident_id,department_id) values(iid,p_department_id);

  insert into public.incident_guest_details(
    incident_id,event_id,movement_type,guest_name,guest_group,party_size,contact_phone,contact_email,
    origin,destination,airline,flight_number,airport,terminal
  ) values(
    iid,p_event_id,
    coalesce(nullif(trim(coalesce(p_guest->>'movement_type','')),''),'OTHER'),
    guest_name_value,
    nullif(trim(coalesce(p_guest->>'guest_group','')),''),
    greatest(1,least(500,coalesce((p_guest->>'party_size')::integer,1))),
    nullif(trim(coalesce(p_guest->>'contact_phone','')),''),
    nullif(trim(coalesce(p_guest->>'contact_email','')),''),
    origin_value,destination_value,
    nullif(trim(coalesce(p_guest->>'airline','')),''),
    nullif(trim(coalesce(p_guest->>'flight_number','')),''),
    nullif(trim(coalesce(p_guest->>'airport','')),''),
    nullif(trim(coalesce(p_guest->>'terminal','')),'')
  );

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,iid,'MOVE_CREATED',jsonb_build_object('scheduled_at',p_scheduled_at,'guest_name',guest_name_value,'status',case when due then 'OPEN' else 'SCHEDULED' end),auth.uid(),'staff');

  if p_assign_unit_id is not null then
    perform public.assign_unit(iid,p_assign_unit_id);
  end if;
  return iid;
end;
$$;
