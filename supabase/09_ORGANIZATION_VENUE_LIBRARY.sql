-- CommCenter Pro v0.5.0
-- Organization Venue Library
--
-- Adds reusable, versioned organization-level venue templates.
-- Events receive copied snapshots of venue maps/POIs/zones/access points.
-- Historical events never change when a venue template gets a new version.

create table if not exists public.organization_venues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  slug text not null,
  venue_type text not null default 'outdoor'
    check(venue_type in ('outdoor','multi_level','hybrid')),
  address text,
  active boolean not null default true,
  current_version_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,slug)
);

create table if not exists public.organization_venue_versions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.organization_venues(id) on delete cascade,
  version_number integer not null,
  status text not null default 'draft'
    check(status in ('draft','published','archived')),
  source_event_id uuid references public.events(id) on delete set null,
  notes text,
  offline_w3w_path text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique(venue_id,version_number)
);

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='organization_venues_current_version_fk'
  ) then
    alter table public.organization_venues
      add constraint organization_venues_current_version_fk
      foreign key(current_version_id)
      references public.organization_venue_versions(id)
      on delete set null;
  end if;
end $$;

create table if not exists public.organization_venue_map_layers (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  source_event_layer_id uuid,
  name text not null,
  short_name text,
  level_code text,
  level_number integer,
  level_type text not null default 'venue'
    check(level_type in ('exterior','field','concourse','suite','deck','back_of_house','parking','venue','other')),
  sort_order integer not null default 100,
  source_pdf_path text,
  rendered_image_path text,
  image_width integer,
  image_height integer,
  georef_method text,
  georef_coefficients jsonb,
  georef_rmse_m double precision,
  georef_max_error_m double precision,
  source_status text not null default 'draft',
  is_default boolean not null default false,
  source_published_at timestamptz,
  created_at timestamptz not null default now(),
  unique(version_id,name)
);

