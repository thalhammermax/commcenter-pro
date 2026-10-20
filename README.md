# CommCenter Pro v0.18.0

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


## v0.7.1 — EMS Handoff / CAD Assignment Sync

Direct EMS handoffs now automatically clear the sending field unit from the CAD incident and commit the receiving ambulance when applicable. The change is transactional and audited. See `UPGRADE-TO-0.7.1.md`.


## v0.7.2 — Dispatcher Unit Control Modal

Moves unit status, assignment, GPS and venue-post controls out of the crowded Dispatch sidebar into the shared large modal. The POI finder also uses a modal so the right sidebar is now a dedicated unit board. See `UPGRADE-TO-0.7.2.md`.


## v0.7.3 — Close-Call Release + Transport Destinations

Closing an incident now automatically clears every committed unit and returns them to AVAILABLE. TRANSPORTING requires a destination: ambulances use a destination-facility text field, while all other units choose an event treatment area. See `UPGRADE-TO-0.7.3.md`.


## v0.7.4 — POI Marker Rendering Fix

Replaces Leaflet default image markers with self-contained HTML/CSS pins for POIs and field incident locations, eliminating broken `Marker` placeholders when Leaflet icon assets are not resolved by the production build. See `UPGRADE-TO-0.7.4.md`.


## v0.7.5 — Treatment Area Arrival from Unit

A non-ambulance unit transporting a patient to a treatment area can now mark `Arrived at Treatment Area` from either the dispatcher Unit Control popup or the Field Unit page. This uses the same incident-level EMS custody flow, transfers the patient to the treatment area, clears the unit from the incident, and returns it to AVAILABLE. See `UPGRADE-TO-0.7.5.md`.


## v0.7.6 — Ambulance Transport Outcome

A transport ambulance returning to AVAILABLE must now confirm whether the patient was delivered to the destination facility or the transport ended in a refusal. Either outcome closes the EMS patient flow, clears the ambulance from the incident, and returns it to AVAILABLE while leaving the CAD incident open. See `UPGRADE-TO-0.7.6.md`.


## v0.8.0 — Configurable Dispatch Workspace + Login Submit Fix

Dispatchers can now choose and resize their own CAD workspace layout, including a map-focused Units Left / Calls Bottom arrangement. Layout settings persist per user/event/browser. Dispatcher/Admin email-password login now uses a real form so pressing Enter submits correctly. See `UPGRADE-TO-0.8.0.md`.


## v0.8.1 — Transport Outcome Closes the Call

When a transporting ambulance returns to AVAILABLE and confirms Patient Delivered or Patient Refusal, CommCenter Pro now closes the EMS patient flow and the CAD incident in the same transaction, releases every committed unit, and returns all of them to AVAILABLE. See `UPGRADE-TO-0.8.1.md`.


## v0.8.2 — Compact Dispatch Bar + Incident-Based POIs

The Dispatch top bar is reduced to Find POI, Command Display, and a More menu. Dispatcher-created event POIs are now created from raw map locations inside New Incident, using the incident Location Description as the POI name. POI + incident creation is atomic. See `UPGRADE-TO-0.8.2.md`.


## v0.8.3 — Dispatcher Walk-In Patients

Dispatch can now create a walk-in patient directly into a selected treatment area. The action creates a normal CAD incident at the treatment area's configured POI and immediately establishes EMS custody as IN_TREATMENT at that area. Treatment Area Station uses the same underlying walk-in function. See `UPGRADE-TO-0.8.3.md`.


## v0.8.4 — Detailed Dispatch Log

Reports now provide a substantially richer incident summary plus complete CAD Activity and Unit Status views. Each call can be opened as a detailed record containing location, notes, response timestamps, unit history, EMS patient flow, transport information, disposition, and the full audit timeline. Three CSV exports support call-level reporting, CAD audit review, and unit-status analysis. See `UPGRADE-TO-0.8.4.md`.


