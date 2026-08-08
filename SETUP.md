# CommCenter Pro Cloud v0.2 — Super Explicit Setup

This version is built for the architecture you described:

- One cloud CommCenter Pro platform.
- Multiple event-management companies ("Organizations" / tenants).
- Multiple events per organization.
- Departments such as EMS, Police, Security, Facilities, Production, Transportation, Guest Services, etc.
- Named accounts for platform admins, company admins, dispatchers and supervisors.
- Field devices do NOT need individual accounts.
- Field devices use an Event ID + 4-digit PIN, then select a department/unit.
- One incident can involve multiple departments and multiple units.
- Custom PDF event maps.
- Browser-based georeferencing using known GPS control points.
- W3W square library import with exact square bounds.
- Browser-created POIs/Common Names tied to the W3W square under the clicked point.
- Offline package download to a field device: map image + W3W square library.
- Dispatch log and CSV export.
- Cloud hosting with Netlify + Supabase. No private server is required.

IMPORTANT: This is an early development build, not a certified emergency/public-safety CAD. Keep radio/normal dispatch failover until you have thoroughly tested authentication, permissions, connectivity loss, reporting, recovery, backups and concurrent use.

---

# PART A — Replace the old starter code in GitHub

You said GitHub, Netlify and Supabase are already initially created.

## 1. Download and unzip this v0.2 package

Unzip the package on your computer.

The project root should look like:

```text
commcenter-pro-cloud-v2/
  index.html
  package.json
  netlify.toml
  .env.example
  README.md
  SETUP.md
  w3w_import_template.csv

  src/
    main.js
    mapBuilder.js
    georef.js
    pdfMap.js
    offlineStore.js
    style.css
    supabase.js

  public/
    manifest.webmanifest
    service-worker.js

  supabase/
    00_DEV_RESET_IF_NEEDED.sql
    01_FULL_SCHEMA.sql
    02_MAKE_ME_PLATFORM_ADMIN.sql
```

## 2. Replace the files in your existing GitHub repository

Your GitHub repository should have these files at the ROOT.

Correct:

```text
commcenter-pro/
  index.html
  package.json
  src/
  public/
  supabase/
```

Wrong:

```text
commcenter-pro/
  commcenter-pro-cloud-v2/
    index.html
```

If your repository only contains the earlier starter and you do not need any of those source files, replace the repository contents with the v0.2 package.

DO NOT upload a real `.env` file.

`.env.example` is safe to keep in GitHub because it contains placeholders only.

If using GitHub's browser:
1. Open your `commcenter-pro` repository.
2. Delete/rewrite the old starter files.
3. Upload the CONTENTS of this package.
4. Commit to `main`.

If using Git locally:

```bash
git add .
git commit -m "Upgrade CommCenter Pro to cloud v0.2 map builder"
git push
```

Netlify should automatically start a new deployment after the push.

---

# PART B — Update Supabase

## 3. Decide whether the old test database can be erased

If you already ran the previous starter SQL but only created demo/test data:

Run:

```text
supabase/00_DEV_RESET_IF_NEEDED.sql
```

in Supabase SQL Editor FIRST.

WARNING:
This deletes the known CommCenter Pro DEVELOPMENT tables from the old starter.

It does NOT delete Supabase Auth users.

Do not run the reset once you have real customer/event data.

If you did NOT run the previous starter database SQL, skip the reset.

## 4. Run the full v0.2 schema

Open:

```text
supabase/01_FULL_SCHEMA.sql
```

Copy the ENTIRE file.

In Supabase:
1. Open your CommCenter Pro project.
2. Click `SQL Editor`.
3. Click `New query`.
4. Paste the entire file.
5. Click `Run`.

A successful schema run may say that the command succeeded with no rows returned.

This schema creates:

```text
profiles
platform_admins
organizations
organization_members

events
event_staff
event_departments
staff_department_access
units
field_sessions

event_maps
map_control_points
event_w3w_squares
event_pois
poi_aliases

incidents
incident_departments
incident_units

unit_status_log
cad_activity
dispatch_log
```

It also creates a private Supabase Storage bucket:

```text
event-assets
```

