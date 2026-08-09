# CommCenter Pro v0.2.3 — Incident RLS Hotfix

Fixes:

`infinite recursion detected in policy for relation "incidents"`

The original policy graph was circular:

`incidents -> incident_units -> incidents`

v0.2.3 moves the field-assignment check into a private `SECURITY DEFINER`
helper function used only by RLS. This breaks the circular policy evaluation
while preserving the intended rule:

- named staff with event access can read event incidents;
- anonymous field sessions can read only incidents actively assigned to their unit.

For an existing deployment, run:

`supabase/03_FIX_INCIDENT_RLS_RECURSION.sql`

No database reset is required and existing incidents are preserved.