create table if not exists public.organization_venue_map_control_points (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid not null references public.organization_venue_map_layers(id) on delete cascade,
  label text not null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision not null,
  longitude double precision not null,
  residual_m double precision,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_venue_zones (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid references public.organization_venue_map_layers(id) on delete cascade,
  source_event_zone_id uuid,
  name text not null,
  short_name text,
  category text,
  notes text,
  sort_order integer not null default 100,
  active boolean not null default true,
  unique(version_id,map_layer_id,name)
);

create table if not exists public.organization_venue_w3w_squares (
  id bigint generated always as identity primary key,
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  words text not null,
  south double precision not null,
  north double precision not null,
  west double precision not null,
  east double precision not null,
  center_lat double precision,
  center_lon double precision,
  unique(version_id,words)
);

create table if not exists public.organization_venue_pois (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  map_layer_id uuid references public.organization_venue_map_layers(id) on delete set null,
  zone_id uuid references public.organization_venue_zones(id) on delete set null,
  source_event_poi_id uuid,
  name text not null,
  category text,
  w3w text,
  latitude double precision not null,
  longitude double precision not null,
  map_x double precision not null,
  map_y double precision not null,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_venue_poi_aliases (
  id bigint generated always as identity primary key,
  poi_id uuid not null references public.organization_venue_pois(id) on delete cascade,
  alias text not null,
  unique(poi_id,alias)
);

create table if not exists public.organization_venue_access_points (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.organization_venue_versions(id) on delete cascade,
  source_event_access_point_id uuid,
  name text not null,
  access_type text not null
    check(access_type in ('elevator','stairwell','escalator','ramp','portal','vomitory','tunnel','gate','corridor','other')),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(version_id,name)
);

create table if not exists public.organization_venue_access_point_nodes (
  id uuid primary key default gen_random_uuid(),
  access_point_id uuid not null references public.organization_venue_access_points(id) on delete cascade,
  map_layer_id uuid not null references public.organization_venue_map_layers(id) on delete cascade,
  zone_id uuid references public.organization_venue_zones(id) on delete set null,
  map_x double precision not null,
  map_y double precision not null,
  latitude double precision,
  longitude double precision,
  w3w text,
  instructions text,
  created_at timestamptz not null default now(),
  unique(access_point_id,map_layer_id)
);

create index if not exists org_venues_org_idx
  on public.organization_venues(organization_id,name);
create index if not exists org_venue_versions_venue_idx
  on public.organization_venue_versions(venue_id,version_number desc);
create index if not exists org_venue_layers_version_idx
  on public.organization_venue_map_layers(version_id,sort_order);
create index if not exists org_venue_zones_version_idx
  on public.organization_venue_zones(version_id,map_layer_id,sort_order);
create index if not exists org_venue_pois_version_idx
  on public.organization_venue_pois(version_id,name);
create index if not exists org_venue_w3w_bounds_idx
  on public.organization_venue_w3w_squares(version_id,south,north,west,east);

alter table public.events
  add column if not exists venue_id uuid references public.organization_venues(id) on delete set null,
  add column if not exists venue_version_id uuid references public.organization_venue_versions(id) on delete set null;

alter table public.event_map_layers
  add column if not exists source_venue_layer_id uuid references public.organization_venue_map_layers(id) on delete set null;

alter table public.event_zones
  add column if not exists source_venue_zone_id uuid references public.organization_venue_zones(id) on delete set null;

alter table public.event_pois
  add column if not exists source_venue_poi_id uuid references public.organization_venue_pois(id) on delete set null,
  add column if not exists poi_scope text not null default 'event'
    check(poi_scope in ('event','venue_snapshot'));

-- ---------------- Venue access helpers ----------------

create or replace function public.has_venue_version_access(p_version uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.organization_venue_versions vv
    join public.organization_venues v on v.id=vv.venue_id
    where vv.id=p_version
      and public.has_org_access(v.organization_id)
  );
$$;

create or replace function public.can_admin_venue_version(p_version uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.organization_venue_versions vv
    join public.organization_venues v on v.id=vv.venue_id
    where vv.id=p_version
      and public.is_org_admin(v.organization_id)
  );
$$;

create or replace function public.storage_venue_access(object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,storage
as $$
declare
  folders text[];
  oid uuid;
begin
  folders:=storage.foldername(object_name);
  if array_length(folders,1)<2 or folders[1]<>'venues' then return false; end if;
  if folders[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  oid:=folders[2]::uuid;
  return public.has_org_access(oid);
end;
$$;

create or replace function public.storage_venue_admin(object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,storage
as $$
declare
  folders text[];
  oid uuid;
begin
  folders:=storage.foldername(object_name);
  if array_length(folders,1)<2 or folders[1]<>'venues' then return false; end if;
  if folders[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  oid:=folders[2]::uuid;
  return public.is_org_admin(oid);
end;
$$;

-- ---------------- RLS ----------------

alter table public.organization_venues enable row level security;
alter table public.organization_venue_versions enable row level security;
alter table public.organization_venue_map_layers enable row level security;
alter table public.organization_venue_map_control_points enable row level security;
alter table public.organization_venue_zones enable row level security;
alter table public.organization_venue_w3w_squares enable row level security;
alter table public.organization_venue_pois enable row level security;
alter table public.organization_venue_poi_aliases enable row level security;
alter table public.organization_venue_access_points enable row level security;
alter table public.organization_venue_access_point_nodes enable row level security;

drop policy if exists "organization venues read" on public.organization_venues;
drop policy if exists "organization venues insert" on public.organization_venues;
drop policy if exists "organization venues update" on public.organization_venues;
drop policy if exists "organization venues delete" on public.organization_venues;

create policy "organization venues read"
on public.organization_venues for select to authenticated
using(public.has_org_access(organization_id));

create policy "organization venues insert"
on public.organization_venues for insert to authenticated
with check(public.is_org_admin(organization_id));

create policy "organization venues update"
on public.organization_venues for update to authenticated
using(public.is_org_admin(organization_id))
with check(public.is_org_admin(organization_id));

create policy "organization venues delete"
on public.organization_venues for delete to authenticated
using(public.is_org_admin(organization_id));

drop policy if exists "organization venue versions read" on public.organization_venue_versions;
drop policy if exists "organization venue versions insert" on public.organization_venue_versions;
drop policy if exists "organization venue versions update" on public.organization_venue_versions;
drop policy if exists "organization venue versions delete" on public.organization_venue_versions;

create policy "organization venue versions read"
on public.organization_venue_versions for select to authenticated
using(public.has_venue_version_access(id));

create policy "organization venue versions insert"
on public.organization_venue_versions for insert to authenticated
with check(exists(
  select 1 from public.organization_venues v
  where v.id=venue_id and public.is_org_admin(v.organization_id)
));

create policy "organization venue versions update"
on public.organization_venue_versions for update to authenticated
using(public.can_admin_venue_version(id))
with check(public.can_admin_venue_version(id));

create policy "organization venue versions delete"
on public.organization_venue_versions for delete to authenticated
using(public.can_admin_venue_version(id));

drop policy if exists "organization venue layers read" on public.organization_venue_map_layers;
drop policy if exists "organization venue layers write" on public.organization_venue_map_layers;
drop policy if exists "organization venue control points read" on public.organization_venue_map_control_points;
drop policy if exists "organization venue control points write" on public.organization_venue_map_control_points;
drop policy if exists "organization venue zones read" on public.organization_venue_zones;
drop policy if exists "organization venue zones write" on public.organization_venue_zones;
drop policy if exists "organization venue w3w read" on public.organization_venue_w3w_squares;
drop policy if exists "organization venue w3w write" on public.organization_venue_w3w_squares;
drop policy if exists "organization venue pois read" on public.organization_venue_pois;
drop policy if exists "organization venue pois write" on public.organization_venue_pois;
drop policy if exists "organization venue poi aliases read" on public.organization_venue_poi_aliases;
drop policy if exists "organization venue poi aliases write" on public.organization_venue_poi_aliases;
drop policy if exists "organization venue access read" on public.organization_venue_access_points;
drop policy if exists "organization venue access write" on public.organization_venue_access_points;
drop policy if exists "organization venue access nodes read" on public.organization_venue_access_point_nodes;
drop policy if exists "organization venue access nodes write" on public.organization_venue_access_point_nodes;

create policy "organization venue layers read"
on public.organization_venue_map_layers for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue layers write"
on public.organization_venue_map_layers for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue control points read"
on public.organization_venue_map_control_points for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue control points write"
on public.organization_venue_map_control_points for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue zones read"
on public.organization_venue_zones for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue zones write"
on public.organization_venue_zones for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue w3w read"
on public.organization_venue_w3w_squares for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue w3w write"
on public.organization_venue_w3w_squares for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue pois read"
on public.organization_venue_pois for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue pois write"
on public.organization_venue_pois for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue poi aliases read"
on public.organization_venue_poi_aliases for select to authenticated
using(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.has_venue_version_access(p.version_id)
));
create policy "organization venue poi aliases write"
on public.organization_venue_poi_aliases for all to authenticated
using(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.can_admin_venue_version(p.version_id)
))
with check(exists(
  select 1 from public.organization_venue_pois p
  where p.id=poi_id and public.can_admin_venue_version(p.version_id)
));

create policy "organization venue access read"
on public.organization_venue_access_points for select to authenticated
using(public.has_venue_version_access(version_id));
create policy "organization venue access write"
on public.organization_venue_access_points for all to authenticated
using(public.can_admin_venue_version(version_id))
with check(public.can_admin_venue_version(version_id));

create policy "organization venue access nodes read"
on public.organization_venue_access_point_nodes for select to authenticated
using(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.has_venue_version_access(ap.version_id)
));
create policy "organization venue access nodes write"
on public.organization_venue_access_point_nodes for all to authenticated
using(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.can_admin_venue_version(ap.version_id)
))
with check(exists(
  select 1 from public.organization_venue_access_points ap
  where ap.id=access_point_id and public.can_admin_venue_version(ap.version_id)
));

grant select,insert,update,delete on
  public.organization_venues,
  public.organization_venue_versions,
  public.organization_venue_map_layers,
  public.organization_venue_map_control_points,
  public.organization_venue_zones,
  public.organization_venue_w3w_squares,
  public.organization_venue_pois,
  public.organization_venue_poi_aliases,
  public.organization_venue_access_points,
  public.organization_venue_access_point_nodes
to authenticated;

-- Extend the existing private bucket policies to organization venue assets.
drop policy if exists "CommCenter event asset read" on storage.objects;
drop policy if exists "CommCenter event asset insert" on storage.objects;
drop policy if exists "CommCenter event asset update" on storage.objects;
drop policy if exists "CommCenter event asset delete" on storage.objects;

create policy "CommCenter event asset read"
on storage.objects for select to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_access(name) or public.storage_venue_access(name))
);

