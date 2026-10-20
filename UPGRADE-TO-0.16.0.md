# Upgrade to CommCenter Pro v0.16.0

v0.16.0 is a performance release. There is **no database migration**: every change is in the frontend. Deploy the frontend, then hard-refresh browser clients and fully close/reopen installed PWAs (the service-worker cache key was bumped).

## Why Dispatch and Field felt slow

| Area | Before | After |
| --- | --- | --- |
| Dispatch heartbeat | 3 RPCs **every second** per workstation | 1 combined heartbeat every 10 s while Realtime is healthy, 3 s while degraded, paused when the tab is hidden |
| Realtime `incidents` event | Two independent full reloads (18 queries each), stacked concurrently during bursts | One coalesced reload (200 ms debounce, in-flight dedupe) |
| Unit / incident boards | `innerHTML` rebuilt and every click handler rebound on every tick | Rendered only when the HTML changed; one delegated click listener; scroll position preserved |
| Lookups | Linear `.find()` in nested loops (unit board was O(units × incidents × links)) | Map-based indexes, rebuilt lazily |
| Open incident/unit modal | Blanked to "Loading…" and refetched on every tick; typed destination text lost | Silent background refresh; DOM untouched when nothing changed |
| GPS markers | Destroyed and recreated every 10 s | Patched in place |
| Map image URL | New signed URL on every map setup | Cached until shortly before expiry |
| Field page render | ~15 mostly sequential queries | 1 session query + 3 parallel + EMS; event reference data cached 2 min |
| Field Realtime channel | Torn down and re-joined on every render | Keyed on unit/session and kept alive |
| Field poll | Every 1.5 s | 6 s while Realtime is healthy, 2.5 s while degraded, paused when hidden |
| Field call map | Destroyed on every refresh | Re-opened automatically after a refresh |
| Field alert pulses | Animated border/background/shadow on a full-screen layer (continuous repaint) | Opacity-only animations (compositor) |
| Command Display | Leaflet map rebuilt on every Realtime event | Map kept alive; boards and markers patched in place |
| Bundle | PDF.js (~1 MB) and QR library in the main bundle for every device | Loaded on demand (Map Builder / Treatment Station only); stable vendor chunks |
| Service worker | Network-first for everything | Cache-first for immutable hashed assets, network-first for the shell; old caches purged on activate |
| Queries | `venue_access_point_nodes` and `ems_unit_config` fetched unfiltered (whole table) | Scoped to the event via relationship embeds |

## Behavior notes

- A workflow modal (Close Incident disposition, transport outcome, walk-in, etc.) is no longer replaced by the incident overview when a background sync fires. Previously a status tick could discard the dispatcher's in-progress close.
- Call timers and GPS-age readouts pause while the tab is hidden and catch up on focus.
- `npm install` is unchanged; `vite.config.js` is new.