That bucket holds:
- original uploaded PDFs
- rendered WebP site maps
- published offline W3W JSON packages

## 5. Confirm Anonymous Sign-Ins are enabled

This is required for field devices.

In Supabase:
1. Open `Authentication`.
2. Open the authentication provider/settings area.
3. Find `Anonymous Sign-Ins`.
4. Enable it.

Field users will never see a Supabase username/password screen.

They will see:

```text
Field Unit Access

Event ID: XR41
PIN: 4821
Operator: Max (optional)
```

CommCenter Pro creates an anonymous authenticated session behind the scenes.

## 6. Make your named account a CommCenter Pro PLATFORM ADMIN

You already need a normal named Supabase Auth account for yourself.

In Supabase:
1. Open `Authentication`.
2. Open `Users`.
3. Find your account.
4. Copy your User UUID.

Open:

```text
supabase/02_MAKE_ME_PLATFORM_ADMIN.sql
```

Find:

```sql
v_user uuid := 'YOUR_USER_UUID';
```

Replace `YOUR_USER_UUID`.

Example:

```sql
v_user uuid := '72be50a8-a073-4b9b-9c13-123456789abc';
```

Then:
1. Supabase -> SQL Editor -> New query.
2. Paste the edited file.
3. Run it.

This is the account that can create new customer organizations.

---

# PART C — Check your Netlify environment variables

## 7. Get your Supabase URL

In Supabase, find the API/project connection settings and copy the Project URL.

It looks like:

```text
https://abcdefghijk.supabase.co
```

## 8. Get your Supabase Publishable Key

Copy your client-side Publishable Key.

It typically begins similarly to:

```text
sb_publishable_...
```

DO NOT put a service-role or secret key into the web app.

## 9. Open Netlify

Open your existing CommCenter Pro site.

Go to the site's environment-variable settings.

You need exactly:

```text
VITE_SUPABASE_URL
```

Value:

```text
https://YOURPROJECT.supabase.co
```

and:

```text
VITE_SUPABASE_PUBLISHABLE_KEY
```

Value:

```text
YOUR SUPABASE PUBLISHABLE KEY
```

If your old starter used:

```text
VITE_SUPABASE_ANON_KEY
```

remove it or ignore it. v0.2 uses:

```text
VITE_SUPABASE_PUBLISHABLE_KEY
```

## 10. Confirm Netlify build settings

This package includes `netlify.toml`.

It specifies:

```text
Build command:
npm run build

Publish:
dist

Node:
22
```

Usually you should not need to manually override those in Netlify.

## 11. Redeploy

After the GitHub commit/push:
1. Open Netlify.
2. Open Deploys.
3. Wait for the latest `main` deployment.
4. It should say `Published`.

If the build fails:
1. Open the failed deploy.
2. Open the build log.
3. Copy the ERROR section.
4. Send it to me.

---

# PART D — First CommCenter Pro login

## 12. Open the Netlify URL

Before worrying about CommCenter.pro DNS, use the Netlify URL.

You should see:

```text
CommCenter Pro

Field Unit Access
Dispatcher / Admin Login
```

## 13. Sign in as staff

Choose:

```text
Dispatcher / Admin Login
```

Use the named account that you made a Platform Admin.

If you currently belong to no organizations, you should get:

```text
Organizations

+ Customer Organization
```

## 14. Create your first customer/company

Click:

```text
+ Customer Organization
```

Enter:

```text
Superior Event Management
```

or whatever organization you want to use for testing.

Click:

```text
Create Organization
```

CommCenter Pro creates the tenant and makes your platform-admin account an Owner of that organization.

This is how separate event-management companies are separated logically in CommCenter Pro.

---

# PART E — Create your first real event

## 15. Open the organization

Open the customer organization.

Click:

```text
+ Create Event
```

Enter:

```text
Event name:
XRoads41 2026

Event ID:
XR41

4-digit Field PIN:
4821

Incident Prefix:
XR26
```

Then:

```text
Create Event
```

Notes:

`Event ID` is the short identifier field devices enter.

`Incident Prefix` is used for calls:

```text
XR26-001
XR26-002
XR26-003
```

