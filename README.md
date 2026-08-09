# CommCenter Pro v0.7.0

CommCenter Pro is a cloud-hosted, multi-tenant, multi-department event operations CAD/PWA.

## Stack

- Frontend/PWA: Vite + JavaScript
- Event maps: Leaflet
- PDF rendering: PDF.js
- Cloud backend: Supabase Postgres/Auth/Realtime/Storage
- Hosting/CD: Netlify + GitHub
- Production domain: CommCenter.pro

## Major v0.2 capabilities

- Platform organizations/tenants
- Events, departments and units
- 4-digit field-access PIN
- Anonymous field-device Auth sessions
- Multi-department incidents
- Realtime unit dispatch/status
- PDF Map Builder
- GPS control-point georeferencing
- georeference error metrics
- POIs/common names + aliases
- dispatch log + CSV export

## Start here

Read:

`SETUP.md`


## Operational note

This is development software. Do not use it as the sole dispatch path until you validate security, roles, connectivity behavior, backups, incident concurrency, audit logs, reporting and fallback procedures.


## v0.3.1

Adds full dispatcher unit assignment controls plus the v0.3.0 EMS treatment-area/handoff workflow. See `UPGRADE-TO-0.3.1.md`.


## v0.4.0

Dark command-center UI and multi-level venue/stadium mapping. See `UPGRADE-TO-0.4.0.md`.


## v0.5.0 — Venue Library

Adds reusable, versioned organization-level venues. Save a completed event map into the organization Venue Library, then create future events from an immutable snapshot of that venue. See `UPGRADE-TO-0.5.0.md`.


## v0.5.1 — Live Field Unit Location

Adds event-controlled, field-device opt-in GPS sharing to the Dispatch map. Only current unit location is stored; no route history. See `UPGRADE-TO-0.5.1.md`.


## v0.5.2 — Treatment Custody Confirmation

Dispatch and Treatment Area Station can independently reconcile a patient/incident as received by a treatment area. See `UPGRADE-TO-0.5.2.md`.


## v0.5.3 — Incident Command Modal

Active incidents now open in a full command popup with complete call information, EMS custody, assigned units, GPS state, and CAD activity. Call editing is performed in the modal rather than the right sidebar. See `UPGRADE-TO-0.5.3.md`.


## v0.5.4 — Field Status Button State

Field Unit CAD status buttons now use semantic colors and a strong `CURRENT` state without page refreshes. See `UPGRADE-TO-0.5.4.md`.


## v0.5.5 — EMS Realtime Hotfix

Fixes Treatment Area Station and EMS Ops Realtime channel lifecycle so re-renders do not attempt to add `postgres_changes` callbacks after `subscribe()`. See `UPGRADE-TO-0.5.5.md`.


## v0.6.0 — Dispatcher Workstations + Command Display

Adds a popup new-call workflow, persistent multi-department dispatcher scope, a filterable TV/Command Center active-call + GPS map display, and dispatcher-created event POIs. See `UPGRADE-TO-0.6.0.md`.


## v0.6.1 — Treatment Area Audit-Log Hotfix

Database-only fix allowing `actor_kind='treatment'` in `cad_activity`, resolving Treatment Area Station receive-patient failures. See `UPGRADE-TO-0.6.1.md`.


## v0.7.0 — Direct EMS Handoffs + GPS-First Mapping

Removes handoff request/accept workflows in favor of immediate custody transfers, allows Dispatch to hand patients directly to treatment areas or ambulances, removes W3W from active application workflows, and replaces specific example text in form help/placeholders with generic labels. Legacy W3W database columns/tables are retained only for non-destructive backward compatibility. See `UPGRADE-TO-0.7.0.md`.