## v0.8.5 — EMS-Scoped Walk-Ins + Patient Flow Naming

The `+ Walk-In Patient` action is now visible only when the current Dispatch Scope includes an EMS-enabled department, determined from configured EMS units/treatment areas rather than department naming. The incident action and workflow formerly called `EMS Handoff / Custody` are now labeled `EMS Patient Flow`. See `UPGRADE-TO-0.8.5.md`.


## v0.8.6 — Reports Dark-Theme Fix

Fixes the Detailed Dispatch Log's hard-coded light report surfaces so the summary tables, CSV menu, metrics, search controls, and full call-record modal consistently use CommCenter Pro's dark command UI palette. See `UPGRADE-TO-0.8.6.md`.


## v0.8.7 — Explicit EMS Departments + Safe Resource Removal

Departments now have an explicit `EMS Enabled Department` flag; the dispatcher Walk-In Patient action is shown only when the active Dispatch Scope includes a department with that flag. Administrative removal is now a typed, server-validated archive workflow for units, departments, events, and EMS treatment areas, with safeguards and restore screens that preserve operational history. See `UPGRADE-TO-0.8.7.md`.


## v0.9.0 — ICS Operational Periods / Multi-Day Events

A single CommCenter event can now contain multiple ICS Operational Periods. Each period has its own explicit incident prefix and sequence counter, with one ACTIVE period controlling new-call numbering. Existing calls may remain open across period transitions. Dispatch, treatment-area walk-ins, Command Center, Realtime, and detailed Reports all understand Operational Period membership. See `UPGRADE-TO-0.9.0.md`.


## v0.9.1 — Walk-In Visibility Fix + Optional Dispatch Map

The Walk-In Patient action is now fail-closed and is not rendered unless the current Dispatch Scope contains an explicitly EMS-enabled department with an active treatment area. Dispatch Layout now includes a per-workstation Show Map toggle, with true two-panel board layouts when Map is off. Incidents can also be created with a text-only Location Description for mapless events. See `UPGRADE-TO-0.9.1.md`.


## v0.9.2 — Clickable Map POIs

Dispatch POI markers are now clickable and open a dark-theme operational popup with POI details and a `+ Start New Incident` action. The normal incident form opens with the POI fully preselected, and realtime-added POIs receive the same behavior. See `UPGRADE-TO-0.9.2.md`.


## v0.9.3 — Field Report Times + Treatment QR

Field Unit CAD now has a read-only Call Times reference showing current/recent incident timestamps and complete unit status history. Treatment Area Station displays a locally generated QR code that opens a PIN-protected field report lookup without claiming or changing the selected unit. See `UPGRADE-TO-0.9.3.md`.


## v0.9.4 — 24-Hour Time + Structured Dispositions

All visible operational timestamps now use 24-hour time. Incident closure uses standardized General Call Disposition and, for EMS incidents, a separate EMS Patient Disposition dropdown. Field EMS and Treatment Area patient closure use the same EMS disposition catalog, and ambulance Delivered / Refusal now stores general and EMS outcomes separately. See `UPGRADE-TO-0.9.4.md`.


## v0.9.5 — Dispatch Close Clears Treatment-Center Patient

Closing a CAD incident from Dispatch now atomically closes any EMS patient flow still in a Treatment Area, clears current treatment custody, cancels pending handoffs, updates the Treatment Area census through Realtime, and logs `EMS_TREATMENT_CLEARED_BY_DISPATCH`. Legacy close clients are blocked from orphaning EMS patients. See `UPGRADE-TO-0.9.5.md`.


## v0.9.6 — Unified Incident Close Routing

`Close Incident` is now the single dispatcher close entry point. Active event-ambulance transports automatically open the Delivered / Refusal transport outcome; all other calls use the structured General / EMS disposition workflow, including treatment-center cleanup. Both routes share the existing backend completion logic. See `UPGRADE-TO-0.9.6.md`.


## v0.10.0 — Guest Logistics / Special Guest Movement

