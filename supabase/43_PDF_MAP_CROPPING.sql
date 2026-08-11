-- CommCenter Pro v0.14.6
-- PDF crop metadata and safe coordinate-preserving recrop support.

alter table public.event_map_layers
  add column if not exists pdf_crop_x double precision not null default 0,
  add column if not exists pdf_crop_y double precision not null default 0,
  add column if not exists pdf_crop_width double precision not null default 1,
  add column if not exists pdf_crop_height double precision not null default 1;

alter table public.organization_venue_map_layers
  add column if not exists pdf_crop_x double precision not null default 0,
  add column if not exists pdf_crop_y double precision not null default 0,
  add column if not exists pdf_crop_width double precision not null default 1,
  add column if not exists pdf_crop_height double precision not null default 1;

create or replace function public.admin_apply_event_map_crop(
  p_map_layer_id uuid,
  p_source_pdf_path text,
  p_rendered_image_path text,
  p_image_width integer,
  p_image_height integer,
  p_crop_x double precision,
  p_crop_y double precision,
  p_crop_width double precision,
  p_crop_height double precision,
  p_source_replaced boolean default false
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  layer_row public.event_map_layers%rowtype;
  old_x double precision;
  old_y double precision;
  old_w double precision;
  old_h double precision;
  cx double precision;
  cy double precision;
  sx double precision;
  sy double precision;
  outside_count integer;
  new_coeff jsonb;
  lat0 double precision;
  lat1 double precision;
  lat2 double precision;
  lon0 double precision;
  lon1 double precision;
  lon2 double precision;
begin
  select * into layer_row
  from public.event_map_layers
  where id=p_map_layer_id
  for update;

  if not found then
    raise exception 'Map layer not found';
  end if;

  if not public.can_admin_event(layer_row.event_id) then
    raise exception 'Event admin access required';
  end if;

  if p_source_pdf_path is null or p_rendered_image_path is null then
    raise exception 'Source PDF and rendered map paths are required';
  end if;

  if coalesce(p_image_width,0)<50 or coalesce(p_image_height,0)<50 then
    raise exception 'Rendered map is too small';
  end if;

  if p_crop_x<0 or p_crop_y<0
     or p_crop_width<=0 or p_crop_height<=0
     or p_crop_x+p_crop_width>1.000001
     or p_crop_y+p_crop_height>1.000001 then
    raise exception 'Invalid PDF crop rectangle';
  end if;

  -- A completely different source PDF cannot safely inherit the existing
  -- pixel coordinate system. The UI directs configured maps to recrop the
  -- retained source instead.
  if p_source_replaced
     and layer_row.rendered_image_path is not null
     and (
       layer_row.georef_coefficients is not null
       or exists(select 1 from public.map_control_points cp where cp.map_layer_id=p_map_layer_id)
       or exists(select 1 from public.event_pois p where p.map_layer_id=p_map_layer_id)
       or exists(select 1 from public.venue_access_point_nodes n where n.map_layer_id=p_map_layer_id)
       or exists(select 1 from public.incidents i where i.map_layer_id=p_map_layer_id and i.map_x is not null and i.map_y is not null)
     ) then
    raise exception 'Configured map layers cannot replace the source PDF. Use Crop Current PDF to preserve mapped coordinates.';
  end if;

  -- First render, or safe replacement of an unconfigured source.
  if layer_row.rendered_image_path is null
     or layer_row.image_width is null
     or layer_row.image_height is null
     or p_source_replaced then
    update public.event_map_layers
    set
      source_pdf_path=p_source_pdf_path,
      rendered_image_path=p_rendered_image_path,
      image_width=p_image_width,
      image_height=p_image_height,
      pdf_crop_x=p_crop_x,
      pdf_crop_y=p_crop_y,
      pdf_crop_width=p_crop_width,
      pdf_crop_height=p_crop_height,
      georef_method=case when p_source_replaced then null else georef_method end,
      georef_coefficients=case when p_source_replaced then null else georef_coefficients end,
      georef_rmse_m=case when p_source_replaced then null else georef_rmse_m end,
      georef_max_error_m=case when p_source_replaced then null else georef_max_error_m end,
      status='draft',
      published_at=null,
      updated_at=now()
    where id=p_map_layer_id;
    return;
  end if;

  old_x:=coalesce(layer_row.pdf_crop_x,0);
  old_y:=coalesce(layer_row.pdf_crop_y,0);
  old_w:=coalesce(layer_row.pdf_crop_width,1);
  old_h:=coalesce(layer_row.pdf_crop_height,1);

  -- Do not silently crop away any coordinate-bearing record. This includes
  -- historical incidents/archived POIs because their map history should
  -- remain visually reproducible.
  select count(*) into outside_count
  from (
    select cp.map_x,cp.map_y
    from public.map_control_points cp
    where cp.map_layer_id=p_map_layer_id

    union all

    select p.map_x,p.map_y
    from public.event_pois p
    where p.map_layer_id=p_map_layer_id

    union all

    select n.map_x,n.map_y
    from public.venue_access_point_nodes n
    where n.map_layer_id=p_map_layer_id

    union all

    select i.map_x,i.map_y
    from public.incidents i
    where i.map_layer_id=p_map_layer_id
      and i.map_x is not null
      and i.map_y is not null
  ) mapped
  where
    (old_x + (mapped.map_x/layer_row.image_width)*old_w) < p_crop_x-0.000001
    or (old_x + (mapped.map_x/layer_row.image_width)*old_w) > p_crop_x+p_crop_width+0.000001
    or (old_y + (mapped.map_y/layer_row.image_height)*old_h) < p_crop_y-0.000001
    or (old_y + (mapped.map_y/layer_row.image_height)*old_h) > p_crop_y+p_crop_height+0.000001;

  if outside_count>0 then
    raise exception 'Crop would exclude % mapped point(s). Enlarge the crop so all existing control points, POIs, access points, and incident locations remain inside it.',
      outside_count;
  end if;

  -- Convert old rendered-image pixels -> normalized original PDF page ->
  -- new rendered-image pixels.
  update public.map_control_points
  set
    map_x=(((old_x+(map_x/layer_row.image_width)*old_w)-p_crop_x)/p_crop_width)*p_image_width,
    map_y=(((old_y+(map_y/layer_row.image_height)*old_h)-p_crop_y)/p_crop_height)*p_image_height
  where map_layer_id=p_map_layer_id;

  update public.event_pois
  set
    map_x=(((old_x+(map_x/layer_row.image_width)*old_w)-p_crop_x)/p_crop_width)*p_image_width,
    map_y=(((old_y+(map_y/layer_row.image_height)*old_h)-p_crop_y)/p_crop_height)*p_image_height
  where map_layer_id=p_map_layer_id;

  update public.venue_access_point_nodes
  set
    map_x=(((old_x+(map_x/layer_row.image_width)*old_w)-p_crop_x)/p_crop_width)*p_image_width,
    map_y=(((old_y+(map_y/layer_row.image_height)*old_h)-p_crop_y)/p_crop_height)*p_image_height
  where map_layer_id=p_map_layer_id;

  update public.incidents
  set
    map_x=(((old_x+(map_x/layer_row.image_width)*old_w)-p_crop_x)/p_crop_width)*p_image_width,
    map_y=(((old_y+(map_y/layer_row.image_height)*old_h)-p_crop_y)/p_crop_height)*p_image_height
  where map_layer_id=p_map_layer_id
    and map_x is not null
    and map_y is not null;

  -- Preserve the existing affine georeference exactly under the pixel-space
  -- crop/scale transform.
  if layer_row.georef_coefficients is not null
     and layer_row.georef_coefficients ? 'lat'
     and layer_row.georef_coefficients ? 'lon' then

    cx:=layer_row.image_width*(p_crop_x-old_x)/old_w;
    cy:=layer_row.image_height*(p_crop_y-old_y)/old_h;
    sx:=layer_row.image_width*p_crop_width/(old_w*p_image_width);
    sy:=layer_row.image_height*p_crop_height/(old_h*p_image_height);

    lat0:=(layer_row.georef_coefficients->'lat'->>0)::double precision;
    lat1:=(layer_row.georef_coefficients->'lat'->>1)::double precision;
    lat2:=(layer_row.georef_coefficients->'lat'->>2)::double precision;
    lon0:=(layer_row.georef_coefficients->'lon'->>0)::double precision;
    lon1:=(layer_row.georef_coefficients->'lon'->>1)::double precision;
    lon2:=(layer_row.georef_coefficients->'lon'->>2)::double precision;

    new_coeff:=jsonb_build_object(
      'lat',jsonb_build_array(
        lat0+lat1*cx+lat2*cy,
        lat1*sx,
        lat2*sy
      ),
      'lon',jsonb_build_array(
        lon0+lon1*cx+lon2*cy,
        lon1*sx,
        lon2*sy
      )
    );
  else
    new_coeff:=layer_row.georef_coefficients;
  end if;

  update public.event_map_layers
  set
    source_pdf_path=p_source_pdf_path,
    rendered_image_path=p_rendered_image_path,
    image_width=p_image_width,
    image_height=p_image_height,
    pdf_crop_x=p_crop_x,
    pdf_crop_y=p_crop_y,
    pdf_crop_width=p_crop_width,
    pdf_crop_height=p_crop_height,
    georef_coefficients=new_coeff,
    updated_at=now()
  where id=p_map_layer_id;
end;
$$;

revoke all on function public.admin_apply_event_map_crop(
  uuid,text,text,integer,integer,double precision,double precision,double precision,double precision,boolean
) from public;

grant execute on function public.admin_apply_event_map_crop(
  uuid,text,text,integer,integer,double precision,double precision,double precision,double precision,boolean
) to authenticated;
