# CommCenter Pro v0.5.2 — Treatment-Area Custody Confirmation

This update makes treatment-area handoff reconciliation possible from BOTH sides.

The CAD incident number remains the patient reference.

## Dispatch

Open any active incident and click:

`EMS Treatment Handoff`

Dispatch sees:
- current EMS custody
- any pending handoff
- active treatment areas

Dispatch can choose a treatment area and click:

`Mark Patient Handed Off`

This is intended for radio/telephone confirmation such as:
"Bike Team 2 to Dispatch, patient transferred to Main Medical."

If a pending handoff to that treatment area exists, CommCenter Pro completes it.

If no pending electronic handoff was ever created, CommCenter Pro still records the real-world custody change.

## EMS Ops pending handoffs

Pending treatment-area handoffs now have:

`Mark Handed Off`

so Dispatch can resolve them directly from EMS Ops as well.

## Treatment Area Station

Incoming electronic handoffs now use the clearer button:

`Patient Received Here`

The station also gets a new:

`Receive Existing Patient`

section.

The treatment-area operator can search:
- incident number
- call type
- location/landmark

Then choose:

`Mark Received Here`

This handles the real-world case where a field team physically walks a patient into the treatment area before anyone entered the electronic handoff.

## Reconciliation behavior

Both Dispatch and Treatment Area Station update the SAME custody state.

Example:

`XR26-041`
Field Team 2
→ Main Medical

If Dispatch marks it handed off first:
- Main Medical immediately sees XR26-041 in Patients in Treatment.

If Main Medical marks it received first:
- Dispatch/EMS Ops immediately sees custody as Main Medical.

If both happen:
- the second confirmation is idempotent; CommCenter Pro reports that the patient is already there rather than creating a duplicate.

Any matching pending handoff is completed.
Other stale/conflicting pending handoffs are cancelled.

## Audit log

Every manual confirmation writes:

`EMS_TREATMENT_RECEIVED`

to `cad_activity` with:
- incident
- prior unit/treatment area
- receiving treatment area
- source (`staff` or `treatment`)
- handoff ID when applicable
- optional operational note

## Upgrade from v0.5.1

### Supabase

Run:

`supabase/11_TREATMENT_CUSTODY_CONFIRMATION.sql`

Supabase
→ SQL Editor
→ New query
→ paste the entire file
→ Run

Do not reset the database.
Do not rerun the full schema.

### GitHub

Replace:
- `src/main.js`
- `src/ems.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/11_TREATMENT_CUSTODY_CONFIRMATION.sql`

Suggested commit:

`Add two-way treatment area custody confirmation`

Wait for Netlify to publish.

## Test

1. Create/assign an EMS incident such as XR26-041.
2. From Dispatch, open XR26-041.
3. Click EMS Treatment Handoff.
4. Choose Main Medical.
5. Click Mark Patient Handed Off.
6. Confirm Main Medical immediately shows XR26-041 in Patients in Treatment.

Then test the opposite direction:

1. Create another incident.
2. Do not create a field handoff.
3. At Main Medical, search the incident number under Receive Existing Patient.
4. Click Mark Received Here.
5. Confirm EMS Ops shows current custody as Main Medical.
6. Open the incident in Dispatch and confirm the EMS Treatment Handoff panel shows Main Medical as current custody.