Adds a first-class Guest Logistics module for prescheduled convention transportation. Guest movements support CSV spreadsheet import, driver preassignment, Field driver progression, Realtime movement status, 24-hour timestamps, flight/contact details, movement audit history, and CSV export. Future driver assignments coexist with normal CAD work; a unit becomes operationally committed only when the guest movement begins. Ad-hoc errands remain normal CAD incidents through `+ New Logistics CAD Task`. See `UPGRADE-TO-0.10.0.md`.


## v0.11.0 — Unit Staffing / Operational Period Assignment Board

Adds an event personnel roster plus a command-center-style Unit Staffing board. Personnel assignments, roles, planned hours, check-in and check-out are explicitly tied to an Operational Period. The board supports per-unit crew assignments, reserve/staging personnel, Quick Add Names, Realtime check-in, crew-level check-in/out, CSV export, and Copy From Another OP for multi-day events. See `UPGRADE-TO-0.11.0.md`.


## v0.12.0 — Operational Period Field Sessions + Field Layout Builder

Field Unit sessions are now bound to the ACTIVE Operational Period. Completing a period or activating its replacement immediately ends all Field sessions from the outgoing period, clears current Field GPS locations, and forces crews to re-enter the Event ID/PIN and select their unit for the next period. Event Admin also gains an event-wide drag-and-drop Field Layout Builder for ordering the Unit Identity, Status, Run Times, Current Call, EMS, Guest Logistics, Location, Transport, Offline, and Session blocks. See `UPGRADE-TO-0.12.0.md`.


## v0.13.0 — Treatment Inbound Board + Treatment Layout Builder

Treatment Area Stations now show patients as **Inbound** as soon as a Field unit is TRANSPORTING to that center. Inbound patients remain separate from Current Census until Treatment, Dispatch, or the Field unit completes the handoff, at which point Realtime moves the patient into census and clears the transporting unit. Event Admin also gains an event-wide drag-and-drop **Treatment Layout** builder for Station Summary, Inbound, Census, station controls, Walk-In, manual receive, Field Report QR, and session controls. See `UPGRADE-TO-0.13.0.md`.


## v0.13.1 — Standalone Command Board PIN Access

The Command Board is now available from the main landing page using Event ID + the event's existing 4-digit specialty-access PIN. Standalone sessions are anonymous and read-only, with RLS limited to the event data required by the call/unit/map wallboard. Named Dispatchers retain the existing one-click Command Display shortcut. See `UPGRADE-TO-0.13.1.md`.


## v0.13.2 — Editable Units & Treatment Areas

Event Admin can now edit existing Unit name/department/home-staging details and EMS Treatment Area name/capacity/department/POI/status/accepting/notes without deleting the resource. Department changes are protected while resources are operational, Treatment Area capacity cannot be reduced below census, and resource edits are audited. This release also makes internal event slugs collision-safe so archived recurring events do not prevent reuse of the same visible event name. See `UPGRADE-TO-0.13.2.md`.


## v0.13.3 — EMS Admin Navigation & Archived Treatment Areas

Archived Treatment Areas are now shown and restorable directly in EMS Setup. Treatment Area Layout has moved under EMS Setup instead of occupying a top-level Event Admin tab, and the general Field Layout interface is now labeled Field Unit Layout throughout the UI. This is a frontend-only update; no SQL migration is required. See `UPGRADE-TO-0.13.3.md`.


## v0.13.4 — Command Board Treatment Center Census

Adds a live Treatment Centers strip to Command Display with current census/capacity, inbound count, Treatment Area operational status, and accepting state. Standalone Event ID/PIN Command Boards receive only aggregate census data through a dedicated security-definer RPC and continue to have no patient-level EMS access.


## v0.13.5 — Treatment Area inbound arrival authorization hotfix

