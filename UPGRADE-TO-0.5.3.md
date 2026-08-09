# CommCenter Pro v0.5.3 — Incident Command Modal + Treatment Custody

This package includes the v0.5.2 treatment-area custody changes and adds a substantially richer Dispatch incident view.

If upgrading directly from v0.5.1, run:
`supabase/11_TREATMENT_CUSTODY_CONFIRMATION.sql`

There is no additional v0.5.3 database migration.

## Dispatch incident workflow

Clicking an incident no longer replaces the small right-side detail panel.

It opens a large incident command modal over the CAD.

The right side of Dispatch can remain dedicated to the persistent unit board and new-call workflow.

## Incident modal contents

The call popup shows:

Header
- incident number
- priority
- live elapsed timer
- call nature

Call Information
- received timestamp
- elapsed time
- departments
- incident status

Location
- common name / landmark
- stadium map layer
- zone
- W3W
- coordinates

Dispatch Notes
- full notes, not a shortened summary

Assigned Units
- every assigned unit
- current CAD status
- live GPS freshness/accuracy
- status control
- unassign control
- assign another unit

EMS / Patient Flow
- current custody
- treatment area / field unit / ambulance
- current EMS status
- pending handoff
- transport destination when present

CAD Activity
- chronological operational history
- creation
- call edits
- unit assignment/unassignment
- unit status changes
- EMS flow/handoffs
- treatment-area custody confirmations
- transport activity

Actions
- Edit Call Details
- EMS Treatment Handoff
- Show on Map
- Close Incident

## Call editing

`Edit Call Details` now opens inside the large modal instead of the Dispatch right sidebar.

The editor includes:
- departments
- nature
- priority
- searchable POI
- selected location
- location description
- full dispatch notes

A context panel keeps the original incident number, received time, elapsed time, and current location visible while editing.

The incident number and received time remain intentionally non-editable.

## Protecting dispatcher input

Routine unit-status and GPS updates already update in place.

v0.5.3 also protects an open call editor from structural Realtime updates.

If another dispatcher/unit changes CAD structure while you have unsaved call edits open:
- CommCenter Pro leaves every edit field untouched
- it displays a notice that other CAD data changed
- the dispatcher can finish Save or Cancel

Outside edit mode, call/unit structural changes refresh the boards and reopen the incident popup when appropriate.

## Treatment-area confirmation included

This package includes v0.5.2:

Dispatch can:
`Incident -> EMS Treatment Handoff -> Mark Patient Handed Off`

Treatment Area Station can:
`Receive Existing Patient -> search incident -> Mark Received Here`

Both update the same EMS custody state using the incident number as the patient reference.

---

# Upgrade from v0.5.1

## 1. Supabase

Run:
`supabase/11_TREATMENT_CUSTODY_CONFIRMATION.sql`

Do not reset the database.
Do not rerun the full schema.

## 2. GitHub

Replace:
- `src/main.js`
- `src/ems.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/11_TREATMENT_CUSTODY_CONFIRMATION.sql`

Suggested commit:
`Add incident command modal and treatment custody confirmation`

Wait for Netlify to publish.

## First test

1. Open Dispatch.
2. Click an active incident.
3. Confirm a large popup opens.
4. Verify location, notes, units, EMS custody and CAD Activity are visible.
5. Click Edit Call Details.
6. Change notes but do not save.
7. Change a field unit's status from another device.
8. Confirm the editor remains open and the typed notes remain intact.
9. Save the call.
10. Confirm the modal returns to the updated overview.

Then test:
`EMS Treatment Handoff`
and confirm the Treatment Area Station reflects the custody change.
