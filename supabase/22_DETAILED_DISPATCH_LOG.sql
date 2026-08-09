-- CommCenter Pro v0.8.4
-- Detailed dispatch reporting.
--
-- Replaces the compact dispatch_log view with a much richer incident summary
-- and adds detailed event activity + unit status views for audit/reporting.
--
-- All views use security_invoker so existing RLS remains the tenant/security
-- boundary.

drop view if exists public.dispatch_log;

create view public.dispatch_log
with (security_invoker=true)
as
with department_summary as (
  select
    idept.incident_id,
    string_agg(distinct d.short_name,', ' order by d.short_name) as departments
  from public.incident_departments idept
  join public.event_departments d on d.id=idept.department_id
  group by idept.incident_id
),
unit_summary as (
  select
    iu.incident_id,
    string_agg(distinct u.name,', ' order by u.name) as units,
    min(iu.assigned_at) as first_unit_assigned,
    max(iu.cleared_at) as last_unit_assignment_cleared
  from public.incident_units iu
  join public.units u on u.id=iu.unit_id
  group by iu.incident_id
),
status_summary as (
  select
    sl.incident_id,
    min(sl.server_time) filter(where sl.new_status='ASSIGNED') as first_assigned_status,
    min(sl.server_time) filter(where sl.new_status='RESPONDING') as first_responding,
    min(sl.server_time) filter(where sl.new_status='EN_ROUTE') as first_enroute,
    min(sl.server_time) filter(where sl.new_status='ON_SCENE') as first_onscene,
    min(sl.server_time) filter(where sl.new_status='WORKING') as first_working,
    min(sl.server_time) filter(where sl.new_status='TRANSPORTING') as first_transporting,
    min(sl.server_time) filter(where sl.new_status='AT_HOSPITAL') as first_at_hospital,
    max(sl.server_time) filter(where sl.new_status in ('AVAILABLE','CLEAR','COMPLETE')) as last_clear,
    count(*) as unit_status_change_count,
    string_agg(
      to_char(sl.server_time,'YYYY-MM-DD HH24:MI:SS')
      || ' ' || coalesce(u.name,'Unit')
      || ': ' || coalesce(sl.old_status,'—')
      || ' -> ' || sl.new_status
      || case
           when sl.transport_destination_text is not null
             then ' (' || sl.transport_destination_text || ')'
           when ta.name is not null
             then ' (' || ta.name || ')'
           else ''
         end,
      ' | ' order by sl.server_time,sl.id
    ) as unit_status_history
  from public.unit_status_log sl
  left join public.units u on u.id=sl.unit_id
  left join public.ems_treatment_areas ta on ta.id=sl.transport_treatment_area_id
  where sl.incident_id is not null
  group by sl.incident_id
),
ems_summary as (
  select
    e.incident_id,
    min(e.created_at) as ems_started_at,
    max(e.transport_started_at) as transport_started_at,
    max(e.transport_completed_at) as transport_completed_at,
    max(e.transport_destination) filter(where e.transport_destination is not null) as transport_destination,
    max(e.final_disposition) filter(where e.final_disposition is not null) as ems_final_disposition,
    max(e.closed_at) as ems_closed_at,
    max(e.current_status) as latest_ems_status,
    max(e.tracking_number) as ems_tracking_number
  from public.ems_encounters e
  where e.incident_id is not null
  group by e.incident_id
),
treatment_history as (
  select
    x.incident_id,
    string_agg(distinct x.area_name,', ' order by x.area_name) as treatment_areas
  from (
    select e.incident_id,ta.name as area_name
    from public.ems_encounters e
    join public.ems_treatment_areas ta on ta.id=e.current_treatment_area_id
    where e.incident_id is not null

    union

    select e.incident_id,ta.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.ems_treatment_areas ta on ta.id=h.from_treatment_area_id
    where e.incident_id is not null

    union

    select e.incident_id,ta.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.ems_treatment_areas ta on ta.id=h.to_treatment_area_id
    where e.incident_id is not null
  ) x
  group by x.incident_id
),
ambulance_history as (
  select
    x.incident_id,
    string_agg(distinct x.unit_name,', ' order by x.unit_name) as ambulances
  from (
    select e.incident_id,u.name as unit_name
    from public.ems_encounters e
    join public.units u on u.id=e.current_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null

    union

    select e.incident_id,u.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.units u on u.id=h.from_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null

    union

    select e.incident_id,u.name
    from public.ems_handoffs h
    join public.ems_encounters e on e.id=h.encounter_id
    join public.units u on u.id=h.to_unit_id
    join public.ems_unit_config c on c.unit_id=u.id
      and c.active=true
      and (c.ems_role='ambulance' or c.transport_capable=true)
    where e.incident_id is not null
  ) x
  group by x.incident_id
),
activity_summary as (
  select
    a.incident_id,
    count(*) as activity_count,
    min(a.created_at) filter(where a.action='TREATMENT_WALKIN_INCIDENT_CREATED') as walkin_created_at,
    min(a.created_at) filter(where a.action in ('EMS_TREATMENT_RECEIVED','UNIT_ARRIVED_TREATMENT_AREA')) as first_treatment_arrival,
    max(a.created_at) as last_activity_at
  from public.cad_activity a
  where a.incident_id is not null
  group by a.incident_id
)
select
  i.event_id,
  i.id as incident_id,
  i.incident_number,
  i.status as incident_status,
  i.created_at as received_time,
  i.closed_at,
  case
    when i.closed_at is not null then extract(epoch from (i.closed_at-i.created_at))::bigint
    else extract(epoch from (now()-i.created_at))::bigint
  end as total_duration_seconds,

  coalesce(ds.departments,'') as departments,
  i.call_type,
  i.priority,

  p.name as poi_name,
  p.category as poi_category,
  i.landmark,
  ml.name as map_layer,
  z.name as zone,
  i.latitude,
  i.longitude,
  i.notes,

  coalesce(us.units,'') as units,
  us.first_unit_assigned,
  ss.first_assigned_status,
  ss.first_responding,
  ss.first_enroute,
  ss.first_onscene,
  ss.first_working,
  ss.first_transporting,
  ss.first_at_hospital,
  coalesce(ss.last_clear,us.last_unit_assignment_cleared) as last_clear,

  case
    when ss.first_enroute is not null
      then extract(epoch from (ss.first_enroute-i.created_at))::bigint
  end as dispatch_to_enroute_seconds,
  case
    when ss.first_onscene is not null
      then extract(epoch from (ss.first_onscene-i.created_at))::bigint
  end as received_to_onscene_seconds,
  case
    when ss.first_transporting is not null and ss.first_onscene is not null
      then extract(epoch from (ss.first_transporting-ss.first_onscene))::bigint
  end as onscene_to_transport_seconds,

  coalesce(ss.unit_status_change_count,0) as unit_status_change_count,
  ss.unit_status_history,

  es.ems_tracking_number,
  es.ems_started_at,
  es.latest_ems_status,
  th.treatment_areas,
  ah.ambulances,
  es.transport_destination,
  es.transport_started_at,
  es.transport_completed_at,
  es.ems_final_disposition,
  es.ems_closed_at,
  (asum.walkin_created_at is not null) as walk_in,
  asum.walkin_created_at,
  asum.first_treatment_arrival,

  i.disposition,
  coalesce(asum.activity_count,0) as activity_count,
  asum.last_activity_at,
  i.created_by
