# CommCenter Pro v0.5.0 — Organization Venue Library

This release adds reusable, versioned venues at the organization level.

## Core model

Organization
→ Venue Library
→ Venue
→ Published Venue Version
→ Event Snapshot

A venue version stores:
- all map layers / stadium levels
- rendered map image and source PDF
- affine georeference/calibration
- map control points
- zones
- POIs
- POI aliases
- vertical access points and per-level nodes
- W3W square library
- offline W3W JSON when one has been published

When an event is created from a venue, CommCenter Pro COPIES the venue version into event-owned tables and event-owned Storage paths.

That means changing the master venue later does not change old events.

## Upgrade from v0.4.4

### 1. Supabase

Run:

`supabase/09_ORGANIZATION_VENUE_LIBRARY.sql`

in:

Supabase
→ SQL Editor
→ New query
→ paste entire file
→ Run

Do NOT reset the database.
Do NOT rerun the full schema.

The migration:
- creates the organization Venue Library tables
- adds `venue_id` and `venue_version_id` to events
- adds source/scope metadata to event map layers/zones/POIs
- expands private Storage RLS for organization venue assets
- adds server-side snapshot/save RPCs

### 2. GitHub

Replace:
- `src/main.js`
- `src/mapBuilder.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `src/venueLibrary.js`
- `supabase/09_ORGANIZATION_VENUE_LIBRARY.sql`

Suggested commit:

`Add organization Venue Library and reusable map snapshots`

Wait for Netlify to publish.

## First-time venue workflow

For an existing event whose venue map is already built:

Event Admin
→ Setup
→ Venue Maps
→ Save / Update Venue Library

Enter:
- Venue Name
- optional address
- version notes

Click:

`Save Venue to Organization`

CommCenter Pro:
1. snapshots the event map metadata into a draft venue version;
2. copies the map PDFs/images from the event Storage path into the organization venue Storage path;
3. copies the W3W library;
4. publishes the venue version;
5. marks it as the organization's current venue version.

## Create another event at the same venue

Go to:

Events
→ + Create Event

The new `Venue / Map Setup` selector contains all published organization venues.

Choose the venue, for example:

`American Family Field · v1`

Then create the event.

CommCenter Pro:
1. creates the normal event;
2. copies the selected venue version into event map tables;
3. copies every map PDF/image into the NEW event's private Storage folder;
4. copies calibration, zones, POIs, aliases, access routes and W3W;
5. links the event to the exact venue version used.

The Event Map Builder remains editable after the snapshot is created.

## Event-only POIs

POIs cloned from a Venue Library version are marked:

`Venue`

POIs added later inside a specific Event Map Builder are marked:

`Event`

Examples of event-only POIs:
- temporary EMS staging
- artist medical
- tour production
- credentialing
- temporary gate
- event-specific command post

This prevents a one-off event location from automatically contaminating the permanent venue template.

## Updating a venue

If an event is already linked to a Venue Library venue:

Event Admin
→ Venue Maps
→ Save / Update Venue Library

The screen changes to:

`Create a new version of <Venue Name>`

This creates a NEW immutable version.

You can optionally enable:

`Include event-only POIs in this new venue version`

Use that when an event-specific POI turned out to be a permanent/common venue location.

Leave it off for temporary event infrastructure.

Once published, the new version becomes the default for FUTURE events.

Existing events remain on the earlier snapshot.

## Venue Library page

From the organization Events screen:

`Venue Library`

The page shows:
- organization venues
- current published version
- version history
- venue type/address
- `Create Event from This Venue`

## Storage layout

Event assets continue to use:

`<eventUUID>/layers/<eventLayerUUID>/...`

Reusable organization venue assets use:

`venues/<organizationUUID>/<venueVersionUUID>/layers/<venueLayerUUID>/...`

Both remain inside the private `event-assets` Supabase Storage bucket.

Organization members can read their venue assets.
Only organization owners/admins can create/update venue assets.

## Important behavior

Applying a venue template is intentionally allowed only when the target event has a blank map configuration.

This prevents an accidental venue import from deleting or overwriting:
- an existing event map
- current event POIs
- incident location references

If you need to change an event that already has a map, edit that event's Map Builder normally.

## Recommended American Family Field workflow

Build American Family Field once with:
- Exterior / Campus
- Field / Event Level
- 100 Level
- 200 / Club
- 300 / Terrace
- Suites / Press
- Back of House
- parking/staging if needed

Add permanent venue POIs:
- seating sections
- portals
- gates
- elevators
- stairwells
- first aid rooms
- loading docks
- permanent security/operations rooms

Save it to the Venue Library.

Future events at American Family Field can then begin with the complete stadium setup already present, while temporary concert/event infrastructure stays event-specific.
