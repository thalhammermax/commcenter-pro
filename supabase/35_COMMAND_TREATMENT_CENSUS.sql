-- CommCenter Pro v0.13.4
-- Read-only Treatment Center census summary for Command Board.
--
-- The standalone Command Board intentionally does not receive EMS encounter or
-- patient-level rows. This aggregate RPC exposes only operational Treatment
-- Center status: census, capacity, inbound count, and accepting state.

create or replace function public.command_treatment_center_summary(
  p_event_id uuid
)
returns table(
  treatment_area_id uuid,
  name text,
  status text,
  capacity integer,
  accepting_patients boolean,
  census_count integer,
  inbound_count integer
)
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if not (
    public.has_event_staff_access(p_event_id)
    or private.command_has_event_access(p_event_id)
  ) then
    raise exception 'Command Board access required';
  end if;

  return query
  select
    ta.id,
    ta.name,
    ta.status,
    ta.capacity,
    ta.accepting_patients,
    coalesce(c.census_count,0)::integer,
    coalesce(ib.inbound_count,0)::integer
  from public.ems_treatment_areas ta
  left join lateral(
    select count(*)::integer as census_count
    from public.ems_encounters e
    where e.event_id=p_event_id
      and e.current_treatment_area_id=ta.id
      and e.current_status<>'CLOSED'
  ) c on true
  left join lateral(
    select count(distinct u.id)::integer as inbound_count
    from public.units u
    where u.event_id=p_event_id
      and u.active=true
      and u.status='TRANSPORTING'
      and u.current_transport_treatment_area_id=ta.id
      and exists(
        select 1
        from public.incident_units iu
        join public.incidents i on i.id=iu.incident_id
        where iu.unit_id=u.id
          and iu.cleared_at is null
          and i.event_id=p_event_id
          and i.status='OPEN'
      )
      and not exists(
        select 1
        from public.incident_units iu2
        join public.ems_encounters e2
          on e2.incident_id=iu2.incident_id
         and e2.event_id=p_event_id
         and e2.current_treatment_area_id=ta.id
         and e2.current_status='IN_TREATMENT'
        where iu2.unit_id=u.id
          and iu2.cleared_at is null
      )
  ) ib on true
  where ta.event_id=p_event_id
    and ta.active=true
  order by ta.name;
end;
$$;

revoke all on function public.command_treatment_center_summary(uuid) from public;
grant execute on function public.command_treatment_center_summary(uuid) to authenticated;
