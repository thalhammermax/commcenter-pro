# CommCenter Pro v0.4.4 — Searchable POIs + Editable Incidents

Upgrade from v0.4.3.

## New: dispatcher POI search

Dispatch now has a `Find POI` button in the top navigation.

The search matches:
- POI common name
- aliases
- category
- map layer / stadium level
- zone
- W3W address

Example searches:
- `Main Medical`
- `Med Tent`
- `312`
- `West Concourse`
- `Gate 4`
- `///word.word.word`

Selecting a POI can:
- switch the dispatcher to the correct map layer;
- center the map on the POI;
- show its zone/W3W;
- create a new incident directly at that POI.

The New Incident form also replaces the long POI dropdown with the same searchable POI picker.

## New: Edit Call Details

Open any active incident and click:

`Edit Call Details`

Dispatch can now change:
- assigned departments
- call type / nature
- priority
- location by selecting a different POI
- location description
- dispatch notes

The incident number and original received time do not change.

Every save writes an `INCIDENT_UPDATED` entry to `cad_activity`.

## Upgrade steps

### 1. Supabase

Run:

`supabase/08_DISPATCH_POI_SEARCH_AND_INCIDENT_EDIT.sql`

Supabase -> SQL Editor -> New query -> paste -> Run

Do NOT reset the database.
Do NOT rerun the full schema.

### 2. GitHub

Replace:
- `src/main.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

Add:
- `supabase/08_DISPATCH_POI_SEARCH_AND_INCIDENT_EDIT.sql`

Commit to `main`.

Suggested commit:
`Add POI search and editable incident details`

Wait for Netlify to publish.

## Test POI search

1. Open Dispatch.
2. Click `Find POI`.
3. Search a common name.
4. Search one of that POI's aliases.
5. Select it.
6. Verify the map changes to the correct stadium level/map layer and centers on it.
7. Click `Create Incident Here`.

## Test call editing

1. Create an incident.
2. Open the incident.
3. Click `Edit Call Details`.
4. Change nature, priority, notes and department.
5. Save.
6. Reopen the incident and confirm the changes.
7. Edit again and search for a different POI.
8. Save and confirm the call moves to the new POI/layer/zone.

The visible incident number remains unchanged.