## 16. Open Event Admin

From Unified Dispatch click:

```text
Event Admin
```

The first admin page lets you manage:
- Field access/PIN
- Departments
- Units
- Map Builder

---

# PART F — Create departments

## 17. Add EMS

Under Departments:

```text
Name:
EMS

Short:
EMS

Statuses:
AVAILABLE,EN_ROUTE,ON_SCENE,TRANSPORTING,AT_HOSPITAL,AVAILABLE,OUT_OF_SERVICE
```

Click:

```text
Add Department
```

## 18. Add Security

```text
Name:
Security

Short:
SEC

Statuses:
AVAILABLE,RESPONDING,ON_SCENE,CLEAR,OUT_OF_SERVICE
```

## 19. Add Police

```text
Name:
Police

Short:
PD

Statuses:
AVAILABLE,RESPONDING,ON_SCENE,CLEAR,OUT_OF_SERVICE
```

## 20. Add Facilities

```text
Name:
Facilities

Short:
FAC

Statuses:
AVAILABLE,RESPONDING,WORKING,COMPLETE,OUT_OF_SERVICE
```

## 21. Add Production

```text
Name:
Production

Short:
PROD

Statuses:
AVAILABLE,RESPONDING,WORKING,COMPLETE,OUT_OF_SERVICE
```

You can add other departments too.

Examples:

```text
Transportation
Guest Services
Fire
Parking
Artist Services
Site Operations
```

---

# PART G — Create units

## 22. Add units

Under Units choose department + unit name.

Examples:

```text
EMS -> Medic 1
EMS -> Medic 2
EMS -> EMS Supervisor

Security -> Security 101
Security -> Security 102
Security -> Security Supervisor

Police -> PD 1
Police -> PD 2

Facilities -> Facilities 1
Production -> Site Ops 1
```

Each unit gets its department's status button set.

---

# PART H — Upload the event PDF in the Map Builder

## 23. Open the Map Builder

Event Admin:

```text
Map Builder
```

You should get five sections:

```text
1. Upload PDF map
2. Georeference
3. W3W library
4. Points of Interest
5. Publish map
```

## 24. Upload the PDF

Under:

```text
1. Upload PDF map
```

Click the file picker.

Choose the site's PDF plan.

Click:

```text
Upload & Render PDF
```

CommCenter Pro does the following IN YOUR BROWSER:

```text
PDF
  ↓
PDF.js renders Page 1
  ↓
~5000px-wide WebP image
```

Then uploads both:

```text
{event UUID}/map/source.pdf
{event UUID}/map/map.webp
```

to the private Supabase `event-assets` bucket.

The map should appear on the left.

You can pan and zoom it.

NOTE:
v0.2 uses PAGE 1 of the PDF. Multi-page map selection is a future improvement.

---

# PART I — Georeference the map

## 25. Understand what a control point is

You need places whose location is known in BOTH systems:

1. You can identify the exact location on the PDF.
2. You know its latitude/longitude.

For XRoads, you already have excellent controls:

```text
N1
43.9656552
-88.5977022

E1
43.9630906
-88.5942227

E2
43.9631001
-88.5935297

S3
43.9614315
-88.5981653

S5
43.9614605
-88.5947357

C1
43.9667633
-88.5911385

C3
43.9658593
-88.5915908

22
43.9642567
-88.5837769
```

## 26. Add N1

Click:

```text
Click Map to Add Control Point
```

The app says:

```text
Click the exact control point on the map.
```

Zoom WAY in.

Click the exact N1 point.

A form appears.

Enter:

```text
Name:
N1

Latitude:
43.9656552

Longitude:
-88.5977022
```

Click:

```text
Save Control Point
```

## 27. Repeat for all eight gates

Repeat using the values above.

VERY IMPORTANT:
Do not click the text label `N1`.

Click the physical location on the site plan that the GPS coordinate represents.

Consistency matters. For a gate, decide what the reference means:
- exact gate center
- centerline crossing
- specific corner

Then use that same interpretation for all controls.

## 28. Calculate

After all eight:

```text
Calculate Georeference
```

CommCenter Pro fits an affine transformation using ALL control points.