create policy "CommCenter event asset insert"
on storage.objects for insert to authenticated
with check(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

create policy "CommCenter event asset update"
on storage.objects for update to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
)
with check(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

create policy "CommCenter event asset delete"
on storage.objects for delete to authenticated
using(
  bucket_id='event-assets'
  and (public.storage_event_admin(name) or public.storage_venue_admin(name))
);

-- ---------------- RPC: organization venue picker ----------------

create or replace function public.organization_venue_choices(p_organization_id uuid)
returns table(
  venue_id uuid,
  venue_name text,
  venue_type text,
  address text,
  version_id uuid,
  version_number integer
)
language sql
stable
security definer
set search_path=public
as $$
  select
    v.id,
    v.name,
    v.venue_type,
    v.address,
    vv.id,
    vv.version_number
  from public.organization_venues v
  join public.organization_venue_versions vv
    on vv.id=v.current_version_id
   and vv.status='published'
  where v.organization_id=p_organization_id
    and v.active=true
    and public.has_org_access(p_organization_id)
  order by v.name;
$$;

grant execute on function public.organization_venue_choices(uuid) to authenticated;

-- ---------------- RPC: save event into a new immutable venue version ----------------

create or replace function public.save_event_as_venue_version(
  p_event_id uuid,
  p_venue_id uuid default null,
  p_venue_name text default null,
  p_address text default null,
  p_notes text default null,
  p_include_event_pois boolean default false
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
  venue_row public.organization_venues;
  new_venue_id uuid;
  new_version_id uuid;
  new_version_number integer;
  layer_row record;
  new_layer_id uuid;
  zone_row record;
  new_zone_id uuid;
  poi_row record;
  new_poi_id uuid;
  ap_row record;
  new_ap_id uuid;
  node_row record;
  mapped_layer_id uuid;
  mapped_zone_id uuid;
  layer_payload jsonb:='[]'::jsonb;
  generated_slug text;
begin
  select * into e from public.events where id=p_event_id;
  if e.id is null then raise exception 'Event not found'; end if;
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;
  if not public.is_org_admin(e.organization_id) then
    raise exception 'Organization admin access is required to save a reusable venue';
  end if;

  if p_venue_id is null then
    if trim(coalesce(p_venue_name,''))='' then raise exception 'Venue name is required'; end if;
    generated_slug:=trim(both '-' from regexp_replace(lower(trim(p_venue_name)),'[^a-z0-9]+','-','g'));
    if generated_slug='' then generated_slug:='venue'; end if;
    if exists(select 1 from public.organization_venues where organization_id=e.organization_id and slug=generated_slug) then
      generated_slug:=generated_slug||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6);
    end if;

    insert into public.organization_venues(
      organization_id,name,slug,venue_type,address
    ) values(
      e.organization_id,trim(p_venue_name),generated_slug,coalesce(e.venue_type,'outdoor'),nullif(trim(p_address),'')
    )
    returning * into venue_row;

    new_venue_id:=venue_row.id;
  else
    select * into venue_row
    from public.organization_venues
    where id=p_venue_id and organization_id=e.organization_id and active=true;

    if venue_row.id is null then raise exception 'Venue does not belong to this organization'; end if;
    new_venue_id:=venue_row.id;

    update public.organization_venues
    set venue_type=coalesce(e.venue_type,venue_type),
        address=coalesce(nullif(trim(p_address),''),address),
        updated_at=now()
    where id=new_venue_id;
  end if;

  select coalesce(max(version_number),0)+1
  into new_version_number
  from public.organization_venue_versions
  where venue_id=new_venue_id;

  insert into public.organization_venue_versions(
    venue_id,version_number,status,source_event_id,notes,created_by
  ) values(
    new_venue_id,new_version_number,'draft',p_event_id,nullif(trim(p_notes),''),auth.uid()
  )
  returning id into new_version_id;

  -- Reusable W3W square library. Server-side insert/select avoids browser-sized transfers.
  insert into public.organization_venue_w3w_squares(
    version_id,words,south,north,west,east,center_lat,center_lon
  )
  select
    new_version_id,words,south,north,west,east,center_lat,center_lon
  from public.event_w3w_squares
  where event_id=p_event_id;

  -- Layers + calibration.
  for layer_row in
    select * from public.event_map_layers
    where event_id=p_event_id and active=true
    order by sort_order,name
  loop
    insert into public.organization_venue_map_layers(
      version_id,source_event_layer_id,name,short_name,level_code,level_number,level_type,sort_order,
      image_width,image_height,georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
      source_status,is_default,source_published_at
    ) values(
      new_version_id,layer_row.id,layer_row.name,layer_row.short_name,layer_row.level_code,
      layer_row.level_number,layer_row.level_type,layer_row.sort_order,
      layer_row.image_width,layer_row.image_height,layer_row.georef_method,layer_row.georef_coefficients,
      layer_row.georef_rmse_m,layer_row.georef_max_error_m,
      layer_row.status,layer_row.is_default,layer_row.published_at
    )
    returning id into new_layer_id;

    insert into public.organization_venue_map_control_points(
      version_id,map_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    )
    select
      new_version_id,new_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    from public.map_control_points
    where event_id=p_event_id and map_layer_id=layer_row.id;

    layer_payload:=layer_payload||jsonb_build_array(jsonb_build_object(
      'venue_layer_id',new_layer_id,
      'name',layer_row.name,
      'source_pdf_path',layer_row.source_pdf_path,
      'rendered_image_path',layer_row.rendered_image_path
    ));
  end loop;

  -- Zones.
  for zone_row in
    select * from public.event_zones
    where event_id=p_event_id and active=true
    order by sort_order,name
  loop
    select id into mapped_layer_id
    from public.organization_venue_map_layers
    where version_id=new_version_id
      and source_event_layer_id=zone_row.map_layer_id
    limit 1;

    insert into public.organization_venue_zones(
      version_id,map_layer_id,source_event_zone_id,name,short_name,category,notes,sort_order,active
    ) values(
      new_version_id,mapped_layer_id,zone_row.id,zone_row.name,zone_row.short_name,
      zone_row.category,zone_row.notes,zone_row.sort_order,zone_row.active
    );
  end loop;

  -- POIs. If this event is already based on a venue, event-only overlays are
  -- excluded unless the admin explicitly promotes them into the new venue version.
  for poi_row in
    select *
    from public.event_pois
    where event_id=p_event_id
      and active=true
      and (
        e.venue_id is null
        or poi_scope='venue_snapshot'
        or p_include_event_pois=true
      )
    order by name
  loop
    select id into mapped_layer_id
    from public.organization_venue_map_layers
    where version_id=new_version_id
      and source_event_layer_id=poi_row.map_layer_id
    limit 1;

    mapped_zone_id:=null;
    if poi_row.zone_id is not null then
      select id into mapped_zone_id
      from public.organization_venue_zones
      where version_id=new_version_id
        and source_event_zone_id=poi_row.zone_id
      limit 1;
    end if;

    insert into public.organization_venue_pois(
      version_id,map_layer_id,zone_id,source_event_poi_id,name,category,w3w,
      latitude,longitude,map_x,map_y,notes,active
    ) values(
      new_version_id,mapped_layer_id,mapped_zone_id,poi_row.id,poi_row.name,poi_row.category,poi_row.w3w,
      poi_row.latitude,poi_row.longitude,poi_row.map_x,poi_row.map_y,poi_row.notes,poi_row.active
    )
    returning id into new_poi_id;

    insert into public.organization_venue_poi_aliases(poi_id,alias)
    select new_poi_id,alias
    from public.poi_aliases
    where poi_id=poi_row.id;
  end loop;

  -- Vertical access routes and per-level nodes.
  for ap_row in
    select * from public.venue_access_points
    where event_id=p_event_id and active=true
    order by name
  loop
    insert into public.organization_venue_access_points(
      version_id,source_event_access_point_id,name,access_type,notes,active
    ) values(
      new_version_id,ap_row.id,ap_row.name,ap_row.access_type,ap_row.notes,ap_row.active
    )
    returning id into new_ap_id;

    for node_row in
      select * from public.venue_access_point_nodes
      where access_point_id=ap_row.id
    loop
      select id into mapped_layer_id
      from public.organization_venue_map_layers
      where version_id=new_version_id
        and source_event_layer_id=node_row.map_layer_id
      limit 1;

      mapped_zone_id:=null;
      if node_row.zone_id is not null then
        select id into mapped_zone_id
        from public.organization_venue_zones
        where version_id=new_version_id
          and source_event_zone_id=node_row.zone_id
        limit 1;
      end if;

      if mapped_layer_id is not null then
        insert into public.organization_venue_access_point_nodes(
          access_point_id,map_layer_id,zone_id,map_x,map_y,latitude,longitude,w3w,instructions
        ) values(
          new_ap_id,mapped_layer_id,mapped_zone_id,node_row.map_x,node_row.map_y,
          node_row.latitude,node_row.longitude,node_row.w3w,node_row.instructions
        );
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'organization_id',e.organization_id,
    'venue_id',new_venue_id,
    'venue_name',coalesce(venue_row.name,p_venue_name),
    'version_id',new_version_id,
    'version_number',new_version_number,
    'source_offline_w3w_path',e.offline_w3w_path,
    'layers',layer_payload
  );
