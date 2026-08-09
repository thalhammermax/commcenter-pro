# CommCenter Pro v0.4.0 — Dark Command UI + Stadium / Multi-Level Venues

This release keeps all v0.3.1 dispatch and EMS functionality and adds the venue model needed for stadiums, arenas, convention centers, parking structures, and hybrid indoor/outdoor events.

## What changes

- Dark command-center UI throughout CommCenter Pro.
- Event venue type: Outdoor / Multi-Level / Hybrid.
- Multiple independent map layers per event.
- Each level has its own PDF, georeference, calibration error, POIs, and zones.
- Incident records store both horizontal coordinates and the selected vertical map layer.
- POIs can belong to a layer and zone.
- W3W remains event-wide and 2D; the map layer supplies vertical context.
- Vertical access points connect levels: elevator, stairwell, escalator, ramp, portal, vomitory, tunnel, gate, corridor.
- Dispatcher map has a live layer selector.
- Clicking an incident automatically changes to its map layer.
- Dispatcher can record a unit's current level/zone/post.
- Field assignment cards show the incident's level/zone.
- Offline field package downloads all published map layers plus the event W3W library.

## Upgrade an existing v0.3.1 system

### 1. Do not reset Supabase

Do NOT run `00_DEV_RESET_IF_NEEDED.sql` and do NOT rerun `01_FULL_SCHEMA.sql`.

### 2. Run the new database upgrade

Open:

`supabase/06_MULTI_LEVEL_VENUES.sql`

In Supabase:

1. SQL Editor
2. New query
3. Paste the entire file
4. Run

The upgrade preserves your current map, POIs, and incidents. Your existing single map is automatically migrated to a default layer named `Event / Site Level`.

### 3. Replace the application files in GitHub

The easiest method is to replace the repository contents with this v0.4.0 package, preserving `.env` only if you keep one locally. Netlify environment variables are not stored in GitHub and are unaffected.

At minimum replace:

- `src/main.js`
- `src/mapBuilder.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

And add:

- `supabase/06_MULTI_LEVEL_VENUES.sql`

### 4. Commit to `main`

Suggested message:

`Add multi-level venue maps and dark command UI`

### 5. Wait for Netlify

Netlify -> Deploys -> newest deploy -> `Published`.

Open the first test in a Private/Incognito window because the service-worker cache changed.

---

# Configure a stadium event

Event Admin -> Map Builder.

At the top choose:

`Venue type: Multi-Level Venue` or `Hybrid`.

For a venue like American Family Field, a reasonable layer stack could be:

- Exterior / Campus
- Field / Event Level
- Field Level / 100
- Club Level / 200
- Terrace Level / 300
- Dew Deck / 400
- Toyota Tundra Territory
- Harley-Davidson Deck
- Press Box / Suites
- Back of House
- Parking / Bus / Ambulance staging layers as needed

You do not need all of these on day one. Add the operationally useful maps you actually have.

For each layer:

1. Select the layer.
2. Upload that level's PDF.
3. Add at least three known GPS control points; use more widely distributed controls when available.
4. Calculate the georeference.
5. Review RMSE and maximum error.
6. Add zones such as `West Concourse`, `Third Base Side`, `Suite Corridor`, `Right Field`.
7. Add POIs such as `Section 312`, `Portal 311`, `Main Medical`, `North First Aid`, `Security Office`.
8. Publish the layer.

## Vertical access points

Choose `Click Map to Add / Link Access Point`.

Example on Level 100:

- Name: `Elevator E3`
- Type: Elevator
- Zone: West Concourse

Save the node.

Switch to Level 200, click the same physical elevator location, choose existing `Elevator E3`, and save another node.

Repeat for Level 300.

CommCenter Pro now knows:

`Elevator E3: Level 100 ↕ Level 200 ↕ Level 300`

The current release records these access connections. Automatic turn-by-turn venue routing is a later feature.

---

# Dispatcher behavior

The dispatcher map now has a Map Layer selector floating above the map.

A stadium incident can be stored as:

- Common name: Section 312
- Layer: Terrace Level / 300
- Zone: West Concourse
- W3W: the 2D W3W square underneath that area
- Map X/Y: exact location on the 300-level PDF

If the dispatcher clicks an incident that is on a different level, CommCenter Pro switches to that level automatically.

A unit can also be clicked in the unit board and assigned a current venue post such as:

`Medic 2 -> Terrace Level / 300 -> West Concourse`

This is intentionally separate from incident assignment and status.

---

# W3W in stadiums

W3W is intentionally not treated as a complete stadium address. The same W3W square can exist under multiple levels.

CommCenter Pro therefore uses:

`Map Layer + Zone + POI/Common Name + W3W + Lat/Lon`

For example:

`Section 312 / Terrace Level 300 / West Concourse / ///three.word.address`

That removes the vertical ambiguity.

---

# Offline field package

The field unit button `Download Event Map + W3W for Offline Use` now downloads every published map layer rather than only one map.

When a field crew opens an assigned incident, CommCenter Pro uses that incident's `map_layer_id` to open the correct saved level map.

Offline shared CAD synchronization still requires connectivity to Supabase. The downloaded layers/W3W are the resilient map/navigation package.

---

# First stadium test

Before loading a real large venue, prove this with two levels:

1. Create `Exterior / Campus`.
2. Create `Terrace Level / 300`.
3. Upload/georeference both.
4. Add a `West Concourse` zone to the 300 layer.
5. Add `Section 312` as a POI.
6. Add `Elevator E3` on both layers.
7. Publish both.
8. Create an incident using Section 312.
9. Confirm Dispatcher automatically shows the 300-level map.
10. Assign a field unit and verify its field CAD identifies the correct level.

Once that works, add the remaining stadium layers.
