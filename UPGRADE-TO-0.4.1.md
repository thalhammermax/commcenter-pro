# CommCenter Pro v0.4.1 — Field Stability + Call Timers

This is a frontend-only upgrade from v0.4.0.

NO Supabase SQL is required.

## Changes

### Field CAD no longer redraws when a crew changes status

Previously:

1. Crew tapped EN ROUTE.
2. `field_set_unit_status()` updated the unit.
3. `fieldUnitCad()` rebuilt the entire field page.
4. The embedded event map was destroyed/re-created or collapsed.

v0.4.1 changes that behavior.

Now:
1. Crew taps EN ROUTE.
2. Supabase saves the status.
3. Only the unit status badge/button state changes.
4. The current incident card and open map stay exactly where they are.

Realtime unit status updates from Dispatch behave the same way: only the status UI changes.

A full field-page refresh still occurs when the unit is actually assigned or unassigned from an incident, because the call content itself has changed.

### Count-up call timer

Every open incident now displays a live elapsed timer based on the incident's `created_at` timestamp.

Examples:

`04:37`

`1:12:08`

`1d 03:14:22`

The timer appears:
- on each incident in the dispatch incident list;
- in the dispatcher incident detail;
- on the field crew's active assignment.

It is calculated in the browser from the authoritative Supabase incident creation timestamp. No database writes happen every second.

## Upgrade

Replace in GitHub:

- `src/main.js`
- `src/style.css`
- `public/service-worker.js`

Commit to `main`.

Suggested commit message:

`Stop field map refreshes and add incident timers`

Wait for Netlify to publish.

For the first test, use a private/incognito browser window.

## Test 1 — Stable field map

1. Log into Field Unit Access.
2. Claim a unit with an active incident.
3. Open `View on Event Map`.
4. Pan/zoom the map somewhere obvious.
5. Tap `EN ROUTE`.
6. Confirm the map stays open at the same pan/zoom.
7. Tap `ON SCENE`.
8. Confirm it still does not redraw.

## Test 2 — Dispatcher changes crew status

1. Keep the field map open.
2. From Dispatch, change that unit's status.
3. The field status badge should update.
4. The field map should remain open and untouched.

## Test 3 — Assignment change

Assignment changes intentionally still reload the field incident panel.

If Dispatch assigns or clears the unit, the field screen refreshes so the new/removed incident is displayed.

## Test 4 — Timers

Create a test incident.

The dispatch call card and field assignment should both start counting from the SAME incident `created_at` time.

Refreshing a browser should not reset the timer.
