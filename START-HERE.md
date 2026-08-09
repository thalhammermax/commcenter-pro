# CommCenter Pro v0.7.0 — Start Here

## Upgrade an existing v0.6.1 deployment

1. Run `supabase/14_DIRECT_EMS_HANDOFFS.sql` in Supabase SQL Editor.
2. Replace the v0.7.0 frontend files.
3. Commit to the production branch.
4. Wait for Netlify to publish.
5. Reopen the PWA or test once in a private/incognito window.

Do not reset the database.

## First validation sequence

### Dispatch

1. Open an event.
2. Choose the workstation's Dispatch Scope.
3. Create a new incident using the popup form.
4. Search for a POI.
5. Create another incident using Pick on Map.
6. Assign a unit.
7. Open the incident command popup and verify the activity timeline.

### Field

1. Join the event.
2. Claim a unit.
3. Verify the current status button is clearly highlighted.
4. Enable GPS sharing.
5. Verify the unit appears on the Dispatch map.
6. Change unit status and confirm Dispatch updates without rebuilding the call editor.

### Direct EMS handoff

1. Use an EMS field unit assigned to an incident.
2. Hand the patient directly to a treatment area.
3. Confirm the patient immediately appears in Patients in Treatment.
4. From the treatment area, hand the patient directly to an ambulance.
5. Confirm the ambulance field page receives the patient automatically.
6. Open the incident in Dispatch and confirm current custody and CAD Activity.

### Dispatch EMS custody

1. Open an active incident.
2. Choose `EMS Handoff / Custody`.
3. Hand the patient directly to a treatment area.
4. Repeat with another incident and hand the patient directly to an ambulance.
5. Confirm there is no request/accept step.

### Treatment Area reconciliation

1. Open Treatment Area Station.
2. Search for an active incident.
3. Choose `Mark Received Here`.
4. Confirm the patient appears in the treatment-area census and Dispatch custody view.

### Quick POI

1. From Dispatch choose `Add POI`.
2. Click a calibrated map location.
3. Enter a name and optional aliases.
4. Save.
5. Confirm the POI becomes searchable.

### Command Center Display

1. Open `Command Display`.
2. Test Calls view.
3. Test Split view.
4. Test Map view.
5. Filter by department.
6. Verify unit statuses and GPS locations update live.
7. Test Full Screen.
8. Refresh and confirm the command display returns.

## Current design rules

- Organization data is isolated by RLS.
- Venues are reusable organization resources.
- Events receive snapshots of venue versions.
- Event-specific POIs do not automatically change the venue template.
- Incident number is the EMS patient reference.
- EMS custody transfers are immediate.
- Live field GPS stores only the current unit position.
- Multi-level venues use the selected map layer/zone for vertical context.
- Dispatch call editing and creation use popup/modal workflows.
- Frequent status/GPS updates must not destroy unfinished dispatcher input.
