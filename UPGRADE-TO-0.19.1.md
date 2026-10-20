# Upgrade to CommCenter Pro v0.19.1 — One ticket type on the Field page + MOVE activation setting

## Database (required)

Run against a v0.19.0 database:

```sql
supabase/55_MOVE_ACTIVATION_LEAD_SETTING.sql
```

Deploy the frontend afterwards; the service-worker cache key was bumped.

## Changes

- **Field Unit page shows one ticket type.** The layout blocks are now **Current Task** (whatever the unit's current ticket is — CAD call or MOVE — with its acknowledgement, details and status controls) and **Task Queue** (every other ticket in order, CAD and MOVE alike, each with an ACK button). The current task always renders before the queue. No "Secondary CAD Assignment" / "Primary MOVE" labels remain anywhere.
- **MOVE activation lead time is an event setting.** Event Admin → Guest Logistics → *Activate before pickup (minutes)*, default 60, range 5–1440. It applies to every MOVE still waiting to activate, and is shown on the MOVE intake form and the Guest Logistics board. The per-MOVE "Activate on board" dropdown was removed.
- A queued CAD ticket no longer contributes EMS/transport/map context on the phone; only the current ticket does.