It calculates:
- latitude coefficients
- longitude coefficients
- residual error at each control point
- RMSE
- maximum error

You will see something similar to:

```text
RMSE
2.10 m

Maximum
4.05 m
```

The actual values depend on the map and where you clicked.

## 29. Judge accuracy

There is no magic fixed threshold in the software.

For event dispatch, inspect:
- average/RMSE
- maximum error
- individual outlier points
- where the controls are distributed

If one gate is far worse than all others:
1. Delete that control.
2. Re-add it more precisely.
3. Recalculate.

If error grows in a part of the property outside your controls, add control points in that area.

The current v0.2 transform is AFFINE.

That means it handles:
- translation
- scale
- rotation
- shear

It does NOT model complex local warping of a distorted site plan.

If the source drawing proves locally distorted, the next upgrade should be piecewise/polynomial georeferencing rather than pretending the affine result is better than it is.

---

# PART J — Import W3W squares

## 30. What CommCenter Pro needs

The W3W library must contain exact square bounds.

CommCenter Pro expects:

```text
words
south
north
west
east
```

Example FORMAT ONLY:

```csv
words,south,north,west,east
example.words.here,43.1230000,43.1230270,-88.1230370,-88.1230000
```

Do NOT use the example as real W3W data.

A blank template is included:

```text
w3w_import_template.csv
```

JSON is also accepted:

```json
[
  {
    "words": "example.words.here",
    "south": 43.1230000,
    "north": 43.1230270,
    "west": -88.1230370,
    "east": -88.1230000
  }
]
```

## 31. Licensing warning

CommCenter Pro v0.2 gives you the TOOLING to import/store/use a local W3W library.

It does NOT generate proprietary what3words assignments.

Only load W3W data that you are entitled to obtain, store and use under your what3words agreement/license.

## 32. Import

Map Builder:

```text
3. W3W library
```

Choose the CSV or JSON.

Click:

```text
Import W3W Squares
```

CommCenter Pro uploads the rows into PostgreSQL in chunks.

The counter should rise:

```text
Imported 500 / 72,143
Imported 1,000 / 72,143
...
```

## 33. Verify visually

After the import:

Zoom into the map.

Click:

```text
Show W3W Squares in View
```

CommCenter Pro:
1. Converts the visible map area back to GPS.
2. Queries W3W squares intersecting the viewport.
3. Draws those square polygons over the site map.
4. Lets you hover/tap them to see the 3-word address.

The visual overlay is capped at 2,500 squares per viewport so the browser isn't asked to draw a gigantic event library all at once.

## 34. Publish the offline W3W library

Click:

```text
Publish Offline W3W Library
```

CommCenter Pro builds one JSON file containing that event's W3W square library and uploads it to:

```text
{event UUID}/offline/w3w.json
```

in private Supabase Storage.

That file is what a field device can download before an event.

---

# PART K — Create common-name POIs

## 35. Add a POI

Map Builder:

```text
4. Points of Interest
```

Click:

```text
Click Map to Add POI
```

Zoom in and click the exact location.

For example click Main Medical.

The browser calculates the GPS coordinate.

CommCenter Pro then asks its LOCAL EVENT W3W database:

```text
Which W3W square contains this coordinate?
```

If one is loaded it displays:

```text
W3W: ///word.word.word
```

## 36. Name the POI

Enter:

```text
Common Name:
Main Medical

Category:
Medical

Aliases:
Main Med, Med Tent, Medical Tent

Notes:
Behind Unified Command
```

Click:

```text
Save POI
```

CommCenter Pro stores:

```text
POI:
Main Medical

Aliases:
Main Med
Med Tent
Medical Tent

GPS:
43.xxxxxx, -88.xxxxxx

W3W:
///word.word.word

W3W square ID:
[internal database reference]
```

The POI references the W3W square that contains its clicked coordinate.

## 37. Add more POIs

Examples:

```text
Main Medical
North Medical
Unified Command
Main Gate
Gate N1
Gate E1
Gate E2
Gate S3
Stage 1
Stage 2
Artist Compound
Production Office
Security HQ
Ambulance Staging
Bus Lot
Rideshare
North Parking
VIP Entrance
```

