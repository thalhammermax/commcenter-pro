# CommCenter Pro v0.5.5 — Treatment Realtime Subscription Fix

Frontend-only hotfix from v0.5.4.

No Supabase SQL is required.

## Fixed error

Treatment Area Station could display:

`cannot add postgres_changes callbacks for realtime:treatment-... after subscribe()`

The problem was lifecycle-related, not a Supabase table/RLS problem.

The treatment dashboard re-renders whenever an EMS encounter, handoff, or treatment-area record changes. After the first render, the Realtime channel was already subscribed. The next render tried to add the same `postgres_changes` callbacks to that already-subscribed channel.

Supabase correctly rejects that.

## New behavior

v0.5.5 creates the treatment Realtime subscription once for the current:

`event + treatment area`

Normal dashboard re-renders REUSE the existing channel.

It does not call `.on(...)` again after `.subscribe()`.

When the station:
- changes treatment areas
- leaves the event
- starts a different treatment-area session

CommCenter Pro explicitly removes the previous channel before creating another one.

Channel names also receive a unique render timestamp as an additional guard against stale channel reuse.

## Race protection

Realtime refreshes are debounced.

A generation token prevents a delayed callback from an old treatment-area subscription from redrawing the new station after the user changes areas.

## EMS Ops

The EMS Ops command dashboard used a similar subscription lifecycle, so v0.5.5 fixes that proactively as well.

EMS Ops now reuses its subscribed Realtime channel during normal live refreshes rather than tearing it down and reconstructing it every time.

## Upgrade

Replace:
- `src/ems.js`
- `public/service-worker.js`
- `package.json`

No SQL migration is required.

Suggested commit:

`Fix EMS Realtime subscription lifecycle`

Wait for Netlify to publish.

Because the service worker cache changed, use a private/incognito window for the first test or fully close/reopen the installed PWA.

## Test

1. Open a Treatment Area Station.
2. Claim Main Medical.
3. From Dispatch, mark an incident handed off to Main Medical.
4. Confirm the patient appears without a Realtime subscription error.
5. At Main Medical, mark/receive another incident.
6. Confirm the dashboard refreshes normally.
7. Change Main Medical status between OPEN/LIMITED and confirm live updates continue.
8. Change to another treatment area and confirm no stale Main Medical updates redraw the new station.
