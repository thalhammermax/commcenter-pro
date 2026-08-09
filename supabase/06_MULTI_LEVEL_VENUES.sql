-- CommCenter Pro v0.4.0
-- Multi-level venue / stadium mapping upgrade.
-- Safe for an existing v0.3.1 database. Existing maps/incidents/POIs are preserved.

alter table public.events
  add column if not exists venue_type text not null default 'outdoor'
  check (venue_type in ('outdoor','multi_level','hybrid')),
  add column if not exists offline_w3w_path text;

create table if not exists public.event_map_layers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  short_name text,
  level_code text,
  level_number integer,
  level_type text not null default 'venue'
    check (level_type in ('exterior','field','concourse','suite','deck','back_of_house','parking','venue','other')),
  sort_order integer not null default 100,
  source_pdf_path text,
  rendered_image_path text,
  image_width integer,
  image_height integer,
  georef_method text,
  georef_coefficients jsonb,
  georef_rmse_m double precision,
  georef_max_error_m double precision,
  status text not null default 'draft' check(status in ('draft','calibrated','published')),
  is_default boolean not null default false,
  active boolean not null default true,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(event_id,name)
);

create unique index if not exists event_map_layers_one_default_idx
  on public.event_map_layers(event_id)
  where is_default=true and active=true;

alter table public.map_control_points
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete cascade;

alter table public.event_pois
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete set null;

create table if not exists public.event_zones (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  map_layer_id uuid references public.event_map_layers(id) on delete cascade,
  name text not null,
  short_name text,
  category text,
  notes text,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(event_id,map_layer_id,name)
);

alter table public.event_pois
  add column if not exists zone_id uuid references public.event_zones(id) on delete set null;

alter table public.incidents
  add column if not exists map_layer_id uuid references public.event_map_layers(id) on delete set null,
  add column if not exists zone_id uuid references public.event_zones(id) on delete set null;

alter table public.units
  add column if not exists current_map_layer_id uuid references public.event_map_layers(id) on delete set null,
  add column if not exists current_zone_id uuid references public.event_zones(id) on delete set null,
  add column if not exists current_poi_id uuid references public.event_pois(id) on delete set null;

create table if not exists public.venue_access_points (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  access_type text not null
    check(access_type in ('elevator','stairwell','escalator','ramp','portal','vomitory','tunnel','gate','corridor','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(event_id,name)
);

create table if not exists public.venue_access_point_nodes (
  id uuid primary key default gen_random_uuid(),
  access_point_id uuid not null references public.venue_access_points(id) on delete cascade,
  map_layer_id uuid not null references public.event_map_layers(id) on delete cascade,
  zone_id uuid references public.event_zones(id) on delete set null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision,
  longitude double precision,
  w3w text,
  instructions text,
  created_at timestamptz not null default now(),
  unique(access_point_id,map_layer_id)
);

create index if not exists event_map_layers_event_idx on public.event_map_layers(event_id,sort_order);
create index if not exists event_zones_event_layer_idx on public.event_zones(event_id,map_layer_id,sort_order);
create index if not exists venue_access_points_event_idx on public.venue_access_points(event_id);
create index if not exists venue_access_nodes_layer_idx on public.venue_access_point_nodes(map_layer_id);

-- Migrate the existing single event map into a default map layer once.
insert into public.event_map_layers(
  event_id,name,short_name,level_code,level_type,sort_order,
  source_pdf_path,rendered_image_path,image_width,image_height,
  georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
  status,is_default,published_at,updated_at
)
select
  em.event_id,'Event / Site Level','EVENT','EVENT','venue',10,
  em.source_pdf_path,em.rendered_image_path,em.image_width,em.image_height,
  em.georef_method,em.georef_coefficients,em.georef_rmse_m,em.georef_max_error_m,
  em.status,true,em.published_at,em.updated_at
from public.event_maps em
where not exists(select 1 from public.event_map_layers l where l.event_id=em.event_id);

-- Attach legacy control points/POIs to the default layer when possible.
update public.map_control_points cp
set map_layer_id=l.id
from public.event_map_layers l
where cp.event_id=l.event_id and l.is_default=true and cp.map_layer_id is null;

update public.event_pois p
set map_layer_id=l.id
from public.event_map_layers l
where p.event_id=l.event_id and l.is_default=true and p.map_layer_id is null;

update public.incidents i
set map_layer_id=l.id
from public.event_map_layers l
where i.event_id=l.event_id and l.is_default=true and i.map_layer_id is null;

-- ---------------- Access helpers / RLS ----------------
alter table public.event_map_layers enable row level security;
alter table public.event_zones enable row level security;
alter table public.venue_access_points enable row level security;
alter table public.venue_access_point_nodes enable row level security;

create policy "map layers read" on public.event_map_layers for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "map layers admin insert" on public.event_map_layers for insert
with check(public.can_admin_event(event_id));
create policy "map layers admin update" on public.event_map_layers for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "map layers admin delete" on public.event_map_layers for delete
using(public.can_admin_event(event_id));

create policy "zones read" on public.event_zones for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "zones admin insert" on public.event_zones for insert
with check(public.can_admin_event(event_id));
create policy "zones admin update" on public.event_zones for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "zones admin delete" on public.event_zones for delete
using(public.can_admin_event(event_id));

create policy "access points read" on public.venue_access_points for select
using(public.has_event_staff_access(event_id) or public.field_has_event_access(event_id));
create policy "access points admin insert" on public.venue_access_points for insert
with check(public.can_admin_event(event_id));
create policy "access points admin update" on public.venue_access_points for update
using(public.can_admin_event(event_id)) with check(public.can_admin_event(event_id));
create policy "access points admin delete" on public.venue_access_points for delete
using(public.can_admin_event(event_id));

create policy "access nodes read" on public.venue_access_point_nodes for select
using(exists(
  select 1 from public.venue_access_points ap
  where ap.id=access_point_id and (public.has_event_staff_access(ap.event_id) or public.field_has_event_access(ap.event_id))
));
create policy "access nodes admin insert" on public.venue_access_point_nodes for insert
with check(exists(
  select 1 from public.venue_access_points ap
  where ap.id=access_point_id and public.can_admin_event(ap.event_id)
));
create policy "access nodes admin update" on public.venue_access_point_nodes for update
using(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)))
with check(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)));
create policy "access nodes admin delete" on public.venue_access_point_nodes for delete
using(exists(select 1 from public.venue_access_points ap where ap.id=access_point_id and public.can_admin_event(ap.event_id)));

