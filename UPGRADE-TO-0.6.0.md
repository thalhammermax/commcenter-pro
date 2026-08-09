# CommCenter Pro v0.6.0 — Dispatcher Workstations + Command Center Display

Upgrade from v0.5.5.

This release changes the dispatcher workflow in four areas:

1. New Incident is now a full popup/modal.
2. Each dispatcher workstation selects the department(s) it is dispatching.
3. A dedicated TV / Command Center display shows active calls and/or the live map.
4. Dispatchers can create event POIs directly from the dispatch map.

## 1. New Incident popup

`+ New Incident` now opens a large modal instead of using the right sidebar.

The form includes:
- call type / nature
- priority
- searchable POI
- Pick on Map
- location description
- dispatch notes
- departments
- initial unit assignment

The right side of the modal is used for departments and initial units.

### Pick on Map without losing the call

If a call location is not a POI:

1. Start the New Incident form.
2. Enter any information you already have.
3. Click `Pick on Map`.
4. The modal closes temporarily.
5. Click the location on the event map.
6. The modal reopens with the location filled in.

The unfinished nature, priority, notes, department choices, and selected initial units are preserved.

## 2. Dispatcher department scope

The Dispatch left panel now includes:

`Dispatching: All Departments`

Click it to select one or more departments.

Example:
- EMS only
- Security only
- Facilities only
- EMS + Security
- All Departments

The selection is remembered for that browser/user/event.

The dispatch scope controls:
- which active calls appear in the left call board
- which units appear in the right unit board
- which incident markers appear on the dispatch map
- which GPS unit markers appear on the dispatch map
- which departments are automatically checked on every new incident

A call involving multiple departments appears if ANY of its departments matches the workstation scope.

### Per-call override

The new-call modal still shows every event department.

The workstation scope is only the DEFAULT.

Example:
A dispatcher normally works EMS, so every new call starts with EMS checked.
If one call also needs Security, simply check Security for that call.

Initial unit choices automatically follow the departments checked on the call.

## 3. Command Center / TV display

Dispatch now has:

`Command Display`

This opens a large-screen status page designed for a command-center television.

The page includes:
- event name
- live clock
- active-call count
- department filter
- Calls / Split / Map view controls
- stadium/map-layer selector
- Full Screen button

### Calls view

Large active-call cards show:
- incident number
- live elapsed timer
- priority
- call type
- location
- map layer / zone
- department(s)
- assigned units and their current statuses

### Map view

The map view shows:
- active incidents for the selected department filter
- current field-unit GPS locations
- live/stale GPS state
- selectable stadium/map level

### Split view

Split shows:
- active calls on the left
- live event map on the right

This is intended for a large command-center monitor.

### Department filters

The TV display can independently filter:
- All
- EMS
- Security
- Facilities
- any combination of departments

Its filter does not change the dispatcher's normal CAD scope.

### Refresh / bookmark behavior

When Command Display is opened, CommCenter Pro adds:

`?view=command`

to the current URL.

Because the selected event is already persisted by CommCenter Pro, refreshing that TV/browser returns to Command Display after authentication is restored.

This also makes the display practical to bookmark on a dedicated command-center computer.

## 4. Dispatcher-created POIs

Dispatchers no longer need Event Admin / Map Builder for every temporary location.

Dispatch has:

`Add POI`

and the POI Finder has:

`+ Add POI from Map`

You can also click any calibrated map location and choose:

`Add POI Here`

Dispatch then enters:
- name
- category
- zone
- aliases
- operational notes

The POI receives:
- map layer
- map X/Y
- latitude/longitude
- W3W when available

The new POI becomes immediately searchable by Dispatch.

Dispatcher-created POIs are always marked as EVENT-only POIs.

They do NOT automatically change the reusable organization Venue Library.

That is intentional for locations such as:
- temporary EMS staging
- temporary command post
- artist medical
- credentialing
- temporary gates
- one-event production areas

An Event/Organization Admin can later promote appropriate event POIs into a new Venue Library version using the existing venue-version workflow.

## Realtime behavior

v0.6.0 preserves the stability work from earlier versions.

Routine:
- unit status changes
- unit GPS changes
- POI additions

do not rebuild the dispatcher call-entry modal.

The Command Display subscribes to:
- incidents
- incident assignments
- unit statuses
- unit locations

GPS updates move map positions without refreshing the entire television display.

## Database change

The only new server-side capability is dispatcher quick-POI creation.

Direct table INSERT remains restricted to Event Admin / Map Builder.

Dispatch uses the security-definer RPC:

`dispatcher_create_poi(...)`

which requires normal `can_dispatch_event()` access and creates only event-scoped POIs.

The migration also adds `event_pois` to Supabase Realtime so new locations can appear on other live dispatch consoles.

---

# Upgrade from v0.5.5

## Step 1 — Supabase

Run:

`supabase/12_DISPATCH_WORKSTATION_COMMAND_DISPLAY_POIS.sql`

Go to:

Supabase
→ SQL Editor
→ New query
→ paste the entire file
→ Run

Do NOT reset the database.
Do NOT rerun `01_FULL_SCHEMA.sql`.

## Step 2 — GitHub

Replace:
- `src/main.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/12_DISPATCH_WORKSTATION_COMMAND_DISPLAY_POIS.sql`

No changes are required to:
- `src/ems.js`
- `src/mapBuilder.js`
- `src/venueLibrary.js`

Suggested commit:

`Add dispatcher scopes, command display, new-call modal and quick POIs`

Wait for Netlify to publish.

Because the service-worker cache changed, use a private/incognito window for the first test or fully close/reopen the installed PWA.

---

# Test plan

## Dispatcher scope

1. Open Dispatch.
2. Click `Dispatching: All Departments`.
3. Select only EMS.
4. Verify only EMS units appear.
5. Verify EMS calls and multi-department calls involving EMS remain visible.
6. Create a new incident.
7. Confirm EMS is already checked.

Then select EMS + Security and repeat.

## New incident popup

1. Click `+ New Incident`.
2. Enter nature and notes.
3. Click `Pick on Map`.
4. Click a location.
5. Confirm the popup returns with all previously typed information intact.
6. Create the incident.

## Quick POI

1. Click `Add POI`.
2. Click a calibrated location on the map.
3. Name it `Temporary North Aid`.
4. Add alias `North Med`.
5. Save.
6. Open Find POI.
7. Search `North Med`.
8. Confirm the POI is found.

## Command Display

1. Click `Command Display`.
2. Test Calls.
3. Test Split.
4. Test Map.
5. Filter by one department.
6. Change a field unit status from another device.
7. Confirm the call card changes.
8. Walk with a GPS-sharing field unit.
9. Confirm its marker moves on the TV map.
10. Press Full Screen.
11. Refresh the browser and confirm the command display returns.