end;
$$;

grant execute on function public.save_event_as_venue_version(uuid,uuid,text,text,text,boolean) to authenticated;

create or replace function public.publish_venue_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  vv public.organization_venue_versions;
  oid uuid;
begin
  select * into vv from public.organization_venue_versions where id=p_version_id;
  if vv.id is null then raise exception 'Venue version not found'; end if;

  select organization_id into oid
  from public.organization_venues
  where id=vv.venue_id;

  if not public.is_org_admin(oid) then
    raise exception 'Organization admin access required';
  end if;

  update public.organization_venue_versions
  set status='archived'
  where venue_id=vv.venue_id
    and id<>p_version_id
    and status='published';

  update public.organization_venue_versions
  set status='published',published_at=now()
  where id=p_version_id;

  update public.organization_venues
  set current_version_id=p_version_id,updated_at=now()
  where id=vv.venue_id;

  if vv.source_event_id is not null then
    update public.events
    set venue_id=vv.venue_id,
        venue_version_id=p_version_id
    where id=vv.source_event_id;
  end if;
end;
$$;

grant execute on function public.publish_venue_version(uuid) to authenticated;

-- ---------------- RPC: clone published venue into an event snapshot ----------------

create or replace function public.apply_venue_version_to_event(
  p_event_id uuid,
  p_version_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.events;
  vv public.organization_venue_versions;
  venue_row public.organization_venues;
  venue_layer record;
  event_layer_id uuid;
  zone_row record;
  event_zone_id uuid;
  poi_row record;
  event_poi_id uuid;
  ap_row record;
  event_ap_id uuid;
  node_row record;
  mapped_event_layer_id uuid;
  mapped_event_zone_id uuid;
  layer_payload jsonb:='[]'::jsonb;
begin
  select * into e from public.events where id=p_event_id;
  if e.id is null then raise exception 'Event not found'; end if;
  if not public.can_admin_event(p_event_id) then raise exception 'Event admin access required'; end if;

  select * into vv
  from public.organization_venue_versions
  where id=p_version_id and status='published';
  if vv.id is null then raise exception 'Published venue version not found'; end if;

  select * into venue_row
  from public.organization_venues
  where id=vv.venue_id and organization_id=e.organization_id and active=true;
  if venue_row.id is null then raise exception 'Venue does not belong to this event organization'; end if;

  if exists(select 1 from public.event_map_layers where event_id=p_event_id)
     or exists(select 1 from public.event_pois where event_id=p_event_id)
     or exists(select 1 from public.event_zones where event_id=p_event_id)
     or exists(select 1 from public.venue_access_points where event_id=p_event_id)
  then
    raise exception 'This event already has map configuration. Apply a venue only to a blank event map.';
  end if;

  insert into public.event_w3w_squares(
    event_id,words,south,north,west,east,center_lat,center_lon
  )
  select
    p_event_id,words,south,north,west,east,center_lat,center_lon
  from public.organization_venue_w3w_squares
  where version_id=p_version_id
  on conflict(event_id,words) do nothing;

  for venue_layer in
    select * from public.organization_venue_map_layers
    where version_id=p_version_id
    order by sort_order,name
  loop
    insert into public.event_map_layers(
      event_id,source_venue_layer_id,name,short_name,level_code,level_number,level_type,sort_order,
      image_width,image_height,georef_method,georef_coefficients,georef_rmse_m,georef_max_error_m,
      status,is_default,active
    ) values(
      p_event_id,venue_layer.id,venue_layer.name,venue_layer.short_name,venue_layer.level_code,
      venue_layer.level_number,venue_layer.level_type,venue_layer.sort_order,
      venue_layer.image_width,venue_layer.image_height,venue_layer.georef_method,venue_layer.georef_coefficients,
      venue_layer.georef_rmse_m,venue_layer.georef_max_error_m,
      'draft',venue_layer.is_default,true
    )
    returning id into event_layer_id;

    insert into public.map_control_points(
      event_id,map_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    )
    select
      p_event_id,event_layer_id,label,map_x,map_y,latitude,longitude,residual_m
    from public.organization_venue_map_control_points
    where version_id=p_version_id
      and map_layer_id=venue_layer.id;

    layer_payload:=layer_payload||jsonb_build_array(jsonb_build_object(
      'event_layer_id',event_layer_id,
      'venue_layer_id',venue_layer.id,
      'name',venue_layer.name,
      'source_pdf_path',venue_layer.source_pdf_path,
      'rendered_image_path',venue_layer.rendered_image_path,
      'source_status',venue_layer.source_status,
      'source_published_at',venue_layer.source_published_at
    ));
  end loop;

  for zone_row in
    select * from public.organization_venue_zones
    where version_id=p_version_id and active=true
    order by sort_order,name
  loop
    select id into mapped_event_layer_id
    from public.event_map_layers
    where event_id=p_event_id
      and source_venue_layer_id=zone_row.map_layer_id
    limit 1;

    insert into public.event_zones(
      event_id,map_layer_id,source_venue_zone_id,name,short_name,category,notes,sort_order,active
    ) values(
      p_event_id,mapped_event_layer_id,zone_row.id,zone_row.name,zone_row.short_name,
      zone_row.category,zone_row.notes,zone_row.sort_order,zone_row.active
    );
  end loop;

  for poi_row in
    select * from public.organization_venue_pois
    where version_id=p_version_id and active=true
    order by name
  loop
    mapped_event_layer_id:=null;
    mapped_event_zone_id:=null;

    if poi_row.map_layer_id is not null then
      select id into mapped_event_layer_id
      from public.event_map_layers
      where event_id=p_event_id
        and source_venue_layer_id=poi_row.map_layer_id
      limit 1;
    end if;

    if poi_row.zone_id is not null then
      select id into mapped_event_zone_id
      from public.event_zones
      where event_id=p_event_id
        and source_venue_zone_id=poi_row.zone_id
      limit 1;
    end if;

    insert into public.event_pois(
      event_id,map_layer_id,zone_id,source_venue_poi_id,poi_scope,
      name,category,w3w,latitude,longitude,map_x,map_y,notes,active
    ) values(
      p_event_id,mapped_event_layer_id,mapped_event_zone_id,poi_row.id,'venue_snapshot',
      poi_row.name,poi_row.category,poi_row.w3w,poi_row.latitude,poi_row.longitude,
      poi_row.map_x,poi_row.map_y,poi_row.notes,poi_row.active
    )
    returning id into event_poi_id;

    insert into public.poi_aliases(poi_id,alias)
    select event_poi_id,alias
    from public.organization_venue_poi_aliases
    where poi_id=poi_row.id;
  end loop;

  for ap_row in
    select * from public.organization_venue_access_points
    where version_id=p_version_id and active=true
    order by name
  loop
    insert into public.venue_access_points(
      event_id,name,access_type,notes,active
    ) values(
      p_event_id,ap_row.name,ap_row.access_type,ap_row.notes,ap_row.active
    )
    returning id into event_ap_id;

    for node_row in
      select * from public.organization_venue_access_point_nodes
      where access_point_id=ap_row.id
    loop
      select id into mapped_event_layer_id
      from public.event_map_layers
      where event_id=p_event_id
        and source_venue_layer_id=node_row.map_layer_id
      limit 1;

      mapped_event_zone_id:=null;
      if node_row.zone_id is not null then
        select id into mapped_event_zone_id
        from public.event_zones
        where event_id=p_event_id
          and source_venue_zone_id=node_row.zone_id
        limit 1;
      end if;

      if mapped_event_layer_id is not null then
        insert into public.venue_access_point_nodes(
          access_point_id,map_layer_id,zone_id,map_x,map_y,latitude,longitude,w3w,instructions
        ) values(
          event_ap_id,mapped_event_layer_id,mapped_event_zone_id,
          node_row.map_x,node_row.map_y,node_row.latitude,node_row.longitude,node_row.w3w,node_row.instructions
        );
      end if;
    end loop;
  end loop;

  update public.events
  set venue_id=venue_row.id,
      venue_version_id=vv.id,
      venue_type=venue_row.venue_type
  where id=p_event_id;

  return jsonb_build_object(
    'venue_id',venue_row.id,
    'venue_name',venue_row.name,
    'version_id',vv.id,
    'version_number',vv.version_number,
    'offline_w3w_path',vv.offline_w3w_path,
    'layers',layer_payload
  );
end;
$$;

grant execute on function public.apply_venue_version_to_event(uuid,uuid) to authenticated;
