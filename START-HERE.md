# CommCenter Pro — Start From Scratch Setup

Assumption: you have created user accounts at GitHub, Netlify, and Supabase, but you have NOT created/configured any CommCenter Pro projects yet.

Use the starter:
`commcenter-pro-cloud-v2.zip`

## Phase 1 — GitHub

1. Sign in to GitHub.
2. Click the `+` button in the upper-right corner.
3. Click `New repository`.
4. Repository name: `commcenter-pro`
5. Set visibility to `Private`.
6. Do NOT initialize it with a README, .gitignore, or license.
7. Click `Create repository`.
8. Download and unzip the CommCenter Pro starter package.
9. In the empty GitHub repository, choose `uploading an existing file` or `Add file -> Upload files`.
10. Upload the CONTENTS of the unzipped starter folder. The repository root must contain:
   - `index.html`
   - `package.json`
   - `netlify.toml`
   - `README.md`
   - `SETUP.md`
   - `.env.example`
   - `src/`
   - `public/`
   - `supabase/`
11. Do NOT upload a real `.env` file.
12. Commit the upload to the `main` branch.

## Phase 2 — Supabase project

13. Sign in to Supabase.
14. Create a new project.
15. Project name: `CommCenter Pro`
16. Create/save a strong database password.
17. Choose the region closest to the expected primary users.
18. Use the Free plan for initial development.
19. Wait for provisioning to complete.

## Phase 3 — Install the database schema

20. In the starter, open `supabase/01_FULL_SCHEMA.sql`.
21. Copy the entire file.
22. In Supabase, open `SQL Editor`.
23. Click `New query`.
24. Paste the SQL.
25. Click `Run`.
26. Do NOT run `00_DEV_RESET_IF_NEEDED.sql` on a new project.
27. After the script succeeds, open `Table Editor` and confirm tables such as:
    - `organizations`
    - `events`
    - `event_departments`
    - `units`
    - `event_maps`
    - `map_control_points`
    - `event_w3w_squares`
    - `event_pois`
    - `incidents`
28. Open `Storage` and confirm the private bucket `event-assets` exists.

## Phase 4 — Configure Supabase Authentication

29. In Supabase, open `Authentication`.
30. Enable Anonymous Sign-Ins.
31. Go to `Authentication -> Users`.
32. Create a named email/password user for yourself.
33. Copy your user's UUID.

## Phase 5 — Make yourself Platform Admin

34. In the starter, open `supabase/02_MAKE_ME_PLATFORM_ADMIN.sql`.
35. Replace `YOUR_USER_UUID` with your Supabase Auth user UUID.
36. Copy the edited script.
37. Supabase -> SQL Editor -> New query.
38. Paste it.
39. Click `Run`.
40. Do not commit your personalized UUID version back to GitHub.

## Phase 6 — Get the frontend connection values

41. In Supabase, open `Project Settings -> API Keys` (wording can vary slightly).
42. Copy the Project URL.
43. Copy the Publishable Key (`sb_publishable_...`).
44. Do not use a Secret key or service_role key in Netlify.

## Phase 7 — Create the Netlify project

45. Sign in to Netlify.
46. Click `Add new project`.
47. Click `Import an existing project`.
48. Choose GitHub.
49. Authorize Netlify to access your `commcenter-pro` repository if prompted.
50. Select the `commcenter-pro` repository.
51. Production branch: `main`.
52. The starter's `netlify.toml` already specifies:
    - Build command: `npm run build`
    - Publish directory: `dist`
    - Node version: 22
53. Before the final production test, add Netlify environment variables:
    - `VITE_SUPABASE_URL` = your Supabase Project URL
    - `VITE_SUPABASE_PUBLISHABLE_KEY` = your Supabase Publishable Key
54. Make sure those variables are available to Builds.
55. Deploy the site.
56. Wait for the deployment to show `Published`.

## Phase 8 — First application test

57. Open the temporary `*.netlify.app` URL.
58. You should see:
    - `Field Unit Access`
    - `Dispatcher / Admin Login`
59. Click `Dispatcher / Admin Login`.
60. Sign in with the named Supabase account you made Platform Admin.
61. You should reach the Organizations screen.
62. Click `+ Customer Organization`.
63. Create a test organization, for example `Superior Event Management`.

## Phase 9 — Create the first event

64. Inside the organization, click `+ Create Event`.
65. Example:
    - Event Name: `XRoads41 2026`
    - Event ID: `XR41`
    - Field PIN: `4821`
    - Incident Prefix: `XR26`
66. Click `Create Event`.
67. Open `Event Admin`.

