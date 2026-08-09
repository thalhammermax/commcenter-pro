# CommCenter Pro v0.7.0 — Direct EMS Handoffs + GPS-First Mapping

Upgrade from v0.6.1.

This release changes the EMS custody model and retires W3W from the active application.

## 1. Handoff requests are gone

CommCenter Pro no longer uses:

- Request Handoff
- Pending Handoff
- Accept Handoff
- Decline Handoff
- Cancel Handoff

A handoff is now entered only when custody actually changes.

The operational model is:

Field Team
→ Hand Off
→ Treatment Area

or:

Field Team
→ Hand Off
→ Ambulance

or:

Treatment Area
→ Hand Off
→ Ambulance

The destination immediately becomes the current custodian.

There is no second acceptance step.

## Historical transfer record

The existing `ems_handoffs` table is retained as the custody-transfer history.

New handoff rows are created with:

`status = COMPLETED`

immediately.

The table is therefore a transfer ledger, not a request queue.

Any legacy `PENDING` handoff that exists when the migration is run is changed to `CANCELLED`.

The old request/accept RPCs are revoked from normal authenticated clients so an older UI cannot create new pending requests after this upgrade.

## 2. Dispatch can hand off to treatment OR ambulance

The incident popup action is now:

`EMS Handoff / Custody`

Dispatch sees current EMS custody and two direct destination controls:

- Hand Off to Treatment Area
- Hand Off to Ambulance

Dispatch can use this even if the incident did not already have an EMS flow row.

CommCenter Pro creates the internal custody record automatically using the CAD incident number as the patient reference.

## 3. Field team direct handoff

The field EMS panel now uses:

`Hand Off`

instead of:

`Request Handoff`

A field EMS team can directly hand the patient to:

- an accepting treatment area
- a configured ambulance / transport-capable EMS unit

Once confirmed:
- the field team loses custody
- the destination gains custody
- the transfer is written to the audit/history tables

## 4. Treatment Area Station

There is no Incoming Handoff request section anymore.

A patient transferred to a treatment area appears immediately under:

`Patients in Treatment`

The existing:

`Receive Existing Patient`

search remains available for reconciliation when the physical patient arrives and the electronic custody was not updated first.

Patients in treatment can now be handed directly to an ambulance with:

`Hand Off`

No ambulance acceptance is required.

## 5. Ambulance field page

When another resource or Dispatch hands a patient directly to an ambulance, the ambulance's field page receives the updated EMS encounter through Realtime.

The patient appears under Ambulance Custody without an acceptance screen.

The ambulance can then:
- start transport
- enter a destination
- complete transport
- close/other disposition where appropriate

## 6. EMS Operations

The EMS Operations screen no longer shows a Pending Handoffs metric or queue.

It shows:
- active EMS incidents
- patients with field teams
- patients in treatment
- patients with ambulances
- treatment-area occupancy
- ambulance custody
- current patient flow
- recent completed direct transfers

## 7. W3W retired

W3W has been removed from the active CommCenter Pro frontend.

Removed from:
- Map Builder
- POI creation
- POI search
- incident creation/editing
- incident display
- field call display
- offline map download
- reports/CSV
- Venue Library frontend asset copy
- field map coordinate lookup

Map location is now based on:
- calibrated event map
- POIs/common names
- zones
- map layers/levels
- latitude/longitude
- live unit GPS

The old W3W database columns/tables are not dropped by this migration.

They are left in place only so the upgrade is non-destructive and older historical data/migrations remain valid.

The v0.7 frontend does not read, display, import, search, or write W3W.

## 8. Help text / placeholders cleaned up

Form placeholders and helper copy no longer contain venue-, agency-, unit-, incident-, or location-specific examples.

Examples of the new generic field text:

- `Event name`
- `Event code`
- `POI name`
- `Search POIs`
- `Call type / nature`
- `Operational notes`
- `Unit name`
- `Treatment area name`
- `Transport destination`
- `Map layer name`
- `Zone name`
- `Access point name`

This keeps the product reusable for different organizations and event types.

---

# Upgrade from v0.6.1

## Step 1 — Supabase

Run:

`supabase/14_DIRECT_EMS_HANDOFFS.sql`

Go to:

Supabase
→ SQL Editor
→ New query
→ paste the entire file
→ Run

Do NOT reset the database.
Do NOT rerun `01_FULL_SCHEMA.sql`.

The migration also contains the v0.6.1 `cad_activity` actor-kind fix, so it is safe even if that small hotfix was not run separately.

## Step 2 — GitHub

Replace:
- `src/main.js`
- `src/ems.js`
- `src/mapBuilder.js`
- `src/venueLibrary.js`
- `src/offlineStore.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`
- `README.md`
- `SETUP.md`
- `START-HERE.md`

Add:
- `supabase/14_DIRECT_EMS_HANDOFFS.sql`

Remove:
- `w3w_import_template.csv`

Suggested commit:

`Simplify EMS custody and retire W3W`

Wait for Netlify to publish.

Because the service worker cache changed, use a private/incognito window for the first test or fully close/reopen the installed PWA.

---

# Test plan

## Field team -> treatment area

1. Assign an EMS field team to an incident.
2. On the field device choose a treatment area.
3. Click `Hand Off`.
4. Confirm the transfer.
5. Verify the patient disappears from the field team's custody.
6. Verify the patient appears immediately at the treatment area.
7. Verify no request/accept screen appears.

## Field team -> ambulance

1. Use another EMS incident.
2. On the field device choose an ambulance.
3. Click `Hand Off`.
4. Verify the ambulance field page receives the patient automatically.
5. Verify the sending field team no longer shows custody.

## Treatment area -> ambulance

1. Open a patient in Patients in Treatment.
2. Choose an ambulance.
3. Click `Hand Off`.
4. Verify the patient leaves the treatment-area census.
5. Verify the ambulance receives custody.

## Dispatch -> treatment area

1. Open an active incident.
2. Click `EMS Handoff / Custody`.
3. Choose a treatment area.
4. Click `Hand Off to Treatment Area`.
5. Verify the incident popup shows the treatment area as current custody.

## Dispatch -> ambulance

1. Open another active incident.
2. Click `EMS Handoff / Custody`.
3. Choose an ambulance.
4. Click `Hand Off to Ambulance`.
5. Verify the incident popup shows the ambulance as current custody.
6. Verify the ambulance field page updates automatically.

## Treatment Area Station reconciliation

1. Search an active incident under Receive Existing Patient.
2. Click `Mark Received Here`.
3. Confirm no `cad_activity_actor_kind_check` error occurs.
4. Verify the treatment area gains custody.

## GPS/map regression

1. Open Map Builder and confirm there are no W3W controls.
2. Add a POI.
3. Search that POI from Dispatch.
4. Create an incident using Pick on Map.
5. Verify live field GPS still plots correctly.
6. Download the event map for offline use.
7. Verify the offline field map works without any W3W package.

## Help-text regression

Review the main forms and confirm placeholders are generic and contain no hard-coded organization, venue, unit, incident, or location examples.
