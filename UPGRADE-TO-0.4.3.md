# CommCenter Pro v0.4.3 — Dispatch Stability, Persistent Console, Incident-Based EMS

This update addresses three operational workflow issues.

## 1. Field status changes no longer refresh Dispatch

Previously, every update to a unit row triggered `dispatchPage()`, which rebuilt:
- the incident list,
- the unit board,
- the map,
- and the incident-entry/detail panel.

That meant a crew pressing `EN ROUTE` could erase a dispatcher’s partially entered call.

v0.4.3 changes unit Realtime events to an in-place update.

A crew status change now updates only:
- that unit's status badge on the unit board;
- the same unit's status shown in an open incident;
- the status selector if that unit detail is open.

It does NOT rebuild the map or replace the dispatcher detail panel.

Structural events still refresh when appropriate:
- a new/closed incident;
- an assignment or unassignment.

## 2. Browser refresh returns to the current console

CommCenter Pro now persists NON-SENSITIVE navigation state in browser local storage:
- mode (staff / field / treatment);
- selected organization;
- selected event;
- selected stadium/map layer.

Supabase still owns authentication.

If a dispatcher refreshes the browser while in an event, CommCenter Pro restores:
`Dispatcher -> Organization -> Event -> Dispatch Console`

instead of returning to the initial landing/login navigation.

If the stored organization/event is no longer authorized, the app safely falls back to the relevant picker.

Logging out clears the stored navigation state.

## 3. EMS uses the CAD incident number as the patient reference

Separate visible `PT-0001` tracking IDs are removed from the operational UI.

The CAD incident number is now the patient reference through:
`Field Team -> Treatment Area -> Ambulance -> Destination`

Example:
`XR26-041`

There is no separate patient-number workflow for crews.

CommCenter Pro still keeps a small INTERNAL EMS custody record because handoffs need a database object, but operators see and use the incident number.

For a field crew:
- open the existing incident;
- choose Treatment Area or Ambulance;
- Request Handoff.

CommCenter Pro starts the internal custody flow automatically.

## Treatment-area walk-ins

A walk-in at a treatment area now creates a normal CAD incident.

Example:
`XR26-057`

That incident number becomes the reference on:
- Treatment Area Station;
- EMS Ops;
- ambulance handoff;
- reporting.

For this to work, the treatment area must be configured with:
- an EMS department;
- a POI.

The POI supplies the walk-in incident's map/GPS/W3W location.

---

# Upgrade from v0.4.2

## Supabase

Run:

`supabase/07_INCIDENT_BASED_EMS_FLOW.sql`

in:
Supabase -> SQL Editor -> New query -> Run

Do NOT reset the database.
Do NOT rerun the full schema.

## GitHub

Replace:
- `src/main.js`
- `src/ems.js`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/07_INCIDENT_BASED_EMS_FLOW.sql`

The existing v0.4.2 CSS can remain. The full package contains the complete current CSS.

Suggested commit:
`Stabilize dispatch console and simplify EMS patient flow`

Wait for Netlify to publish, then test in a private/incognito window once.

---

# Test A — Dispatcher form protection

1. Dispatcher opens `+ New Incident`.
2. Type a call nature and some notes but DO NOT submit.
3. On a field phone, press `EN ROUTE`.
4. Dispatcher unit status should update.
5. The unfinished incident form and everything typed into it must remain untouched.

Repeat with `ON SCENE`.

# Test B — Refresh persistence

1. Be logged into an event's Dispatch Console.
2. Press browser Refresh.
3. The app should return directly to that event's Dispatch Console.
4. Authentication should still come from the existing Supabase session.

# Test C — EMS incident-number flow

1. Assign an EMS field unit to an incident, e.g. `XR26-041`.
2. On the field unit, request a handoff to Main Medical.
3. Main Medical should see `XR26-041`, not a PT number.
4. Accept it.
5. Request an ambulance.
6. The ambulance should also see `XR26-041`.

# Test D — Walk-in

1. Treatment Area Station -> Main Medical.
2. Create Walk-In Incident.
3. A normal CAD incident number should be generated.
4. That number should appear in Dispatch and in the treatment-area patient list.