## Phase 10 — Configure departments and units

68. Add departments. Example EMS:
    - Name: `EMS`
    - Short: `EMS`
    - Statuses: `AVAILABLE,EN_ROUTE,ON_SCENE,TRANSPORTING,AT_HOSPITAL,AVAILABLE,OUT_OF_SERVICE`
69. Example Security:
    - Name: `Security`
    - Short: `SEC`
    - Statuses: `AVAILABLE,RESPONDING,ON_SCENE,CLEAR,OUT_OF_SERVICE`
70. Add Police, Facilities, Production, Transportation, etc. as needed.
71. Add units, for example:
    - EMS -> Medic 1
    - EMS -> Medic 2
    - EMS -> EMS Supervisor
    - Security -> Security 101
    - Facilities -> Facilities 1
    - Production -> Site Ops 1

## Phase 11 — Upload and georeference a PDF map

72. Event Admin -> `Map Builder`.
73. Under `1. Upload PDF map`, choose the event PDF.
74. Click `Upload & Render PDF`.
75. Wait for the map to appear.
76. Under `2. Georeference`, click `Click Map to Add Control Point`.
77. Zoom in and click the exact known point.
78. Enter its name, latitude, and longitude.
79. Save.
80. Repeat with at least 3 points; preferably use many well-distributed controls.
81. Click `Calculate Georeference`.
82. Review RMSE, maximum error, and individual residuals.
83. Delete/re-add obvious outliers and recalculate as needed.

## Phase 12 — W3W library

84. CommCenter Pro does not generate proprietary W3W assignments itself.
85. Obtain W3W square data in a manner your W3W agreement/license permits.
86. Prepare CSV or JSON using:
    - `words`
    - `south`
    - `north`
    - `west`
    - `east`
87. A blank CSV template is included: `w3w_import_template.csv`.
88. Map Builder -> `3. W3W library`.
89. Select the file.
90. Click `Import W3W Squares`.
91. After import, zoom into the map and click `Show W3W Squares in View`.
92. Confirm the boxes align with the map.
93. Click `Publish Offline W3W Library`.

## Phase 13 — POIs/common names

94. Map Builder -> `4. Points of Interest`.
95. Click `Click Map to Add POI`.
96. Click the desired exact point.
97. Example:
    - Common name: `Main Medical`
    - Category: `Medical`
    - Aliases: `Main Med, Med Tent, Medical Tent`
    - Notes: `Behind Unified Command`
98. If W3W coverage exists at the point, CommCenter Pro automatically references that W3W square.
99. Save the POI.
100. Add other common-name locations such as gates, stages, command, security HQ, ambulance staging, rideshare, parking, etc.

## Phase 14 — Publish and dispatch

101. Map Builder -> `Publish Event Map`.
102. Return to CAD.
103. Click `+ New Incident`.
104. Choose a POI or click the map.
105. Choose one or more departments.
106. Enter call type, priority, and notes.
107. Create the incident.
108. Assign a unit.

## Phase 15 — Field-device test

109. On another phone/browser, open the Netlify URL.
110. Choose `Field Unit Access`.
111. Enter:
     - Event ID: `XR41`
     - PIN: `4821`
112. Choose department and unit.
113. From dispatch, assign that unit.
114. Verify the assignment appears on the field device.
115. Press a status such as `EN ROUTE`.
116. Verify the dispatcher sees the status change.

## Phase 16 — Offline map/W3W test

117. While the field device has internet, click `Download Event Map + W3W for Offline Use`.
118. Wait for the saved-offline confirmation.
119. Test the event map.
120. Put the device into Airplane Mode.
121. Verify the saved map can still display and local map taps can resolve GPS/W3W from downloaded data.
122. Remember: loss of internet prevents shared realtime CAD synchronization with Supabase. Offline map/W3W is a navigation fallback, not a fully disconnected shared CAD server.

## Phase 17 — Connect CommCenter.pro

123. Do this only after the Netlify URL works.
124. In Netlify open Domain management.
125. Add `CommCenter.pro`.
126. Follow Netlify's DNS instructions for the registrar/DNS provider holding the domain.
127. Make `CommCenter.pro` the primary domain after DNS validation and HTTPS provisioning.

## Phase 18 — GitHub/Supabase migrations later

128. Do NOT connect Supabase automatic GitHub database deployment on day one.
129. First get the manual initial schema + app working.
130. After the initial system is stable, baseline the existing schema into `supabase/migrations/` and then enable automatic migration deployment.
131. From then on, database changes should be new migration files rather than editing/re-running the original full schema.
