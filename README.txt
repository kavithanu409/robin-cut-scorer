ROBIN CUT SCORER V12

V12 adds a real Supabase data path for tournaments, teams, players, fixtures, matches and deliveries, while retaining a local cache.

SETUP:
1. Run schema-v12.sql once in Supabase SQL Editor.
2. Open the website.
3. Connection -> enter Project URL and the Supabase Publishable key.
4. Save & Test Connection.
5. Create a tournament; the record should appear in Supabase.

Never put a Supabase secret/service-role key in the browser or GitHub.

Next production phase: authenticated Admin/Scorer roles, realtime subscriptions, full two-innings lifecycle, player-level batting/bowling statistics, NRR, knockout generation, public match links and full cricket-law validation.
