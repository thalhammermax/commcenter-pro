# Upgrade to CommCenter Pro v0.17.0 — Guest Logistics Task Priority

## Database (required)

Run against an existing v0.16.0 database, in the Supabase SQL Editor:

```sql
supabase/52_CAD_PRIORITY_OVERRIDE_AND_HELD_MOVES.sql
```

Do **not** rerun `01_FULL_SCHEMA.sql`. Deploy the frontend after the migration; the service-worker cache key was bumped, so hard-refresh browsers and reopen installed PWAs.

## What changed

### Task priority model
- Default (unchanged): a Guest Logistics unit's MOVE is its **primary** task; a CAD ticket on that unit is **secondary**.
- New: in the incident modal (assigned-unit row) or the unit-controls modal, Dispatch can **Prioritize This Ticket**. The override is stored on the active `incident_units` row, so it ends automatically when the ticket closes or the unit is cleared — no manual cleanup. **Return Priority to MOVE** ends it early.
- Each time, Dispatch chooses what happens to the MOVE(s):
  - **Place on HOLD** — MOVE status becomes `HELD` everywhere. When the override ends, the MOVE resumes its previous status (a leg that was en route/at pickup restarts at Driver Assigned; a guest already on board stays on board).
  - **Keep MOVE status running** — nothing changes on the MOVE; the unit is shown as diverted.
- If a guest is on board, prioritizing requires typing `DIVERT`.
- Only one CAD ticket per unit can hold priority.

### Driver acknowledgement
- The diverted driver's phone shows the red assignment alert ("Dispatch prioritized CAD-… over your MOVE") until they tap **ACKNOWLEDGE** (`field_acknowledge_cad_priority`). Dispatch sees **AWAITING DRIVER ACK** until then.
- The Field page reorders: the CAD ticket moves above the MOVE panel while the override is active.

### Screens
- **Dispatch unit cards**: primary task first, `⇅ DIVERTED TO CAD` tag, MOVE block labelled ON HOLD / SECONDARY.
- **Command Display**: MOVE cards show `HELD` / `DIVERTED — unit on CAD-…`; call-card unit chips show `PRIORITY CAD`.
- **Guest Logistics board**: HELD cards show which incident holds them, with **Resume MOVE Now** (`guest_logistics_resume_movement`).
- **Audit**: `CAD_PRIORITY_SET`, `CAD_PRIORITY_CLEARED`, `CAD_PRIORITY_ACKNOWLEDGED`, `LOGISTICS_MOVEMENT_RESUMED` in `cad_activity`; `MOVEMENT_HELD` / `MOVEMENT_RESUMED` in `guest_logistics_activity`.

### LATE / AT-RISK badges
Computed on every screen from the same rule:
- **LATE** (red): scheduled time passed and the guest has not been picked up (shows minutes late).
- **AT RISK** (amber): `NO DRIVER` within 15 min of pickup; `NO DRIVER ACK` 3 min after assignment; `HELD · PICKUP SOON`; `WAITING AT PICKUP` past the scheduled time.

### Driver suggestion
The Assign Driver dropdown is grouped and ranked for that pickup: Current driver → Free now → Has later MOVEs → On a CAD ticket → Schedule conflict (another MOVE within 45 min) → Not available (underway / out of service / diverted).

### Field MOVE queue
The first MOVE is shown in full; the rest appear as a compact **Upcoming** list with time, guest, route, risk badge and an ACK button when needed.

### Snapshot RPC
`dispatch_task_status_snapshot()` now returns `priority_override`, `priority_acknowledged_at`, `held_from_status` and `held_by_incident_id`. The frontend reconciles these like every other task field, so the Dispatch board self-corrects if a Realtime event is missed.

## Notes
- A `HELD` MOVE cannot be reassigned or unassigned until it is resumed (Resume MOVE Now on the Guest Logistics board, or Return Priority to MOVE on the unit).
- No changes to `units.status`, `incident_units.cad_status` or any status template: CAD and MOVE statuses remain fully independent.
