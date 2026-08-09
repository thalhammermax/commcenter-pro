# CommCenter Pro v0.6.1 — Treatment Area Audit-Log Hotfix

This is a database-only hotfix for v0.6.0.

No frontend files need to be replaced.
No Netlify redeploy is required.

## Error fixed

When a Treatment Area Station used:

`Receive Existing Patient`
→ `Mark Received Here`

Supabase could return:

`new row for relation "cad_activity" violates check constraint "cad_activity_actor_kind_check"`

## Cause

Treatment-area custody confirmation records its audit source as:

`actor_kind = 'treatment'`

That is useful because the incident activity timeline can distinguish:

- staff / Dispatch confirmation
- field-unit activity
- system activity
- treatment-area confirmation

However, the original `cad_activity` table constraint only allowed:

`staff`
`field`
`system`

So the custody function reached the CAD audit-log insert and PostgreSQL rejected the `treatment` value.

## Fix

v0.6.1 expands the existing `cad_activity_actor_kind_check` constraint to allow:

`staff`
`field`
`system`
`treatment`

Nothing else about custody, access permissions, or incident behavior changes.

## Upgrade

Run:

`supabase/13_TREATMENT_ACTIVITY_ACTOR_KIND.sql`

In:

Supabase
→ SQL Editor
→ New query
→ paste the entire file
→ Run

Do NOT reset the database.
Do NOT rerun `01_FULL_SCHEMA.sql`.

That is the entire production upgrade.

## Retest

1. Open Treatment Area Station.
2. Claim the treatment area.
3. Search for an existing active incident.
4. Click `Mark Received Here`.
5. Confirm the incident appears in Patients in Treatment.
6. Open the incident in Dispatch.
7. Confirm EMS custody shows the treatment area.
8. Confirm CAD Activity shows `Treatment-area custody confirmed` with actor source `treatment`.

Dispatch-side `Mark Patient Handed Off` continues to record actor source `staff`.
