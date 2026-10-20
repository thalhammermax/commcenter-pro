# Upgrade to CommCenter Pro v0.19.0 — Per-Unit Task Queue

Replaces the v0.18.0 "primary CAD / secondary MOVE" rule with a simple ordered queue per unit.

## Database (required)

Run against a **v0.18.0** database (migration 53 already applied):

```sql
supabase/54_UNIT_TASK_QUEUE.sql
```

Do not rerun `01_FULL_SCHEMA.sql`. Deploy the frontend afterwards; the service-worker cache key was bumped, so hard-refresh browsers and reopen installed PWAs.

## How the queue works

- `incident_units.queue_position`: 1 = **CURRENT**, 2, 3… = **QUEUED**. Any mix of CAD tickets and MOVEs. `is_primary` is now derived (position 1) so every existing status/close path keeps working.
- `units.status` mirrors the CURRENT task's status. Queued tickets never change the unit's status.
- **Assigning** a ticket to a busy unit appends it to the end of the queue (the assign dropdown now says "will queue as #n"). Units are no longer disabled in assign lists because they are busy.
- **Scheduled MOVEs** sit at the end of the queue in pickup-time order; when one activates it joins the end of the *active* queue and only becomes current if the unit has nothing else active.
- **When the current ticket closes or is cleared**, the next ticket becomes current automatically, its acknowledgement is reset, and the driver's phone shows the red alert for it.
- **Only Dispatch reorders**: `dispatch_set_unit_queue_position(p_incident_id, p_unit_id, p_position)`. Position 1 = Make Current. Making a ticket current while a guest is on board requires typing `DIVERT`.
- Status controls (Dispatch and Field) act only on the CURRENT task. A queued CAD ticket on the Field page shows "QUEUED #n — status controls unlock when this becomes your current task".

## Screens

- **Unit cards**: `CURRENT · …` line with status, then a compact `QUEUED · n` list (`#2 M-014 · Guest · Pickup 14:30`, `#3 CAD-0042 · …`). Badge reads e.g. `MOVE · GUEST ON BOARD +2`.
- **Incident modal**: each assigned unit shows `CURRENT · n QUEUED` or `QUEUED #n · current CAD-…` with **Make Current**, ▲, ▼. MOVE driver status buttons appear only when that MOVE is the unit's current task.
- **Unit Controls**: a **Task Queue** section listing every ticket in order with Open and reorder controls; MOVE driver status for a current MOVE; CAD status buttons for a current CAD ticket.
- **Field Unit**: the current task's card is first with its status buttons; everything else is queued (queued CAD tickets listed under the current CAD card with ACK buttons; queued MOVEs in the Upcoming list).
- **Command Display**: unit chips show `CURRENT` or `QUEUED #n · on CAD-…`; MOVE cards note when the driver is on a different ticket.

## Removed

All "primary / secondary / priority / diverted" wording and the `openPrimaryTaskModal` flow. `dispatch_set_primary_assignment` remains as a wrapper for `dispatch_set_unit_queue_position(…, 1)`; `field_acknowledge_primary_change` is no longer used (the normal assignment acknowledgement covers a promotion).
