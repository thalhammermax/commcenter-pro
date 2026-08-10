-- CommCenter Pro v0.14.0
-- Authoritative Dispatch unit-state heartbeat.
-- Realtime remains the fast path; this guarded snapshot lets Dispatch repair
-- stale unit badges without a browser refresh even when a websocket event is
-- missed or the channel is temporarily degraded.

create index if not exists units_event_active_idx
  on public.units(event_id,active);

create or replace function public.dispatch_unit_status_snapshot(
  p_event_id uuid
)
returns table(
  id uuid,
  status text,
  current_transport_destination_text text,
  current_transport_treatment_area_id uuid,
  current_map_layer_id uuid,
  current_zone_id uuid,
  current_poi_id uuid
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
    u.id,
    u.status,
    u.current_transport_destination_text,
    u.current_transport_treatment_area_id,
    u.current_map_layer_id,
    u.current_zone_id,
    u.current_poi_id
  from public.units u
  where u.event_id=p_event_id
    and u.active=true
  order by u.name;
end;
$$;

revoke all on function public.dispatch_unit_status_snapshot(uuid) from public;
grant execute on function public.dispatch_unit_status_snapshot(uuid) to authenticated;
