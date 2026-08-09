# CommCenter Pro v0.2.2 UI Hotfix

This release fixes a dispatcher-board problem where an incident could be created
successfully in Supabase but disappear from the interface.

Changes:
- Incident base rows are loaded separately from relationship data.
- Department/unit relationship errors no longer blank the entire incident list.
- Supabase query errors are surfaced instead of silently converting to an empty list.
- Dispatcher refresh now clears previous Realtime subscriptions and Leaflet map instances.
- Incident creation logs a clear frontend error when the RPC fails.
- Fresh-install schema includes the earlier pgcrypto `extensions` search-path correction.

For an existing deployment, replacing `src/main.js` is sufficient for the UI fix.
No database reset is required.
