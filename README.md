# CommCenter Pro Cloud v0.2

CommCenter Pro is a cloud-hosted, multi-tenant, multi-department event operations CAD/PWA.

## Stack

- Frontend/PWA: Vite + JavaScript
- Event maps: Leaflet
- PDF rendering: PDF.js
- Cloud backend: Supabase Postgres/Auth/Realtime/Storage
- Hosting/CD: Netlify + GitHub
- Production domain: CommCenter.pro

## Major v0.2 capabilities

- Platform organizations/tenants
- Events, departments and units
- 4-digit field-access PIN
- Anonymous field-device Auth sessions
- Multi-department incidents
- Realtime unit dispatch/status
- PDF Map Builder
- GPS control-point georeferencing
- georeference error metrics
- exact-bound W3W square import
- W3W square visualization
- offline W3W package publishing
- POIs/common names + aliases
- POI-to-W3W association
- offline field map/W3W download
- dispatch log + CSV export

## Start here

Read:

`SETUP.md`

## W3W note

CommCenter Pro stores/uses W3W square records you import. It does not reproduce the proprietary W3W assignment algorithm. Only import/store data in a way allowed by your what3words rights/license.

## Operational note

This is development software. Do not use it as the sole dispatch path until you validate security, roles, connectivity behavior, backups, incident concurrency, audit logs, reporting and fallback procedures.