- Fixes `Not authorized for this unit` when a Treatment Area Station accepts an inbound patient whose CAD incident did not yet have an EMS encounter row.
- Allows the destination Treatment Area Station to establish EMS custody only for a unit actively TRANSPORTING that exact incident to that exact Treatment Area.
- Preserves audit actor as Treatment Area.
- Already-committed inbound patients can still be received if the Treatment Area becomes FULL or stops accepting after transport began; new destination selections remain blocked.


## v0.13.6 — Treatment Area release closes CAD incident

- Releasing/closing a patient from a Treatment Area now also closes the associated open CAD incident.
- Remaining incident unit assignments are released and returned to AVAILABLE atomically.
- The EMS disposition selected by the Treatment Area is preserved; the CAD incident uses the event's active COMPLETED disposition when available.
- Field-side and Dispatch uses of `ems_release_encounter()` retain their prior EMS-only behavior.
- A legacy/corrupt incident with another active EMS encounter is left open rather than silently closing another patient's call.

## v0.13.7 — Intentional disposition selection

Disposition dropdowns no longer preselect hard-coded outcomes. Dispatch General disposition, Field EMS close disposition, and Treatment Area patient-release disposition now begin blank and require an intentional operator selection. Previously recorded EMS dispositions are still preserved when reopening a close workflow.

## v0.13.8 — Dispatch live status hardening

The main Dispatch unit board now reconciles unit status through realtime unit updates, realtime unit-status activity, and a lightweight two-second database fallback. This prevents a dropped/stalled Realtime subscription from leaving Dispatch status badges stale until a browser refresh. Unit realtime rows are also merged into nested incident-assignment unit state.

## v0.13.9 — Field Unit call-relative map

Field Unit CAD now shows the crew's own device GPS position alongside the assigned call on the event map. Live sharing updates the local marker continuously, while crews who are not sharing can request a one-time local-only GPS fix. The map provides a straight-line reference/distance, fit-to-unit-and-call control, and multi-level venue warnings.

## v0.14.1 — Google navigation rollback + Dispatch status reliability retained

The experimental Google Maps/Routes Field navigation integration has been removed. Field Unit CAD returns to the CommCenter georeferenced Event Map with live/local GPS position, call marker, straight-line reference, and distance.

The v0.14.0 Dispatch status reliability improvements remain in place: Realtime is the fast path, `dispatch_unit_status_snapshot()` provides an authoritative one-second database heartbeat, focus/visibility changes trigger immediate synchronization, and the Units panel displays LIVE / LIVE · DB / SYNC DEGRADED state.

## v0.14.2 — Dispatch map and active-call self-healing

Dispatch now tracks incident markers as first-class Leaflet objects and reconciles them whenever the active incident set changes. Closing a call removes its marker immediately without rebuilding the whole map.

A guarded `dispatch_active_incident_snapshot()` RPC also reconciles the active-call set every second, so missed/stalled Realtime events self-heal without a browser refresh. The service worker no longer intercepts or caches cross-origin Supabase/API traffic; PWA caching is limited to CommCenter's own same-origin application assets.

## v0.14.3 — Map Builder POI management

Map Builder POIs can now be edited, repositioned, and deleted from the active event map. The POI list includes Edit/Delete actions, and clicking a POI marker opens the editor. Editing supports name, category, zone, aliases, and notes. **Move on Map** lets an admin click a new location while preserving POI metadata.

Delete is implemented as a safe archive (`active=false`) so the POI disappears from active maps/search without destroying historical incident references. Venue-snapshot POI edits affect only the event copy, not the organization Venue Library source.

## v0.14.4 — Map Builder zone management

Map Builder zones can now be edited or deleted. Zone editing supports name, short name, category, notes, and sort order. Delete is implemented as a safe archive so historical closed-incident references remain intact.

Deleting a zone automatically unassigns active POIs, current unit zone/post references, and vertical-access nodes from that zone. A zone referenced by an active incident is protected from deletion until the incident is closed or moved. The active-only zone-name unique index also allows a previously archived zone name to be reused.

## v0.14.5 — Low-profile POI markers

