ROBIN CUT SCORER V10
====================

This is the first integrated online-application foundation.

Phone setup:
1. Open index.html after publishing it.
2. Enter your Supabase Project URL and the PUBLIC Publishable key.
3. Never enter a secret/service-role key.
4. The application stores these two public connection values in the browser.

Database:
- Existing V9-style cricket tables are already created in the Supabase project.
- schema-v10.sql adds authentication profiles and a first RLS foundation.
- Before production, role-specific policies must be tightened and tested.

Important:
This package is a development foundation, not yet the final production deployment.
Next modules: login, admin dashboard, tournament CRUD, scorer, live public match page, and production deployment.
