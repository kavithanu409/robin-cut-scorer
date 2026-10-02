-- ROBIN CUT SCORER V10 security foundation
-- Run only after the existing tables have been created.

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'viewer'
    check (role in ('super_admin','tournament_admin','scorer','viewer')),
  created_at timestamptz default now()
);

alter table profiles enable row level security;
alter table tournaments enable row level security;
alter table groups enable row level security;
alter table teams enable row level security;
alter table players enable row level security;
alter table fixtures enable row level security;
alter table matches enable row level security;
alter table deliveries enable row level security;
alter table playing_xi enable row level security;
alter table match_events enable row level security;

create or replace function public.is_authenticated()
returns boolean language sql stable as $$
  select auth.uid() is not null;
$$;

create or replace function public.current_role()
returns text language sql stable security definer set search_path=public as $$
  select role from public.profiles where id=auth.uid();
$$;

-- Basic policies: authenticated users may work with tournament data.
-- Public live-score reads can be added more narrowly when the public match page is wired.
drop policy if exists profiles_self_select on profiles;
create policy profiles_self_select on profiles for select using (id=auth.uid());

drop policy if exists profiles_self_update on profiles;
create policy profiles_self_update on profiles for update using (id=auth.uid()) with check (id=auth.uid());

drop policy if exists tournaments_auth_all on tournaments;
create policy tournaments_auth_all on tournaments for all to authenticated using (true) with check (true);

drop policy if exists groups_auth_all on groups;
create policy groups_auth_all on groups for all to authenticated using (true) with check (true);

drop policy if exists teams_auth_all on teams;
create policy teams_auth_all on teams for all to authenticated using (true) with check (true);

drop policy if exists players_auth_all on players;
create policy players_auth_all on players for all to authenticated using (true) with check (true);

drop policy if exists fixtures_auth_all on fixtures;
create policy fixtures_auth_all on fixtures for all to authenticated using (true) with check (true);

drop policy if exists matches_auth_all on matches;
create policy matches_auth_all on matches for all to authenticated using (true) with check (true);

drop policy if exists deliveries_auth_all on deliveries;
create policy deliveries_auth_all on deliveries for all to authenticated using (true) with check (true);

drop policy if exists playing_xi_auth_all on playing_xi;
create policy playing_xi_auth_all on playing_xi for all to authenticated using (true) with check (true);

drop policy if exists match_events_auth_all on match_events;
create policy match_events_auth_all on match_events for all to authenticated using (true) with check (true);

-- Automatically create a viewer profile when a new Auth user signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', new.email));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();
