# CommCenter Pro v0.5.4 — Field Status Button State

Frontend-only upgrade from v0.5.3.

No Supabase SQL is required.

## What changed

The Field Unit CAD status buttons now make the CURRENT status visually obvious.

All status choices keep a subtle semantic tint:

- Available / Clear / Complete → green
- Assigned / Responding / En Route / Returning → blue
- On Scene / Working / Loading → amber
- Transporting / At Hospital → purple
- Out of Service → red
- custom/unrecognized statuses → neutral slate

The currently selected status becomes a strongly filled button with:
- brighter semantic color
- white outline
- `CURRENT` marker
- `aria-pressed="true"` for accessibility

Example:

AVAILABLE     EN ROUTE      ON SCENE
subtle green  SOLID BLUE    subtle amber
              CURRENT

When the crew taps another status, the highlight moves immediately after Supabase confirms the update. Realtime status changes from Dispatch update the same button state without refreshing the Field CAD page.

## Upgrade

Replace:
- `src/main.js`
- `src/style.css`
- `public/service-worker.js`
- `package.json`

There is no database migration.

Suggested commit:

`Improve field status button indication`

Wait for Netlify to publish, then test in a private/incognito window once because the service-worker cache changed.

## Test

1. Open Field Unit Access.
2. Claim a unit.
3. Confirm the unit's existing status button is strongly filled and says `CURRENT`.
4. Tap EN ROUTE.
5. Confirm EN ROUTE becomes the highlighted button without the page/map refreshing.
6. From Dispatch, change the unit status.
7. Confirm the Field page moves the `CURRENT` highlight to the new status without a reload.
