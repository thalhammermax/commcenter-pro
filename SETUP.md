# CommCenter Pro v0.7.0 — Setup

CommCenter Pro is a cloud-hosted, multi-tenant event operations CAD/PWA.

## Production stack

- Frontend: Vite + JavaScript
- Hosting: Netlify
- Database/Auth/Realtime/Storage: Supabase
- Maps: Leaflet + PDF-derived event map images
- Source control: GitHub

## Initial installation

1. Create the private GitHub repository.
2. Upload the project files to the repository root.
3. Create the Supabase project.
4. For a fresh database, run `supabase/01_FULL_SCHEMA.sql`.
5. Enable Anonymous Sign-Ins in Supabase Auth.
6. Create the first named staff account.
7. Grant that user Platform Admin using the provided admin bootstrap SQL.
8. Create the Netlify site from the GitHub repository.
9. Add:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
10. Deploy.

Never expose the Supabase service-role/secret key in the Vite frontend.

## Organization setup

From Staff Login:

1. Create or select an organization.
2. Add organization staff as needed.
3. Create an event.
4. Configure departments.
5. Configure units.
6. Configure Field Access.
7. Configure EMS resources if used.

## Venue and maps

Open:

Event Admin
→ Map Builder

For each map layer:

1. Create the layer.
2. Upload the PDF.
3. Add at least three known GPS control points.
4. Calculate the georeference.
5. Add zones as needed.
6. Add POIs/common names.
7. Add vertical access points for multi-level venues.
8. Publish the layer.

Once a venue is configured, use:

Event Admin
→ Venue Maps
→ Save / Update Venue Library

Future events can begin from a published venue snapshot.

## Dispatcher workstation

Open Dispatch and select:

`Dispatching: <departments>`

Choose one or more departments for that workstation.

The selection controls:
- active-call board
- unit board
- incident markers
- live unit GPS markers
- default department selection on new calls

The dispatcher can override departments on an individual call.

## New incidents

Use:

`+ New Incident`

The popup supports:
- nature
- priority
- searchable POI
- map-picked location
- operational notes
- one or more departments
- initial unit assignment

`Pick on Map` preserves unfinished form entries while the dispatcher selects a location.

## Dispatcher-created POIs

Dispatch can create an event-only POI from any calibrated map point.

Use:
- `Add POI`
- `Find POI → Add POI from Map`
- or click a map point and choose `Add POI Here`

Dispatcher-created POIs remain event-scoped unless an admin later includes them in a new Venue Library version.

## Field unit access

Field users join with:
- Event ID
- four-digit field PIN
- department/unit selection

Field location sharing is opt-in.

When enabled by Event Admin, the field user can press:

`Start Sharing Location`

Dispatch receives the current GPS location through Supabase Realtime.

For multi-level venues, field users can also set the current map layer and zone.

## EMS patient flow

The CAD incident number is the patient reference.

There is no separate operator-facing patient tracking number.

Handoffs are direct custody transfers.

There is no request/accept workflow.

A field team can hand a patient directly to:
- a treatment area
- an ambulance

A treatment area can hand a patient directly to:
- an ambulance

Dispatch can place or transfer a patient directly to:
- a treatment area
- an ambulance

Treatment Area Station can also search an active incident and use:

`Mark Received Here`

to reconcile physical arrival.

The `ems_handoffs` table remains the historical custody-transfer ledger; new transfers are written as completed immediately.

## Treatment Area Station

Open:

CommCenter Pro
→ Treatment Area Station

Join the event, claim the treatment area, then use the station to:
- update treatment-area status
- create walk-in incidents
- receive an existing incident
- see patients currently in treatment
- hand a patient directly to an ambulance
- release/close a patient flow

## Command Center Display

From Dispatch:

`Command Display`

Modes:
- Calls
- Split
- Map

The display supports:
- independent department filters
- live active-call cards
- call elapsed timers
- assigned-unit statuses
- active incident map markers
- live GPS unit positions
- venue map-layer selection
- browser full screen

The display URL uses `?view=command`, allowing a dedicated command-center browser to return to that view after refresh when the authenticated event state is still available.

## Offline maps

Field devices can download published map layers for offline viewing.

Offline maps provide local venue navigation only.

Shared CAD changes still require connectivity to Supabase.

## Production checklist

Before operational use, validate:
- RLS policies
- staff roles
- field PIN controls
- anonymous-auth protections
- incident concurrency
- Realtime behavior
- map calibration accuracy
- field GPS accuracy
- offline map behavior
- audit log behavior
- backup/fallback dispatch procedures

CommCenter Pro should not be the sole operational dispatch path until the deployment has been tested under realistic event conditions.