---

# PART L — Publish the map

## 38. Publish

After:
- PDF uploaded
- georeference calculated
- W3W loaded if desired
- POIs created

click:

```text
Publish Event Map
```

The event map becomes usable in Unified Dispatch.

The field map requires published status as well.

---

# PART M — Test POI dispatch

## 39. Return to CAD

Click:

```text
Back
```

then:

```text
Back to CAD
```

Click:

```text
+ New Incident
```

You now have:

```text
Use a POI
```

Choose:

```text
Main Medical
```

CommCenter Pro fills the underlying location from the POI:

```text
POI ID
map X/Y
latitude
longitude
W3W
Common name
```

Choose departments:

```text
EMS
Security
```

Enter:

```text
Call type:
Medical

Priority:
Urgent
```

Create the incident.

The incident display can say:

```text
Main Medical
///word.word.word
```

instead of forcing dispatch to speak raw coordinates.

---

# PART N — Test field-unit access

## 40. Use a second device / private browser

Go to the deployed CommCenter Pro site.

Choose:

```text
Field Unit Access
```

Enter the event's:

```text
Event ID:
XR41

PIN:
4821
```

Optional:

```text
Operator:
Max
```

Choose:

```text
EMS
```

then:

```text
Medic 1
```

The device now acts as Medic 1.

No individual field account is required.

## 41. Dispatch Medic 1

On the dispatcher device:
1. Open an incident.
2. Choose Medic 1.
3. Click Dispatch Unit.

On Medic 1's device the assignment should appear.

Press:
- En Route
- On Scene
- etc.

Those changes are timestamped into the audit/status tables.

---

# PART O — Download event map/W3W for offline field use

## 42. While the phone HAS internet

On the unit screen click:

```text
Download Event Map + W3W for Offline Use
```

The app downloads:
- published WebP event map
- published offline W3W JSON
- map calibration metadata
- POIs

and stores them in browser IndexedDB.

You should get:

```text
Saved offline: map + 72,143 W3W squares.
```

## 43. Test offline mapping

After download:
1. Open the current incident.
2. Open View on Event Map.
3. Put the phone into Airplane Mode.
4. Reload carefully / reopen the installed PWA.
5. Open the field map.

The saved map can be loaded from IndexedDB.

When you tap the field map, CommCenter Pro:
1. Converts map x/y to GPS locally.
2. Searches the downloaded W3W array locally.
3. Shows:

```text
///word.word.word
43.xxxxxx, -88.xxxxxx
```

IMPORTANT:
Offline MAP/W3W is one thing.
Offline CAD synchronization is another.

If there is no connectivity between field device and cloud Supabase:
- dispatch cannot send new live calls to that device
- status updates cannot reach dispatch in realtime

v0.2 does NOT claim to provide fully disconnected shared CAD operation.

---

# PART P — Reports

## 44. Close a call

Dispatcher:

```text
Close Incident
```

Enter disposition:

```text
Treated / Released
```

or:

```text
Transported
```

etc.

## 45. Reports

Click:

```text
Reports
```

The current Dispatch Log contains:
- incident number
- received time
- departments
- call nature
- priority
- common location
- W3W
- assigned units
- first responding/en-route
- first on-scene
- disposition
- clear

Click:

```text
Download CSV
```

PDF Event Summary/Daily Report is still a next-phase feature.

---

# PART Q — Add another event-management company

## 46. Return to Organizations

From the event list choose Organizations.

As a Platform Admin click:

```text
+ Customer Organization
```

Create:

```text
ABC Festival Operations
```

Now you have two tenants.

The intention is:

```text
Superior Event Management
  -> its own events

ABC Festival Operations
  -> its own events
```

The database uses organization/event access boundaries and RLS policies.

---

# PART R — Add named customer staff

## 47. Create the named user in Supabase Auth

For v0.2, named staff account creation still begins in Supabase Dashboard:

```text
Authentication -> Users -> Add User
```

Create the person's email/password account.

## 48. Assign that existing user in CommCenter Pro

Open:

```text
Organization Staff
```

Enter their exact Auth email.

Choose:

```text
Admin
Dispatcher
Viewer
Owner
```

Click:

```text
Add / Update Member
```

The user can now log in through Dispatcher/Admin Login.

A future version should replace the Supabase-dashboard user creation step with a secure server-side invitation workflow.

---

# PART S — What v0.2 DOES and DOES NOT include

## Included now

- Cloud Netlify frontend
- Cloud Supabase Postgres backend
- Supabase Auth
- Anonymous field access
- Tenant organizations
- Platform-admin customer creation
- Organization member assignment for existing Auth accounts
- Event creation
- 4-digit event PIN
- Multiple departments
- Department-specific status lists
- Multiple units
- Multi-department incidents
- Custom PDF map upload
- Client-side PDF -> WebP rendering
- Private Supabase map storage
- Control-point georeferencing
- Affine transformation
- residual/RMSE error display
- W3W exact-square CSV/JSON import
- W3W square visualization
- W3W offline JSON publishing
- POIs/common names
- POI aliases
- POI -> W3W square association
- Map-click incident creation
- POI incident creation
- Unit dispatch
- Field unit CAD
- Realtime status updates
- Offline field map/W3W package download
- Dispatch log
- CSV export

## Not fully built yet

- polished platform-admin dashboard
- secure email invitation workflow from inside CommCenter Pro
- department-restricted dispatcher permissions UI
- configurable call-type library
- configurable disposition library
- event templates
- PDF dispatch reports
- full event analytics dashboard
- unit timers/alerts
- multi-assignment unit handling
- call queue / pending-call workflow
- map version history
- multi-page PDF selector
- drawing/cropping/rotation controls
- higher-order/piecewise georeferencing
- W3W acquisition/generation itself
- resilient offline CAD synchronization
- dedicated on-premise/local event server mode
- billing/subscriptions
- customer branding/white label
- MFA enforcement UI
- support impersonation/audit workflow
- production backups/monitoring dashboards

---

# PART T — If something fails

## Netlify build fails
Send:
- the first red ERROR
- about 20 lines before/after it

## Staff login works but no organizations
Verify:
- your Auth UUID
- `02_MAKE_ME_PLATFORM_ADMIN.sql`
- `platform_admins` contains your UUID

## Upload returns 403/RLS
Verify:
- you are an Owner/Admin for that event's organization
- `event-assets` bucket exists
- Storage policies from `01_FULL_SCHEMA.sql` were created

## Field access says disabled
Check:
- Event Admin -> Field Access
- 4-digit PIN
- checkbox `Field access enabled`

## Field access errors immediately
Verify Supabase Anonymous Sign-Ins are enabled.

## Map is blank after upload
Check:
- Event Admin -> Map Builder
- upload status
- Supabase Storage -> event-assets -> [event UUID] -> map -> map.webp

## Georeference is wildly wrong
Most likely:
- map click was on the wrong physical point
- latitude/longitude was entered incorrectly
- control points are clustered
- PDF plan itself is distorted

Delete/re-add suspect controls.

## POI has no W3W
That coordinate is not covered by an imported `event_w3w_squares` record.
Import the W3W coverage first.

---

# RECOMMENDED NEXT BUILD AFTER THIS WORKS

Do not add ten more features immediately.

Prove this sequence first:

1. Platform Admin creates Organization A.
2. Organization A creates Event A.
3. Add EMS + Security + Production.
4. Add units.
5. Upload the real festival PDF.
6. Add your eight GPS controls.
7. Get a sensible georeference error.
8. Import a small TEST set of legitimate W3W squares around one part of the map.
9. Add Main Medical POI.
10. Create an incident at Main Medical.
11. Dispatch Medic 1.
12. Medic 1 receives it on an iPhone.
13. Medic 1 presses En Route / On Scene.
14. Dispatch sees the changes.
15. Report records them.
16. Download map/W3W offline.
17. Put the phone into Airplane Mode and verify map/W3W still work.

After that passes, the next coding sprint should be:
- polished Event Builder
- dispatcher department filters
- call type/disposition configuration
- PDF daily report
- map versioning
- W3W generator/import workflow appropriate to your license
- production hardening.
