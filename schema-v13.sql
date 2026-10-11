-- ROBIN CRICK V13: accounts, permissions, tournament pages, permanent delete
-- Run once in the Supabase SQL Editor, AFTER the backup and AFTER testing on the test project.
-- Additive only: no tables or data are dropped. The only things removed are the old
-- "anyone can write" policies, which are replaced by owner/scorer rules.
--
-- Part 1 = structure + security.  Part 2 (bottom) = assign existing tournaments to the owner account.

create extension if not exists pgcrypto;

---------------------------------------------------------------------------
-- 1. PROFILES (one row per account; username is unique, case-insensitive)
---------------------------------------------------------------------------
create table if not exists public.rcs_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text,
  can_create_tournaments boolean not null default true,
  is_platform_admin boolean not null default false,
  created_at timestamptz not null default now(),
  check (username ~ '^[A-Za-z0-9_.]{3,30}$')
);
create unique index if not exists rcs_profiles_username_key on public.rcs_profiles (lower(username));

-- Profile is created automatically at sign-up from the username sent by the website.
create or replace function public.rcs_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.rcs_profiles (id, username, display_name)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'username',''), 'user_' || substr(new.id::text,1,8)),
          coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'username'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists rcs_on_auth_user_created on auth.users;
create trigger rcs_on_auth_user_created after insert on auth.users
  for each row execute function public.rcs_handle_new_user();

-- Lets the sign-up form check a username before submitting.
create or replace function public.rcs_username_available(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.rcs_profiles where lower(username) = lower(p_username));
$$;

---------------------------------------------------------------------------
-- 2. NEW COLUMNS ON EXISTING TABLES (all nullable or defaulted: existing rows untouched)
---------------------------------------------------------------------------
alter table public.rcs_tournaments
  add column if not exists owner_id uuid references auth.users(id),
  add column if not exists is_public boolean not null default true,
  add column if not exists venue text,
  add column if not exists start_date date,
  add column if not exists end_date date,
  add column if not exists balls_per_over integer not null default 6,
  add column if not exists points_config jsonb;          -- groups for the points table (was phone-only)

-- Standalone teams and matches (no tournament) are owned directly by their creator.
alter table public.rcs_teams
  add column if not exists owner_id uuid references auth.users(id);

alter table public.rcs_fixtures
  add column if not exists owner_id uuid references auth.users(id),
  add column if not exists overs integer,                -- per-match overs (falls back to tournament overs)
  add column if not exists balls_per_over integer,       -- per-match balls per over (standalone matches)
  add column if not exists toss_winner uuid references public.rcs_teams(id) on delete set null,
  add column if not exists toss_decision text check (toss_decision in ('bat','bowl')),
  add column if not exists scorer_id uuid references auth.users(id),
  add column if not exists group_name text;

alter table public.rcs_matches
  add column if not exists result_text text,
  add column if not exists innings_data jsonb,           -- per-innings totals, used for NRR and summary
  add column if not exists batting_team uuid references public.rcs_teams(id) on delete set null,
  add column if not exists striker text,
  add column if not exists non_striker text,
  add column if not exists bowler text,
  add column if not exists locked_by uuid references auth.users(id),   -- active scorer
  add column if not exists locked_at timestamptz;

alter table public.rcs_deliveries
  add column if not exists innings integer,
  add column if not exists over_no integer,
  add column if not exists ball_in_over integer,
  add column if not exists batting_team uuid references public.rcs_teams(id) on delete set null,
  add column if not exists dismissed_player text,
  add column if not exists fielder text,
  add column if not exists commentary text,
  add column if not exists created_by uuid references auth.users(id) default auth.uid();

