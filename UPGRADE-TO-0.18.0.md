# Upgrade to CommCenter Pro v0.18.0 — Unified MOVE Incidents

Guest Logistics is rebuilt on the incident model. A MOVE is now a CAD incident with `incident_kind='MOVE'`, guest details in `incident_guest_details`, a scheduled pickup time, and a status that lives on `incident_units.cad_status` exactly like every other ticket.

## Database (required)

Run against a **v0.16.0** database in the Supabase SQL Editor:

```sql
supabase/53_UNIFIED_MOVE_INCIDENTS.sql
```

- Do **not** run migration 52 (v0.17.0 was superseded and is not part of this release).
- Do **not** rerun `01_FULL_SCHEMA.sql`.
- Existing `guest_logistics_movements` rows are converted into MOVE incidents (open ones keep their driver, status and acknowledgement; completed ones become closed incidents). The legacy tables are left in place for history.

Deploy the frontend after the migration; the service-worker cache key was bumped, so hard-refresh browsers and reopen installed PWAs.

## The model

| Concept | Where it lives |
| --- | --- |
| MOVE ticket | `incidents` row, `incident_kind='MOVE'`, number `M-001…` per event |
| Guest, party, route, flight, contact | `incident_guest_details` (1:1) |
| Pickup time / activation | `incidents.scheduled_at`, `activate_lead_minutes` (default 60), `activated_at` |
| Ticket lifecycle | `incidents.status`: `SCHEDULED` → `OPEN` → `CLOSED` |
| Driver assignment | `incident_units` (same row type as every CAD assignment) |
| MOVE status | `incident_units.cad_status`: `ASSIGNED` → `EN_ROUTE_PICKUP` → `AT_PICKUP` → `PASSENGER_ONBOARD` → `EN_ROUTE_DESTINATION`, then close |
| Close | `close_move_incident` with a MOVE disposition (`COMPLETE`, `NO_SHOW`, `CANCELLED`, `REASSIGNED`; editable per event, scope `MOVE`) |
| Primary task | `incident_units.is_primary` — a unit may hold one CAD ticket and one MOVE; exactly one is primary |

`units.status` always mirrors the unit's **primary** open assignment, so the unit board, GPS tooltips and Command Display never show "AVAILABLE" for a driver who is committed to a guest.

## Scheduling and activation

- A MOVE created more than `activate_lead_minutes` before pickup is `SCHEDULED`: visible on the Guest Logistics board, the driver's phone (queue) and the Dispatch "MOVES" strip, but not on the active incident board or map.
- Every dispatcher heartbeat calls `activate_due_move_incidents()`, which flips due MOVEs to `OPEN`, stamps the active Operational Period, and refreshes the assigned driver's status. **Activate Now** on the ticket does it manually; a driver tapping *En Route to Pickup* early activates it too.
- MOVEs can be scheduled for any day of the event. Numbering is per event (`M-###`), not per Operational Period.

## Priority between a MOVE and a CAD ticket

- Assigning a CAD ticket to a driver who has an active MOVE makes the ticket **secondary**; assigning an active MOVE to a unit on a CAD ticket makes the MOVE primary.
- **Prioritize This Ticket** (incident modal or Unit Controls) makes the CAD ticket primary. If a guest is on board, Dispatch must type `DIVERT`. The driver's phone shows a red **PRIORITY CHANGE** alert until acknowledged (`field_acknowledge_primary_change`), and the CAD card moves above the MOVE panel.
- **Return Priority to MOVE** / **Make MOVE Primary** reverses it.
- When the primary ticket closes or the unit is cleared, the remaining ticket becomes primary automatically (trigger `promote_remaining_primary_assignment`).
- The MOVE keeps its own status while secondary; there is no separate HOLD state in this model.

## Screens

- **Dispatch board**: active MOVEs appear as incidents with a `MOVE` badge, pickup time, route, driver status and LATE / AT-RISK badges. A "MOVES · n active · n scheduled · next 14:30" strip opens the Guest Logistics board.
- **Incident modal (MOVE)**: Guest Movement section, driver status buttons (Dispatch can drive the MOVE on the driver's behalf), Activate Now, Edit MOVE, Close MOVE with MOVE disposition, Prioritize controls.
- **Unit Controls**: MOVE list with status buttons for the primary MOVE, Open MOVE Ticket.
- **Guest Logistics board** (`src/moves.js`): Upcoming / Today / Active / Unassigned / At Risk filters, department filter, search, New MOVE, Import CSV, Export. Cards open the normal incident modal.
- **Field Unit**: MOVE panel shows the primary MOVE in full with ACKNOWLEDGE and status buttons; later MOVEs in a compact Upcoming queue; a secondary-task note when a CAD ticket has priority. Acknowledging a MOVE uses the same `field_acknowledge_assignment` RPC as a CAD ticket.
- **Command Display**: active MOVEs (including ones with no driver) as MOVE cards; call cards are CAD tickets only; unit chips show primary/secondary.
- **Reports**: MOVEs are incidents, so they appear in the Detailed Dispatch Log, CAD activity, unit status history and CSV exports with no extra work.

## Removed

- `src/logistics.js` (replaced by `src/moves.js`).
- Realtime subscriptions to `guest_logistics_movements`.
- Legacy RPCs (`guest_logistics_*`) are no longer called by the frontend; they remain in the database.

## RPCs added

`create_move_incident`, `update_move_incident`, `set_move_status`, `close_move_incident`, `activate_due_move_incidents`, `dispatch_activate_incident`, `dispatch_set_primary_assignment`, `field_acknowledge_primary_change`, `create_incident_v6` (CAD ticket linked to a MOVE via `related_incident_id`). `assign_unit` and `dispatch_task_status_snapshot` are redefined; `private.guest_logistics_primary_unit_status` now returns the primary assignment's status.
