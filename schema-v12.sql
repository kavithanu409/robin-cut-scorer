-- ROBIN CUT SCORER V12
-- Run this once in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.rcs_tournaments (
 id uuid primary key default gen_random_uuid(), name text not null,
 format text not null default 'League', overs integer not null default 10,
 created_at timestamptz not null default now()
);
create table if not exists public.rcs_teams (
 id uuid primary key default gen_random_uuid(), tournament_id uuid not null references public.rcs_tournaments(id) on delete cascade,
 name text not null, created_at timestamptz not null default now()
);
create table if not exists public.rcs_players (
 id uuid primary key default gen_random_uuid(), team_id uuid not null references public.rcs_teams(id) on delete cascade,
 name text not null, role text not null default 'Batter', created_at timestamptz not null default now()
);
create table if not exists public.rcs_fixtures (
 id uuid primary key default gen_random_uuid(), tournament_id uuid not null references public.rcs_tournaments(id) on delete cascade,
 team_a uuid not null references public.rcs_teams(id), team_b uuid not null references public.rcs_teams(id),
 venue text, match_time timestamptz, status text not null default 'scheduled', created_at timestamptz not null default now(),
 check(team_a <> team_b)
);
create table if not exists public.rcs_matches (
 id uuid primary key default gen_random_uuid(), fixture_id uuid unique not null references public.rcs_fixtures(id) on delete cascade,
 status text not null default 'not_started', innings integer not null default 1, runs integer not null default 0,
 wickets integer not null default 0, target integer, winner uuid references public.rcs_teams(id), updated_at timestamptz not null default now()
);
create table if not exists public.rcs_deliveries (
 id uuid primary key default gen_random_uuid(), match_id uuid not null references public.rcs_matches(id) on delete cascade,
 ball_no integer not null, event_type text not null, runs integer not null default 0,
 striker text, non_striker text, bowler text, created_at timestamptz not null default now()
);

alter table public.rcs_tournaments enable row level security;
alter table public.rcs_teams enable row level security;
alter table public.rcs_players enable row level security;
alter table public.rcs_fixtures enable row level security;
alter table public.rcs_matches enable row level security;
alter table public.rcs_deliveries enable row level security;

do $$ begin
 create policy rcs_t_select on public.rcs_tournaments for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_t_insert on public.rcs_tournaments for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_tm_select on public.rcs_teams for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_tm_insert on public.rcs_teams for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_p_select on public.rcs_players for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_p_insert on public.rcs_players for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_f_select on public.rcs_fixtures for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_f_insert on public.rcs_fixtures for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_m_select on public.rcs_matches for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_m_insert on public.rcs_matches for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_m_update on public.rcs_matches for update to anon, authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_d_select on public.rcs_deliveries for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_d_insert on public.rcs_deliveries for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
 create policy rcs_d_delete on public.rcs_deliveries for delete to anon, authenticated using (true);
exception when duplicate_object then null; end $$;