-- Deleting a team removes its fixtures; deleting a winner team clears the winner.
-- (Before, deleting a tournament directly failed because fixtures still pointed at its teams.)
do $$ declare r record; begin
  for r in select c.conname, c.conrelid::regclass::text as tbl, a.attname
           from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.contype = 'f' and c.confrelid = 'public.rcs_teams'::regclass
             and c.conrelid in ('public.rcs_fixtures'::regclass, 'public.rcs_matches'::regclass)
             and a.attname in ('team_a','team_b','winner')
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    execute format('alter table %s add constraint %I foreign key (%I) references public.rcs_teams(id) on delete %s',
                   r.tbl, r.conname, r.attname, case when r.attname = 'winner' then 'set null' else 'cascade' end);
  end loop;
end $$;

create index if not exists rcs_deliveries_match_idx on public.rcs_deliveries (match_id, innings, created_at);
create index if not exists rcs_fixtures_tournament_idx on public.rcs_fixtures (tournament_id);
create index if not exists rcs_teams_tournament_idx on public.rcs_teams (tournament_id);
create index if not exists rcs_players_team_idx on public.rcs_players (team_id);

---------------------------------------------------------------------------
-- 3. MEMBERS, INVITATIONS, MATCH ASSIGNMENTS
---------------------------------------------------------------------------
-- owner  = full control (one per tournament, mirrors rcs_tournaments.owner_id)
-- editor = scorer who may also manage teams, players and fixtures (granted by the owner)
-- scorer = may only score matches
create table if not exists public.rcs_tournament_members (
  tournament_id uuid not null references public.rcs_tournaments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','editor','scorer')),
  all_matches boolean not null default true,   -- false = only matches listed in rcs_match_scorers
  added_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (tournament_id, user_id)
);

create table if not exists public.rcs_match_scorers (
  fixture_id uuid not null references public.rcs_fixtures(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (fixture_id, user_id)
);

create table if not exists public.rcs_invites (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.rcs_tournaments(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  email text,                                   -- optional: only this email may accept
  role text not null default 'scorer' check (role in ('editor','scorer')),
  fixture_ids uuid[],                           -- optional: limit to these matches
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_by uuid not null references auth.users(id) default auth.uid(),
  accepted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days'
);

---------------------------------------------------------------------------
-- 4. PERMANENT DELETE: tombstones so every phone removes deleted records
---------------------------------------------------------------------------
create table if not exists public.rcs_deleted (
  table_name text not null,
  row_id uuid not null,
  deleted_at timestamptz not null default now(),
  deleted_by uuid default auth.uid(),
  primary key (table_name, row_id)
);
create or replace function public.rcs_log_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.rcs_deleted (table_name, row_id) values (TG_TABLE_NAME, old.id)
  on conflict (table_name, row_id) do update set deleted_at = now();
  return old;
end $$;
do $$ declare t text; begin
  foreach t in array array['rcs_tournaments','rcs_teams','rcs_players','rcs_fixtures','rcs_matches','rcs_deliveries'] loop
    execute format('drop trigger if exists rcs_log_delete on public.%I', t);
    execute format('create trigger rcs_log_delete after delete on public.%I for each row execute function public.rcs_log_delete()', t);
  end loop;
end $$;

---------------------------------------------------------------------------
-- 5. PERMISSION HELPERS (security definer so policies do not recurse)
---------------------------------------------------------------------------
create or replace function public.rcs_role(p_tournament uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from rcs_tournaments where id = p_tournament and owner_id = auth.uid()) then 'owner'
    else (select role from rcs_tournament_members where tournament_id = p_tournament and user_id = auth.uid())
  end;
$$;
create or replace function public.rcs_can_manage(p_tournament uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.rcs_role(p_tournament) in ('owner','editor'), false);
$$;
-- Standalone records (no tournament) are always public.
create or replace function public.rcs_can_view(p_tournament uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_tournament is null
      or exists (select 1 from rcs_tournaments where id = p_tournament and is_public)
      or public.rcs_role(p_tournament) is not null;
$$;
-- Tournament records: owner/editor. Standalone records: their creator.
create or replace function public.rcs_can_manage_row(p_tournament uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_tournament is null then p_owner = auth.uid() else public.rcs_can_manage(p_tournament) end;
$$;
create or replace function public.rcs_team_manageable(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.rcs_can_manage_row(tournament_id, owner_id) from rcs_teams where id = p_team), false);
$$;
create or replace function public.rcs_team_viewable(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.rcs_can_view(tournament_id) from rcs_teams where id = p_team), false);
$$;
create or replace function public.rcs_fixture_manageable(p_fixture uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.rcs_can_manage_row(tournament_id, owner_id) from rcs_fixtures where id = p_fixture), false);
$$;
create or replace function public.rcs_fixture_viewable(p_fixture uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.rcs_can_view(tournament_id) from rcs_fixtures where id = p_fixture), false);
$$;
create or replace function public.rcs_can_score(p_fixture uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from rcs_fixtures f
    where f.id = p_fixture and (
      (f.tournament_id is null and f.owner_id = auth.uid())
      or public.rcs_role(f.tournament_id) in ('owner','editor')
      or exists (select 1 from rcs_tournament_members m
                 where m.tournament_id = f.tournament_id and m.user_id = auth.uid() and m.role = 'scorer'
                   and (m.all_matches or exists (select 1 from rcs_match_scorers s
                                                 where s.fixture_id = f.id and s.user_id = auth.uid())))));
