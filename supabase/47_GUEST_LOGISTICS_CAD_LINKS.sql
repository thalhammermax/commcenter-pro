-- CommCenter Pro v0.15.4
-- Link normal CAD incidents to an existing Guest Logistics MOVE.
--
-- A CAD incident may reference one MOVE. A MOVE may have any number of CAD
-- incidents linked to it over its lifetime.

alter table public.incidents
  add column if not exists guest_logistics_movement_id uuid
  references public.guest_logistics_movements(id) on delete set null;

create index if not exists incidents_guest_logistics_movement_idx
  on public.incidents(guest_logistics_movement_id)
  where guest_logistics_movement_id is not null;

create or replace function public.create_incident_v5(
  p_event_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_create_poi boolean default false,
  p_poi_category text default null,
  p_poi_aliases text[] default null,
  p_guest_logistics_movement_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  incident_id_value uuid;
  movement public.guest_logistics_movements;
begin
  if p_guest_logistics_movement_id is not null then
    select *
    into movement
    from public.guest_logistics_movements
    where id=p_guest_logistics_movement_id
      and event_id=p_event_id;

    if movement.id is null then
      raise exception 'Guest Logistics MOVE was not found in this event';
    end if;

    if not exists(
      select 1
      from public.event_departments d
      where d.id=movement.department_id
        and d.event_id=p_event_id
        and d.active=true
        and d.guest_logistics_enabled=true
    ) then
      raise exception 'The selected MOVE is not in an active Guest Logistics-enabled department';
    end if;
  end if;

  incident_id_value:=public.create_incident_v4(
    p_event_id,
    p_department_ids,
    p_call_type,
    p_priority,
    p_latitude,
    p_longitude,
    p_map_x,
    p_map_y,
    p_landmark,
    p_notes,
    p_poi_id,
    p_map_layer_id,
    p_zone_id,
    p_create_poi,
    p_poi_category,
    p_poi_aliases
  );

  if p_guest_logistics_movement_id is not null then
    update public.incidents
    set guest_logistics_movement_id=p_guest_logistics_movement_id
    where id=incident_id_value;

    insert into public.cad_activity(
      event_id,incident_id,action,detail,actor_user_id,actor_kind
    ) values(
      p_event_id,
      incident_id_value,
      'GUEST_LOGISTICS_MOVE_LINKED',
      jsonb_build_object(
        'movement_id',movement.id,
        'movement_number',movement.movement_number,
        'guest_name',movement.guest_name,
        'flight_number',movement.flight_number
      ),
      auth.uid(),
      'staff'
    );
  end if;

  return incident_id_value;
end;
$$;

revoke all on function public.create_incident_v5(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[],uuid
) from public;

grant execute on function public.create_incident_v5(
  uuid,uuid[],text,text,
  double precision,double precision,double precision,double precision,
  text,text,uuid,uuid,uuid,boolean,text,text[],uuid
) to authenticated;
