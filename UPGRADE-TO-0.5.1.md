# CommCenter Pro v0.5.1 — Live Field Unit Location

This release adds opt-in live GPS location sharing from field-unit devices to the Dispatch map.

## Privacy / storage model

v0.5.1 stores only the CURRENT location for a unit.

It does not create:
- breadcrumb history
- route history
- personnel tracking history

When the crew intentionally stops sharing, changes units, or leaves the field session, the current location row is removed.

If a browser/device disappears without cleanly stopping, Dispatch automatically treats the last location as stale and stops plotting it after five minutes.

## Browser permission

The field device must grant the CommCenter Pro website location permission.

The PWA uses:
`navigator.geolocation.watchPosition()`

Location sharing is not silently enabled. Event Admin first enables the feature for the event, then the field crew presses:

`Start Sharing Location`

The browser/OS displays its normal permission prompt.

## Important PWA background limitation

The web Geolocation API delivers position updates to fully active, visible documents.

Therefore this release is designed for the field CAD being open/visible.

If the phone is locked, the browser/PWA is backgrounded, or the page is otherwise hidden, continuous updates are NOT reliable and should not be treated like native background GPS tracking.

A future native iOS/Android wrapper would be required if CommCenter Pro needs dependable background location with the screen off.

## Dispatch behavior

Live field locations are drawn directly on the selected event map using the map layer's existing georeference transform.

Marker:
- blue = fresh location
- yellow/dim = stale location
- hidden after five minutes without an update

The unit tooltip shows:
- unit name
- CAD status
- location age
- reported GPS accuracy
- venue map layer

The unit board also shows:
`GPS now · ±8m`
or
`GPS 42s · ±14m`

GPS Realtime messages update only the marker and unit GPS line.

They do NOT rebuild the CAD screen, map, or incident-entry form.

## Multi-level stadiums

GPS gives latitude/longitude but cannot reliably identify the stadium level.

For multi-level events, the field screen now includes:

`Current Venue Level`
`Current Zone`

The crew can select:
`Terrace / 300`
`West Concourse`

CommCenter Pro then plots the GPS marker on that map layer.

If no level has been selected, the default event map layer is used.

## Update frequency

The device can receive GPS callbacks more frequently, but database writes are throttled:

- first fix: immediate
- while moving: approximately every 5 seconds at most
- stationary: approximately 15-second heartbeat
- movements below about 3 meters are ignored between heartbeats

This reduces unnecessary Supabase Realtime/database traffic and device battery usage while keeping the Dispatch position operationally useful.

## Event Admin

Event Admin -> Setup -> Field Access now contains:

`Allow field units to share live GPS location with Dispatch`

The setting defaults OFF after the migration.

Disabling it deletes current location rows for that event.

---

# Upgrade from v0.5.0

## 1. Supabase

Run:

`supabase/10_LIVE_FIELD_UNIT_LOCATION.sql`

Supabase
-> SQL Editor
-> New query
-> paste entire file
-> Run

Do not reset the database.
Do not rerun `01_FULL_SCHEMA.sql`.

## 2. GitHub

Replace:
- `src/main.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/10_LIVE_FIELD_UNIT_LOCATION.sql`

Suggested commit:

`Add opt-in live field unit GPS`

Wait for Netlify to publish.

---

# First test

## Event Admin

Open:
Event Admin -> Setup -> Field Access

Enable:
`Allow field units to share live GPS location with Dispatch`

Save.

## Field device

1. Join the event.
2. Claim a unit.
3. Find `Live Unit Location`.
4. If this is a stadium/multi-level venue, select the current map level.
5. Press `Start Sharing Location`.
6. Allow location when the browser asks.

The field screen should show:
`Location shared with Dispatch · accuracy ±Xm`

## Dispatch

Open the same map layer.

The unit should appear as a live GPS marker.

Pan/zoom the map and verify incoming location updates move the marker without resetting the map.

Start entering a new call but do not save it. Walk with the field device. The unit marker should move while the unfinished incident form remains untouched.

## Staleness test

Stop moving/location updates or background the field browser.

After approximately 30 seconds the marker becomes stale.
After five minutes with no update, CommCenter Pro stops plotting the marker.

## Stop test

On the field device press:
`Stop Sharing`

The marker should disappear from Dispatch through Supabase Realtime.