grant select,insert,update,delete on public.event_map_layers,public.event_zones,public.venue_access_points,public.venue_access_point_nodes to authenticated;

-- ---------------- v2 incident creation ----------------
create or replace function public.create_incident_v2(
  p_event_id uuid,
  p_department_ids uuid[],
  p_call_type text,
  p_priority text,
  p_latitude double precision,
  p_longitude double precision,
  p_map_x double precision,
  p_map_y double precision,
  p_w3w text,
  p_landmark text,
  p_notes text,
  p_poi_id uuid default null,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare n integer; prefix text; number text; iid uuid; d uuid;
begin
  if not public.can_dispatch_event(p_event_id) then raise exception 'Dispatch access required'; end if;
  if array_length(p_department_ids,1) is null then raise exception 'At least one department is required'; end if;

  if p_map_layer_id is not null and not exists(select 1 from public.event_map_layers where id=p_map_layer_id and event_id=p_event_id and active=true) then
    raise exception 'Map layer is not part of this event';
  end if;
  if p_zone_id is not null and not exists(select 1 from public.event_zones where id=p_zone_id and event_id=p_event_id and active=true) then
    raise exception 'Zone is not part of this event';
  end if;

  update public.events set next_incident_number=next_incident_number+1 where id=p_event_id
  returning next_incident_number-1,incident_prefix into n,prefix;
  number:=prefix||'-'||lpad(n::text,3,'0');

  insert into public.incidents(
    event_id,incident_number,call_type,priority,poi_id,map_layer_id,zone_id,
    latitude,longitude,map_x,map_y,w3w,landmark,notes,created_by
  ) values(
    p_event_id,number,p_call_type,p_priority,p_poi_id,p_map_layer_id,p_zone_id,
    p_latitude,p_longitude,p_map_x,p_map_y,p_w3w,p_landmark,p_notes,auth.uid()
  ) returning id into iid;

  foreach d in array p_department_ids loop
    insert into public.incident_departments(incident_id,department_id)
    select iid,d where exists(select 1 from public.event_departments where id=d and event_id=p_event_id);
  end loop;

  insert into public.cad_activity(event_id,incident_id,action,detail,actor_user_id,actor_kind)
  values(p_event_id,iid,'INCIDENT_CREATED',jsonb_build_object(
    'incident_number',number,'call_type',p_call_type,'map_layer_id',p_map_layer_id,'zone_id',p_zone_id
  ),auth.uid(),'staff');
  return iid;
end;
$$;

grant execute on function public.create_incident_v2(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,text,uuid,uuid,uuid) to authenticated;

create or replace function public.staff_set_unit_location(
  p_unit_id uuid,
  p_map_layer_id uuid default null,
  p_zone_id uuid default null,
  p_poi_id uuid default null
) returns void
language plpgsql security definer set search_path=public
as $$
declare eid uuid;
begin
  select event_id into eid from public.units where id=p_unit_id and active=true;
  if eid is null then raise exception 'Active unit not found'; end if;
  if not public.can_dispatch_event(eid) then raise exception 'Dispatch access required'; end if;

  if p_map_layer_id is not null and not exists(select 1 from public.event_map_layers where id=p_map_layer_id and event_id=eid) then raise exception 'Invalid map layer'; end if;
  if p_zone_id is not null and not exists(select 1 from public.event_zones where id=p_zone_id and event_id=eid) then raise exception 'Invalid zone'; end if;
  if p_poi_id is not null and not exists(select 1 from public.event_pois where id=p_poi_id and event_id=eid) then raise exception 'Invalid POI'; end if;

  update public.units set current_map_layer_id=p_map_layer_id,current_zone_id=p_zone_id,current_poi_id=p_poi_id where id=p_unit_id;
  insert into public.cad_activity(event_id,unit_id,action,detail,actor_user_id,actor_kind)
  values(eid,p_unit_id,'UNIT_LOCATION_CHANGED',jsonb_build_object('map_layer_id',p_map_layer_id,'zone_id',p_zone_id,'poi_id',p_poi_id),auth.uid(),'staff');
end;
$$;

grant execute on function public.staff_set_unit_location(uuid,uuid,uuid,uuid) to authenticated;
