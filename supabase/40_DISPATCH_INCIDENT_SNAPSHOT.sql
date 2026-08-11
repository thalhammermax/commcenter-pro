-- CommCenter Pro v0.14.2
-- Authoritative Dispatch active-incident heartbeat.
--
-- This is deliberately small: Dispatch uses it to reconcile the active-call
-- set and map markers every second without depending solely on Realtime.

create index if not exists incidents_event_status_idx
  on public.incidents(event_id,status);

create or replace function public.dispatch_active_incident_snapshot(
  p_event_id uuid
)
returns table(
  id uuid,
  incident_number text,
  status text,
  map_x double precision,
  map_y double precision,
  map_layer_id uuid,
  call_type text,
  priority text,
  landmark text,
  closed_at timestamptz
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_event_id is null then
    raise exception 'Event is required';
  end if;

  if not public.can_dispatch_event(p_event_id) then
    raise exception 'Dispatcher access required';
  end if;

  return query
  select
    i.id,
    i.incident_number,
    i.status,
    i.map_x,
    i.map_y,
    i.map_layer_id,
    i.call_type,
    i.priority,
    i.landmark,
    i.closed_at
  from public.incidents i
  where i.event_id=p_event_id
    and i.status<>'CLOSED'
  order by i.created_at desc;
end;
$$;

revoke all on function public.dispatch_active_incident_snapshot(uuid) from public;
grant execute on function public.dispatch_active_incident_snapshot(uuid) to authenticated;