POI markers on Dispatch and Map Builder maps are now compact, semi-transparent dots rather than full-size teardrop pins. The visible mark is intentionally subtle so dense POI layers do not obscure the underlying event map, while the Leaflet click target remains larger for usability. Hovering or keyboard-focusing a POI temporarily increases its visibility.

## v0.14.6 — PDF map cropping

Map Builder can crop a PDF before rendering it as the operational map. The crop editor uses a drag-to-select page preview, keeps the original PDF intact, and stores the selected crop relative to the source page.

Existing configured maps can use **Crop Current PDF**. CommCenter atomically remaps control points, POIs, vertical-access nodes, incident map coordinates, and the affine georeference into the new pixel coordinate system. A crop that would exclude any existing mapped record is rejected rather than silently losing map history.

Crop metadata also follows maps into and out of the reusable Venue Library.

## v0.14.7 — Field Unit assignment alert + acknowledgement

When a Field Unit receives a new CAD assignment, its portal now enters a prominent red pulsing alert state and displays an **ACKNOWLEDGE** button. The alert persists across refreshes and Field UI updates until that exact assignment is acknowledged.

Acknowledgement is stored on `incident_units`, recorded in the CAD activity log with assignment-to-acknowledgement time, and shown to Dispatch as **AWAITING ACK** or **ACK HH:MM**. Reassigning a cleared unit to the same incident creates a fresh acknowledgement requirement.

Field assignment state also has a lightweight 1.5-second database heartbeat plus focus/visibility recovery so a missed Realtime event does not leave a crew unaware of a new assignment.



## v0.15.0 — Multi-task MOVEs + inline EMS workflow

Guest Logistics units can now carry multiple assigned MOVEs while also remaining assigned to one CAD incident. Assigned MOVEs are presented as the unit's **primary task**, while the CAD incident is shown as a **secondary assignment**. Only one MOVE can be physically underway at a time; when the underway MOVE completes, an existing CAD assignment automatically becomes operationally active again.

Dispatch unit cards, Unit Controls, Field Unit CAD, and Command Board now show assigned MOVEs and their primary/secondary relationship. Command Board PIN sessions can read only the event's assigned Guest Logistics movements needed for that display.

EMS operational UI is now event-aware: when no active department is EMS-enabled, EMS-specific Dispatch/Admin/Command/Field/report presentation is suppressed. The department EMS-enable control remains available in Event Admin. For EMS incidents, patient-flow controls are embedded directly in the incident detail popup instead of requiring a separate **EMS Patient Flow** button.

See `UPGRADE-TO-0.15.0.md`.



## v0.15.2 — Field MOVE pulse hotfix

- Field Unit pending-task pulse now uses an explicit rendered overlay tied directly to the current acknowledgement state.
- New MOVE assignments reliably pulse yellow until acknowledged.
- CAD-only alerts remain red, and simultaneous unacknowledged CAD + MOVE assignments alternate red/yellow.
- No database migration is required from v0.15.1.

See `UPGRADE-TO-0.15.2.md`.

## v0.15.1 — Concurrent CAD/MOVE status + MOVE acknowledgement

New Guest Logistics MOVE assignments now produce a yellow pulsing Field Unit alert until the driver explicitly acknowledges the MOVE. Each pending MOVE has a prominent acknowledgement banner/button modeled after the CAD assignment acknowledgement workflow. If both a CAD ticket and MOVE are awaiting acknowledgement, the screen alternates the alert border between red and yellow.

CAD and Guest Logistics statuses are now stored independently. Each active `incident_units` assignment has its own `cad_status`, while Guest Logistics continues to use the movement status workflow. A unit can therefore show a primary MOVE such as **EN ROUTE TO PICKUP** while its secondary CAD ticket is independently **ON SCENE**. Dispatch, Field Unit CAD, and Command Board display the two task statuses separately.

