# CommCenter Pro v0.4.2 — Department Status Selector

Frontend-only upgrade from v0.4.1.

No Supabase SQL is required.

## What changed

Event Admin -> Departments no longer requires a comma-separated status string.

When adding a department, you now get selectable checkboxes:

- Available
- Responding
- En Route
- On Scene
- Working
- Transporting
- At Hospital
- Returning
- Clear
- Complete
- Out of Service

Select exactly the statuses appropriate for that department.

`ASSIGNED` is not included in the manual list because CommCenter Pro applies that state automatically when Dispatch assigns the unit to a call.

Examples:

EMS:
- Available
- En Route
- On Scene
- Transporting
- At Hospital
- Returning
- Out of Service

Security / Police:
- Available
- Responding
- On Scene
- Clear
- Out of Service

Facilities / Production:
- Available
- Responding
- Working
- Complete
- Out of Service

## Existing departments

Existing departments now display their configured statuses as readable badges instead of raw JSON.

Each department has:

`Edit Statuses`

Click it to change the selectable field statuses. Saving updates the existing department and immediately changes the status buttons field units receive the next time their field interface loads.

## Upgrade

Replace in GitHub:

- `src/main.js`
- `src/style.css`
- `public/service-worker.js`

Commit to `main`.

Suggested commit:

`Add selectable department status options`

Wait for Netlify to publish.

No database migration is required.