from public.incidents i
left join department_summary ds on ds.incident_id=i.id
left join unit_summary us on us.incident_id=i.id
left join status_summary ss on ss.incident_id=i.id
left join ems_summary es on es.incident_id=i.id
left join treatment_history th on th.incident_id=i.id
left join ambulance_history ah on ah.incident_id=i.id
left join activity_summary asum on asum.incident_id=i.id
left join public.event_pois p on p.id=i.poi_id
left join public.event_map_layers ml on ml.id=i.map_layer_id
left join public.event_zones z on z.id=i.zone_id;

create or replace view public.dispatch_activity_log
with (security_invoker=true)
as
select
  a.event_id,
  a.incident_id,
  i.incident_number,
  i.created_at as received_time,
  a.id as activity_id,
  a.created_at as activity_time,
  extract(epoch from (a.created_at-i.created_at))::bigint as elapsed_seconds,
  a.action,
  a.actor_kind,
  a.actor_user_id,
  a.unit_id,
  u.name as unit_name,
  d.short_name as unit_department,
  a.detail,
  a.detail->>'destination' as destination,
  a.detail->>'treatment_area_name' as treatment_area_name,
  a.detail->>'disposition' as activity_disposition,
  a.detail->>'reason' as reason,
  a.detail->>'from' as status_from,
  a.detail->>'to' as status_to
from public.cad_activity a
join public.incidents i on i.id=a.incident_id
left join public.units u on u.id=a.unit_id
left join public.event_departments d on d.id=u.department_id;

create or replace view public.dispatch_unit_status_log
with (security_invoker=true)
as
select
  sl.event_id,
  sl.incident_id,
  i.incident_number,
  sl.id as status_log_id,
  sl.server_time,
  sl.client_time,
  extract(epoch from (sl.server_time-i.created_at))::bigint as elapsed_seconds,
  sl.unit_id,
  u.name as unit_name,
  d.short_name as unit_department,
  sl.old_status,
  sl.new_status,
  sl.transport_destination_text,
  sl.transport_treatment_area_id,
  ta.name as transport_treatment_area,
  sl.actor_kind,
  sl.actor_user_id
from public.unit_status_log sl
join public.incidents i on i.id=sl.incident_id
join public.units u on u.id=sl.unit_id
left join public.event_departments d on d.id=u.department_id
left join public.ems_treatment_areas ta on ta.id=sl.transport_treatment_area_id
where sl.incident_id is not null;

grant select on public.dispatch_log to authenticated;
grant select on public.dispatch_activity_log to authenticated;
grant select on public.dispatch_unit_status_log to authenticated;
