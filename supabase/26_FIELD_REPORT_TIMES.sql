-- CommCenter Pro v0.9.3
-- Field Report Time Reference.
--
-- Field users with an active event session may retrieve CAD times for units in
-- that event without claiming the unit. This supports a report-only QR workflow
-- at EMS treatment areas without interfering with an operational field-device
-- session already controlling the unit.
--
-- The RPC is intentionally read-only and returns operational timestamps only.
-- It does not expose EMS narrative, vitals, medications, procedures, signatures,
-- or other clinical documentation.

create or replace function public.field_report_call_times(
  p_unit_id uuid,
  p_limit integer default 20
)
returns table(
  event_id uuid,
  unit_id uuid,
  unit_name text,
  incident_id uuid,
  incident_number text,
  operational_period_id uuid,
  operational_period_name text,
  call_type text,
  priority text,
  landmark text,
  incident_status text,
  disposition text,
  received_at timestamptz,
  assigned_at timestamptz,
  first_responding_at timestamptz,
  first_enroute_at timestamptz,
  first_onscene_at timestamptz,
  first_working_at timestamptz,
  first_transporting_at timestamptz,
  first_at_hospital_at timestamptz,
  treatment_handoff_at timestamptz,
  treatment_area_name text,
  transport_destination text,
  cleared_at timestamptz,
  incident_closed_at timestamptz,
  status_timeline jsonb
)
language plpgsql
security definer
set search_path=public
as $$
declare
  unit_event_id uuid;
  unit_name_value text;
  limit_value integer;
begin
  select u.event_id,u.name
  into unit_event_id,unit_name_value
  from public.units u
  where u.id=p_unit_id;

  if unit_event_id is null then
    raise exception 'Unit not found';
  end if;

  if not (
    public.field_has_event_access(unit_event_id)
    or public.has_event_staff_access(unit_event_id)
  ) then
    raise exception 'Active field event access is required';
  end if;

  limit_value:=greatest(1,least(coalesce(p_limit,20),100));

  return query
  with assigned_calls as (
    select
      iu.incident_id,
      min(iu.assigned_at) as assigned_at,
      max(iu.cleared_at) as cleared_at
    from public.incident_units iu
    where iu.unit_id=p_unit_id
    group by iu.incident_id
  ),
  status_summary as (
    select
      sl.incident_id,
      min(sl.server_time) filter(where sl.new_status='RESPONDING') as first_responding_at,
      min(sl.server_time) filter(where sl.new_status='EN_ROUTE') as first_enroute_at,
      min(sl.server_time) filter(where sl.new_status='ON_SCENE') as first_onscene_at,
      min(sl.server_time) filter(where sl.new_status='WORKING') as first_working_at,
      min(sl.server_time) filter(where sl.new_status='TRANSPORTING') as first_transporting_at,
      min(sl.server_time) filter(where sl.new_status='AT_HOSPITAL') as first_at_hospital_at,
      (
        array_agg(
          nullif(trim(sl.transport_destination_text),'')
          order by sl.server_time desc,sl.id desc
        ) filter(
          where nullif(trim(sl.transport_destination_text),'') is not null
        )
      )[1] as transport_destination,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'time',sl.server_time,
            'client_time',sl.client_time,
            'from',sl.old_status,
            'to',sl.new_status,
            'destination',sl.transport_destination_text,
            'treatment_area_id',sl.transport_treatment_area_id
          )
          order by sl.server_time,sl.id
        ),
        '[]'::jsonb
      ) as status_timeline
    from public.unit_status_log sl
    where sl.unit_id=p_unit_id
      and sl.incident_id is not null
    group by sl.incident_id
  ),
  treatment_transfer as (
    select
      x.incident_id,
      min(x.handoff_time) as treatment_handoff_at,
      (array_agg(x.treatment_area_name order by x.handoff_time))[1] as treatment_area_name
    from (
      select
        e.incident_id,
        h.completed_at as handoff_time,
        ta.name as treatment_area_name
      from public.ems_handoffs h
      join public.ems_encounters e on e.id=h.encounter_id
      join public.ems_treatment_areas ta on ta.id=h.to_treatment_area_id
      where h.from_unit_id=p_unit_id
        and h.to_treatment_area_id is not null
        and h.status='COMPLETED'
        and h.completed_at is not null

      union all

      select
        a.incident_id,
        a.created_at,
        nullif(a.detail->>'treatment_area_name','')
      from public.cad_activity a
      where a.unit_id=p_unit_id
        and a.action='UNIT_ARRIVED_TREATMENT_AREA'
        and a.incident_id is not null
    ) x
    group by x.incident_id
  )
  select
    i.event_id,
    p_unit_id,
    unit_name_value,
    i.id,
    i.incident_number,
    i.operational_period_id,
    op.name,
    i.call_type,
    i.priority,
    i.landmark,
    i.status,
    i.disposition,
    i.created_at,
    ac.assigned_at,
    ss.first_responding_at,
    ss.first_enroute_at,
    ss.first_onscene_at,
    ss.first_working_at,
    ss.first_transporting_at,
    ss.first_at_hospital_at,
    tt.treatment_handoff_at,
    tt.treatment_area_name,
    ss.transport_destination,
    ac.cleared_at,
    i.closed_at,
    coalesce(ss.status_timeline,'[]'::jsonb)
  from assigned_calls ac
  join public.incidents i on i.id=ac.incident_id
  left join public.operational_periods op on op.id=i.operational_period_id
  left join status_summary ss on ss.incident_id=i.id
  left join treatment_transfer tt on tt.incident_id=i.id
  where i.event_id=unit_event_id
  order by ac.assigned_at desc
  limit limit_value;
end;
$$;

revoke all on function public.field_report_call_times(uuid,integer) from public;
grant execute on function public.field_report_call_times(uuid,integer) to authenticated;