The shared `units.status` remains as an operational summary and follows the primary task: any assigned MOVE takes precedence; after the last MOVE is unassigned, cancelled, no-showed, or completed, the unit returns to the remaining CAD assignment status (or AVAILABLE when no task remains).

See `UPGRADE-TO-0.15.1.md`.

EMS custody handoffs are now assignment-aware as well. A unit-to-unit patient handoff removes the sending field unit from the CAD incident and commits the receiving ambulance; a handoff to a Treatment Area removes the sending field unit. The shared unit status still respects Guest Logistics priority when a MOVE remains assigned.

## v0.15.3 — Guest Logistics CAD toolbar shortcut

When an event contains at least one active Guest Logistics-enabled department, the main CAD top toolbar now includes a direct **Guest Logistics** button alongside **Find POI** and **Command Display**. The shortcut opens the event-wide Guest Logistics board regardless of the current CAD department scope.

See `UPGRADE-TO-0.15.3.md`.

## v0.15.4 — Link CAD tickets to Guest Logistics MOVEs

New CAD incidents can optionally attach to an existing Guest Logistics MOVE using a search by MOVE number, guest name, or flight number. The relationship is persistent and appears in both the CAD incident detail and the Guest Logistics MOVE detail.

See `UPGRADE-TO-0.15.4.md`.


## v0.15.6 — CAD assignment status guard

- Unassigned Field Units can no longer select CAD response/progress statuses such as Assigned, Responding, En Route, On Scene, Working, Transporting, or Clear.
- With no active CAD assignment, Field Unit exposes only department-enabled `AVAILABLE` / `OUT_OF_SERVICE` availability controls.
- Dispatch unit controls apply the same restriction when a unit has no active CAD ticket.
- `staff_set_unit_status_v2` and `field_set_unit_status_v2` now enforce the rule server-side, so stale clients cannot create impossible CAD status states.

See `UPGRADE-TO-0.15.6.md`.

## v0.15.5 — CAD/MOVE status isolation + Dispatch task watchdog

Guest Logistics MOVE status is now fully isolated from CAD/general unit status. Main Dispatch merges task-specific Realtime updates immediately and runs a one-second authoritative CAD/MOVE task-state watchdog so missed websocket events self-heal without a browser refresh.

See `UPGRADE-TO-0.15.5.md`.

## v0.15.7 — Locked module status profiles

EMS- and Guest-Logistics-enabled departments now receive required, non-editable CAD status profiles. Ordinary CAD tasks use a clean Assigned (automatic) → En Route → On Scene → Working → Clear progression, with Available / Out of Service as unit availability states. EMS adds Transporting / At Hospital. Guest Logistics MOVE statuses remain completely separate from CAD task statuses. See `UPGRADE-TO-0.15.7.md`.


## v0.15.8 — Editable status templates + terminal CAD close

Event Admins can now edit Standard CAD, Guest Logistics CAD, and EMS CAD status templates while required workflow states remain protected. EMS/Guest Logistics departments inherit their applicable template and remain locked at the department level. On active CAD assignments, Available / Clear / Complete are now terminal actions that close the incident and release all committed units instead of merely clearing one assignment.

See `UPGRADE-TO-0.15.8.md`.


## v0.16.0 — Performance Release

Frontend-only. Adaptive Realtime-aware heartbeats replace per-second polling, structural reloads are coalesced, boards and modals render only on change, field devices load a fraction of the queries and keep their websocket channel and call map across refreshes, and PDF.js is split out of the main bundle. See `UPGRADE-TO-0.16.0.md`.


## v0.18.0 — Unified MOVE Incidents

Guest Logistics MOVEs are now CAD incidents of kind `MOVE`, created from a dedicated intake form or CSV import, scheduled ahead of time and auto-activated about an hour before pickup. One status engine, one assignment path, one acknowledgement flow, one audit log and one report pipeline for every ticket. A unit can hold one CAD ticket and one MOVE at once; the MOVE is primary by default and Dispatch can promote the CAD ticket. See `UPGRADE-TO-0.18.0.md`.