$$;
create or replace function public.rcs_team_tournament(p_team uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select tournament_id from rcs_teams where id = p_team;
$$;
create or replace function public.rcs_match_fixture(p_match uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select fixture_id from rcs_matches where id = p_match;
$$;
create or replace function public.rcs_fixture_tournament(p_fixture uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select tournament_id from rcs_fixtures where id = p_fixture;
$$;
-- True when the current user holds the scoring lock on this match.
create or replace function public.rcs_holds_lock(p_match uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from rcs_matches where id = p_match and locked_by = auth.uid());
$$;

---------------------------------------------------------------------------
-- 6. ONE ACTIVE SCORER PER MATCH
---------------------------------------------------------------------------
-- A lock expires after 10 minutes without a heartbeat, so a closed phone cannot block a match.
-- The owner can always take over (p_force).
create or replace function public.rcs_claim_match(p_fixture uuid, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m rcs_matches; holder text;
begin
  if not public.rcs_can_score(p_fixture) then raise exception 'You do not have scoring access for this match'; end if;
  insert into rcs_matches (fixture_id, status) values (p_fixture, 'not_started') on conflict (fixture_id) do nothing;
  select * into m from rcs_matches where fixture_id = p_fixture for update;
  if m.locked_by is null or m.locked_by = auth.uid() or m.locked_at < now() - interval '10 minutes'
     or (p_force and public.rcs_fixture_manageable(p_fixture)) then
    update rcs_matches set locked_by = auth.uid(), locked_at = now() where id = m.id;
    return jsonb_build_object('ok', true, 'match_id', m.id);
  end if;
  select username into holder from rcs_profiles where id = m.locked_by;
  return jsonb_build_object('ok', false, 'match_id', m.id, 'locked_by', holder, 'locked_at', m.locked_at);
end $$;
create or replace function public.rcs_release_match(p_fixture uuid) returns void
language sql security definer set search_path = public as $$
  update rcs_matches set locked_by = null, locked_at = null
  where fixture_id = p_fixture and locked_by = auth.uid();
$$;

---------------------------------------------------------------------------
-- 7. INVITATIONS
---------------------------------------------------------------------------
-- Add an existing user directly by username or email (owner only).
create or replace function public.rcs_add_member(p_tournament uuid, p_user text, p_role text default 'scorer',
                                                 p_fixture_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if public.rcs_role(p_tournament) is distinct from 'owner' then raise exception 'Only the tournament owner can add people'; end if;
  if p_role not in ('editor','scorer') then raise exception 'Invalid role'; end if;
  select p.id into uid from rcs_profiles p join auth.users u on u.id = p.id
   where lower(p.username) = lower(p_user) or lower(u.email) = lower(p_user) limit 1;
  if uid is null then return jsonb_build_object('ok', false, 'error', 'No account found. Send them an invitation link instead.'); end if;
  if uid = auth.uid() then raise exception 'You already own this tournament'; end if;
  insert into rcs_tournament_members (tournament_id, user_id, role, all_matches, added_by)
  values (p_tournament, uid, p_role, p_fixture_ids is null, auth.uid())
  on conflict (tournament_id, user_id) do update set role = excluded.role, all_matches = excluded.all_matches;
  delete from rcs_match_scorers s using rcs_fixtures f
   where s.fixture_id = f.id and f.tournament_id = p_tournament and s.user_id = uid;
  if p_fixture_ids is not null then
    insert into rcs_match_scorers (fixture_id, user_id)
    select f.id, uid from rcs_fixtures f where f.id = any(p_fixture_ids) and f.tournament_id = p_tournament
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'user_id', uid);
end $$;

-- Accept an invitation link while signed in.
create or replace function public.rcs_accept_invite(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i rcs_invites; my_email text;
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  select * into i from rcs_invites where token = p_token for update;
  if i.id is null or i.status <> 'pending' or i.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'This invitation is no longer valid');
  end if;
  select email into my_email from auth.users where id = auth.uid();
  if i.email is not null and lower(i.email) <> lower(my_email) then
    return jsonb_build_object('ok', false, 'error', 'This invitation was sent to a different email address');
  end if;
  insert into rcs_tournament_members (tournament_id, user_id, role, all_matches, added_by)
  values (i.tournament_id, auth.uid(), i.role, i.fixture_ids is null, i.created_by)
  on conflict (tournament_id, user_id) do update set role = excluded.role, all_matches = excluded.all_matches;
  if i.fixture_ids is not null then
    insert into rcs_match_scorers (fixture_id, user_id)
    select unnest(i.fixture_ids), auth.uid() on conflict do nothing;
  end if;
  update rcs_invites set status = 'accepted', accepted_by = auth.uid() where id = i.id;
  return jsonb_build_object('ok', true, 'tournament_id', i.tournament_id);
end $$;

-- Owner sees member usernames (profiles are otherwise private).
create or replace function public.rcs_members(p_tournament uuid)
returns table (user_id uuid, username text, role text, all_matches boolean, fixture_ids uuid[])
language sql stable security definer set search_path = public as $$
  select m.user_id, p.username, m.role, m.all_matches,
         array(select s.fixture_id from rcs_match_scorers s join rcs_fixtures f on f.id = s.fixture_id
               where s.user_id = m.user_id and f.tournament_id = m.tournament_id)
  from rcs_tournament_members m join rcs_profiles p on p.id = m.user_id
  where m.tournament_id = p_tournament and public.rcs_role(p_tournament) = 'owner';
$$;

-- Public scorer name for Match Info (username only, never email).
create or replace function public.rcs_usernames(p_ids uuid[])
returns table (id uuid, username text)
language sql stable security definer set search_path = public as $$
  select id, username from rcs_profiles where id = any(p_ids);
$$;

---------------------------------------------------------------------------
-- 8. OWNER IS SET AUTOMATICALLY ON NEW TOURNAMENTS
---------------------------------------------------------------------------
create or replace function public.rcs_set_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['rcs_tournaments','rcs_teams','rcs_fixtures'] loop
    execute format('drop trigger if exists rcs_set_owner on public.%I', t);
    execute format('create trigger rcs_set_owner before insert on public.%I for each row execute function public.rcs_set_owner()', t);
  end loop;
end $$;

-- Ownership can only change through Part 2 below (run by you in the SQL editor).
create or replace function public.rcs_keep_owner() returns trigger
language plpgsql as $$
begin
  if new.owner_id is distinct from old.owner_id and auth.uid() is not null then
    new.owner_id := old.owner_id;
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['rcs_tournaments','rcs_teams','rcs_fixtures'] loop
    execute format('drop trigger if exists rcs_keep_owner on public.%I', t);
    execute format('create trigger rcs_keep_owner before update on public.%I for each row execute function public.rcs_keep_owner()', t);
  end loop;
end $$;

---------------------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
---------------------------------------------------------------------------
-- Remove the old V12 "anyone can insert/update/delete" policies (and our own, so this file can be re-run).
do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('rcs_tournaments','rcs_teams','rcs_players','rcs_fixtures','rcs_matches','rcs_deliveries',
                               'rcs_profiles','rcs_tournament_members','rcs_match_scorers','rcs_invites','rcs_deleted')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.rcs_tournaments enable row level security;
alter table public.rcs_teams enable row level security;
alter table public.rcs_players enable row level security;
alter table public.rcs_fixtures enable row level security;
alter table public.rcs_matches enable row level security;
alter table public.rcs_deliveries enable row level security;
alter table public.rcs_profiles enable row level security;
alter table public.rcs_tournament_members enable row level security;
alter table public.rcs_match_scorers enable row level security;
alter table public.rcs_invites enable row level security;
alter table public.rcs_deleted enable row level security;

-- Tournaments
create policy rcs_t_read on public.rcs_tournaments for select to anon, authenticated
  using (is_public or public.rcs_role(id) is not null);
create policy rcs_t_create on public.rcs_tournaments for insert to authenticated
  with check (exists (select 1 from public.rcs_profiles where id = auth.uid() and can_create_tournaments));
create policy rcs_t_edit on public.rcs_tournaments for update to authenticated
  using (public.rcs_can_manage(id)) with check (public.rcs_can_manage(id));
create policy rcs_t_delete on public.rcs_tournaments for delete to authenticated
  using (owner_id = auth.uid());

-- Teams
create policy rcs_tm_read on public.rcs_teams for select to anon, authenticated
  using (public.rcs_can_view(tournament_id));
create policy rcs_tm_create on public.rcs_teams for insert to authenticated
  with check (tournament_id is null or public.rcs_can_manage(tournament_id));
create policy rcs_tm_edit on public.rcs_teams for update to authenticated
  using (public.rcs_can_manage_row(tournament_id, owner_id)) with check (public.rcs_can_manage_row(tournament_id, owner_id));
create policy rcs_tm_delete on public.rcs_teams for delete to authenticated
  using (public.rcs_can_manage_row(tournament_id, owner_id));

-- Players
create policy rcs_p_read on public.rcs_players for select to anon, authenticated
  using (public.rcs_team_viewable(team_id));
create policy rcs_p_write on public.rcs_players for all to authenticated
  using (public.rcs_team_manageable(team_id)) with check (public.rcs_team_manageable(team_id));

-- Fixtures (scorers may update toss and status of matches they score; only managers create/delete)
create policy rcs_f_read on public.rcs_fixtures for select to anon, authenticated
  using (public.rcs_can_view(tournament_id));
create policy rcs_f_create on public.rcs_fixtures for insert to authenticated
  with check (tournament_id is null or public.rcs_can_manage(tournament_id));
create policy rcs_f_edit on public.rcs_fixtures for update to authenticated
  using (public.rcs_can_manage_row(tournament_id, owner_id) or public.rcs_can_score(id))
  with check (public.rcs_can_manage_row(tournament_id, owner_id) or public.rcs_can_score(id));
create policy rcs_f_delete on public.rcs_fixtures for delete to authenticated
  using (public.rcs_can_manage_row(tournament_id, owner_id));

-- Matches (scoring requires the lock)
create policy rcs_m_read on public.rcs_matches for select to anon, authenticated
  using (public.rcs_fixture_viewable(fixture_id));
create policy rcs_m_create on public.rcs_matches for insert to authenticated
  with check (public.rcs_can_score(fixture_id));
create policy rcs_m_edit on public.rcs_matches for update to authenticated
  using (public.rcs_can_score(fixture_id) and (locked_by = auth.uid() or public.rcs_fixture_manageable(fixture_id)))
  with check (public.rcs_can_score(fixture_id));
create policy rcs_m_delete on public.rcs_matches for delete to authenticated
  using (public.rcs_fixture_manageable(fixture_id));

-- Deliveries (ball-by-ball and commentary; only the active scorer writes)
create policy rcs_d_read on public.rcs_deliveries for select to anon, authenticated
  using (public.rcs_fixture_viewable(public.rcs_match_fixture(match_id)));
create policy rcs_d_create on public.rcs_deliveries for insert to authenticated
  with check (public.rcs_holds_lock(match_id));
create policy rcs_d_edit on public.rcs_deliveries for update to authenticated
  using (public.rcs_holds_lock(match_id)) with check (public.rcs_holds_lock(match_id));
create policy rcs_d_delete on public.rcs_deliveries for delete to authenticated
  using (public.rcs_holds_lock(match_id) or public.rcs_fixture_manageable(public.rcs_match_fixture(match_id)));

-- Profiles: you see and edit only your own (others' usernames via rcs_usernames/rcs_members)
create policy rcs_pr_read on public.rcs_profiles for select to authenticated using (id = auth.uid());
create policy rcs_pr_edit on public.rcs_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
-- Users cannot grant themselves admin or creation rights.
revoke update on public.rcs_profiles from authenticated;
grant update (username, display_name) on public.rcs_profiles to authenticated;

-- Members: owner manages, members see their own row
create policy rcs_mem_read on public.rcs_tournament_members for select to authenticated
  using (user_id = auth.uid() or public.rcs_role(tournament_id) = 'owner');
create policy rcs_mem_edit on public.rcs_tournament_members for update to authenticated
  using (public.rcs_role(tournament_id) = 'owner') with check (public.rcs_role(tournament_id) = 'owner' and role <> 'owner');
create policy rcs_mem_delete on public.rcs_tournament_members for delete to authenticated
  using (public.rcs_role(tournament_id) = 'owner' or user_id = auth.uid());

create policy rcs_ms_read on public.rcs_match_scorers for select to authenticated
  using (user_id = auth.uid() or public.rcs_role(public.rcs_fixture_tournament(fixture_id)) = 'owner');
create policy rcs_ms_write on public.rcs_match_scorers for all to authenticated
  using (public.rcs_role(public.rcs_fixture_tournament(fixture_id)) = 'owner')
  with check (public.rcs_role(public.rcs_fixture_tournament(fixture_id)) = 'owner');

-- Invites: owner only (accepting goes through rcs_accept_invite)
create policy rcs_inv_all on public.rcs_invites for all to authenticated
  using (public.rcs_role(tournament_id) = 'owner') with check (public.rcs_role(tournament_id) = 'owner');

-- Tombstones are public so every device can remove deleted records.
create policy rcs_del_read on public.rcs_deleted for select to anon, authenticated using (true);

grant execute on function public.rcs_username_available(text) to anon, authenticated;
grant execute on function public.rcs_usernames(uuid[]) to anon, authenticated;

---------------------------------------------------------------------------
-- PART 2: ASSIGN EXISTING TOURNAMENTS TO THE OWNER ACCOUNT
-- Run AFTER the owner has signed up and verified their email on the new website.
-- Replace the email below with the owner's sign-up email.
---------------------------------------------------------------------------
-- update public.rcs_tournaments
--    set owner_id = (select id from auth.users where lower(email) = lower('OWNER_EMAIL_HERE'))
--  where owner_id is null;
-- update public.rcs_teams
--    set owner_id = (select id from auth.users where lower(email) = lower('OWNER_EMAIL_HERE'))
--  where owner_id is null and tournament_id is null;
-- update public.rcs_fixtures
--    set owner_id = (select id from auth.users where lower(email) = lower('OWNER_EMAIL_HERE'))
--  where owner_id is null and tournament_id is null;
-- update public.rcs_profiles set is_platform_admin = true
--  where id = (select id from auth.users where lower(email) = lower('OWNER_EMAIL_HERE'));
