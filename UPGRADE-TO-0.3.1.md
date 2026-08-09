# CommCenter Pro v0.3.1 — Upgrade Guide

This release combines the v0.3.0 EMS treatment-area/handoff system with the missing dispatcher assignment controls.

## What v0.3.1 adds

Dispatcher:
- Assign one or more units when creating an incident.
- Create an incident without assigning a unit.
- Assign additional units from the incident detail panel.
- Click a unit on the unit board and assign it to an active incident.
- Multiple units can be assigned to the same incident.
- Units from different departments can be assigned to the same incident.
- Dispatcher can change an assigned unit's status.
- Dispatcher can unassign a unit and return it to AVAILABLE.
- Unit board shows the current incident number/nature.
- A unit cannot be assigned to two open incidents at the same time.
- Assignments are logged in `incident_units`, `unit_status_log`, and `cad_activity`.
- Field CAD receives assignments through the existing Supabase Realtime subscription.

EMS from v0.3.0:
- Dedicated Treatment Area Station.
- Treatment-area capacity and OPEN/LIMITED/FULL/CLOSED state.
- Field team -> treatment area handoff.
- Field team -> ambulance handoff.
- Treatment area -> ambulance handoff.
- Handoff accept/decline.
- Operational patient tracking IDs.
- Ambulance transport workflow.
- EMS Ops command dashboard.

---

# IMPORTANT: upgrade order

Do these steps in order.

## 1. Do NOT reset Supabase

Do not run:
`00_DEV_RESET_IF_NEEDED.sql`

Do not rerun:
`01_FULL_SCHEMA.sql`

Your current event/incidents/map data should remain intact.

## 2. If you have NOT installed v0.3.0 EMS yet

First run:

`supabase/04_EMS_OPERATIONS.sql`

Supabase:
- SQL Editor
- New query
- Paste the entire file
- Run

Wait for success.

## 3. Install the v0.3.1 dispatcher database functions

Then run:

`supabase/05_DISPATCH_ASSIGNMENTS.sql`

Supabase:
- SQL Editor
- New query
- Paste the entire file
- Run

This replaces/upgrades `assign_unit()` and adds:
- `unassign_unit()`
- `staff_set_unit_status()`

No incident records are deleted.

## 4. Update GitHub frontend files

Replace these files with the v0.3.1 copies:

`src/main.js`
`src/style.css`
`public/service-worker.js`

If you have not installed v0.3.0 yet, also add/replace:

`src/ems.js`

For easiest installation, replacing the entire repository with the full v0.3.1 package is acceptable as long as you preserve your Netlify environment variables (those live in Netlify, not the repository).

## 5. Commit to main

Suggested commit message:

`Add EMS treatment areas and dispatcher unit assignment`

Netlify should automatically build the new commit.

## 6. Wait for Netlify

Netlify -> Deploys

Wait until the newest deploy says:
`Published`

The service worker cache is bumped in this release.

For the first test, use an Incognito/Private browser window anyway.

---

# Dispatcher test

## 7. Create an incident with units

Open:
Dispatcher / Admin Login -> Event -> Unified Dispatch

Click:
`+ New Incident`

Choose the location and departments.

The form now contains:

`Initial unit assignment`

Check:
- Bike Team 1
- Medic 1
- Security 101

Then click:

`Create & Dispatch Selected`

The incident is created first. CommCenter Pro then assigns each selected unit.

The incident card should list the assigned units.

## 8. Add another unit after creation

Click the incident.

Under:
`Assign another unit`

select another unassigned unit.

Click:
`Assign Unit`

It should immediately become ASSIGNED.

## 9. Dispatcher status control

Inside the incident detail, each assigned unit gets:
- status dropdown
- Set Status
- Unassign

Example:
Medic 1 -> EN ROUTE

Click:
`Set Status`

The unit board should update and `unit_status_log` gets a timestamp.

## 10. Unassign a unit

Click:
`Unassign`

Confirm.

CommCenter Pro:
- sets `incident_units.cleared_at`
- changes the unit to AVAILABLE
- writes a unit status log
- writes `UNIT_UNASSIGNED` into CAD activity

## 11. Assign from the unit board

Click an unassigned unit in the right-side unit board.

The detail panel shows:
`Assign to incident`

Choose:
`XR26-004 · Medical`

Click:
`Assign to Incident`

The assignment works in either direction:
Incident -> Unit
or
Unit -> Incident

## 12. Multi-department incident

One incident can have, for example:

EMS:
- Bike Team 2
- Medic 1

Security:
- Security 104

Police:
- PD 2

All remain under one incident number.

## 13. Field-device test

On a different/private browser:
- Field Unit Access
- Enter Event ID and 4-digit PIN
- Claim Bike Team 2

From Dispatch:
- assign Bike Team 2 to an incident

The existing field Realtime subscription watches `incident_units` for that unit.
The assignment should appear automatically.

---

# EMS treatment-area test

After v0.3.0/v0.3.1 EMS SQL is installed:

Event Admin -> EMS Setup

Create:
Main Medical
Capacity: 12
Department: EMS
POI: Main Medical

Configure:
Bike Team 1 -> Field Team
Medic 1 -> Ambulance / ALS / Transport Capable

On another device:
CommCenter Pro -> Treatment Area Station
Event ID + PIN
Select Main Medical

Test:
Bike Team 1 -> Main Medical -> Medic 1 -> Transport

---

# Database behavior

v0.3.1 intentionally prevents a single unit from being assigned to two different OPEN incidents simultaneously.

If Dispatch tries it, the RPC returns:

`Unit is already assigned to XR26-###`

Multiple different units may be assigned to one incident.

---

# Validation notes

The JavaScript files in this package were syntax-checked with Node.

A complete local Vite build could not be run in the package-building environment because its internal npm mirror did not provide `@supabase/supabase-js`. Netlify remains the authoritative full dependency/build test.

If Netlify fails:
send the first red build error and approximately 20 lines around it.
