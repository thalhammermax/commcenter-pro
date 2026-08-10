-- CommCenter Pro v0.13.8
-- Dispatch live unit status hardening
--
-- Realtime remains the primary update path. This migration defensively verifies
-- that the tables used by Dispatch status synchronization are published to
-- Supabase Realtime and that units sends complete UPDATE row images.

alter table public.units replica identity full;

do $$
begin
  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='units'
  ) then
    alter publication supabase_realtime add table public.units;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='unit_status_log'
  ) then
    alter publication supabase_realtime add table public.unit_status_log;
  end if;

  if not exists(
    select 1
    from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='incident_units'
  ) then
    alter publication supabase_realtime add table public.incident_units;
  end if;
end $$;

grant select on public.units, public.unit_status_log, public.incident_units to authenticated;
