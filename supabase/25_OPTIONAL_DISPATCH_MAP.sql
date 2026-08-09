-- CommCenter Pro v0.9.1
-- Optional dispatch mapping / mapless incidents.
--
-- Events may operate as a board-only CAD without requiring a map point.
-- Existing mapped incidents are unchanged.

alter table public.incidents
  alter column latitude drop not null,
  alter column longitude drop not null;

-- No incident-creation RPC signature change is required. Existing v0.9.0
-- creation functions accept nullable double precision parameters and now may
-- store NULL coordinates when the dispatcher uses a text-only location.
