-- ROBIN CRICK V15: team captain and wicket-keeper
-- Run once in the Supabase SQL Editor, after schema-v14.sql. Additive only.
alter table public.rcs_teams add column if not exists captain_id uuid references public.rcs_players(id) on delete set null;
alter table public.rcs_teams add column if not exists keeper_id  uuid references public.rcs_players(id) on delete set null;
notify pgrst, 'reload schema';
