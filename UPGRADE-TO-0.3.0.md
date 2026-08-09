# Upgrade an existing CommCenter Pro deployment to v0.3.0

Do NOT reset the database and do NOT rerun the full schema.

## 1. Supabase

Open `supabase/04_EMS_OPERATIONS.sql`.

Copy the entire file into:

Supabase -> SQL Editor -> New query

Click Run.

Expected result: success/no rows returned.

This preserves all existing organizations, events, maps, POIs, units and incidents.

## 2. GitHub

Update these files in the existing `commcenter-pro` repository:

- Replace `src/main.js`
- Replace `src/style.css`
- Add `src/ems.js`

Also add `supabase/04_EMS_OPERATIONS.sql` to the repository for source history.

Do not run the updated `01_FULL_SCHEMA.sql` against the existing project.

Commit to `main`.

## 3. Netlify

Wait for the GitHub-triggered Netlify deployment to finish and show `Published`.

No new Netlify environment variables are required for v0.3.0.

## 4. Configure EMS

CommCenter Pro -> Dispatcher/Admin Login -> Event -> Event Admin -> EMS Setup

1. Configure existing EMS CAD units:
   - Field Team
   - Ambulance
   - EMS Command
2. Mark ambulances transport capable.
3. Create treatment areas.
4. Link each treatment area to its existing map POI when available.
5. Set treatment-area capacity.

## 5. Treatment-area tablet test

Open CommCenter Pro in a private/incognito browser or a second device.

Choose:

Treatment Area Station

Enter the event ID and the same 4-digit field PIN.

Select a treatment area.

The station dashboard should show its occupancy and incoming handoff queue.

## 6. End-to-end handoff test

1. Configure `Bike Team 1` as Field Team.
2. Configure `Medic 1` as Ambulance / transport capable.
3. Create `Main Medical` treatment area.
4. Assign Bike Team 1 to an EMS incident.
5. On Bike Team 1, click `Create Patient Tracking Record`.
6. Confirm a `PT-0001` style ID appears.
7. Request handoff to Main Medical.
8. On the Main Medical station, confirm the incoming handoff appears.
9. Click `Accept Handoff`.
10. Confirm Main Medical occupancy increases and the patient appears under Patients in Treatment.
11. From Main Medical, request Medic 1.
12. On Medic 1's field CAD, confirm the incoming patient handoff appears.
13. Click `Accept Patient`.
14. Enter destination and click `Start Transport`.
15. Click `Complete Transport / Handoff at Destination` when finished.
16. Open EMS Ops from dispatcher and confirm the handoff/custody changes were recorded.
