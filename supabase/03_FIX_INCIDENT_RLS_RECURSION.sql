-- CommCenter Pro v0.2.3
-- Fix: "infinite recursion detected in policy for relation incidents"
--
-- Cause:
--   incidents SELECT policy queried incident_units
--   incident_units SELECT policy queried incidents
--   -> circular RLS evaluation
--
-- This helper runs as the function owner and checks the join tables without
-- recursively applying their caller-side RLS policies.

create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.field_can_read_incident(p_incident_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.incident_units iu
    join public.field_sessions fs
      on fs.unit_id = iu.unit_id
    where iu.incident_id = p_incident_id
      and iu.cleared_at is null
      and fs.auth_user_id = (select auth.uid())
      and fs.active = true
  );
$$;

revoke all on function private.field_can_read_incident(uuid) from public;
grant execute on function private.field_can_read_incident(uuid) to authenticated;

drop policy if exists "incidents read" on public.incidents;

create policy "incidents read"
on public.incidents
for select
to authenticated
using (
  public.has_event_staff_access(event_id)
  or private.field_can_read_incident(id)
);
