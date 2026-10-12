-- ROBIN CRICK V14: cloud photos, player bio, man of the match, tournament rounds, storage alert
-- Run once in the Supabase SQL Editor, after schema-v13.sql. Additive only: nothing is dropped.
--
-- Part 1 = required.  Part 2 (bottom) = optional e-mail alert when the free plan fills up.

---------------------------------------------------------------------------
-- 1. NEW COLUMNS
---------------------------------------------------------------------------
alter table public.rcs_tournaments add column if not exists photo_url text;
alter table public.rcs_teams       add column if not exists photo_url text;
alter table public.rcs_players     add column if not exists photo_url text;
alter table public.rcs_players     add column if not exists jersey_number text;
alter table public.rcs_players     add column if not exists batting_style text;
alter table public.rcs_players     add column if not exists bowling_style text;
alter table public.rcs_players     add column if not exists bio text;
-- Man of the match chosen by the scorer/owner (falls back to the automatic top performer).
alter table public.rcs_matches     add column if not exists player_of_match text;
-- Round 1, 2, 3 ... of the points table. Old fixtures count as round 1.
alter table public.rcs_fixtures    add column if not exists round_no integer not null default 1;

---------------------------------------------------------------------------
-- 2. PHOTO STORAGE (public read, small JPEGs only, write = whoever may edit that record)
--    Files are stored as  tournaments/<id>.jpg, teams/<id>.jpg, players/<id>.jpg
---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rcs-photos', 'rcs-photos', true, 307200, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 307200, allowed_mime_types = array['image/jpeg'];

create or replace function public.rcs_photo_writable(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare kind text := split_part(p_name, '/', 1); rid uuid;
begin
  begin rid := split_part(split_part(p_name, '/', 2), '.', 1)::uuid;
  exception when others then return false; end;
  if kind = 'tournaments' then return public.rcs_can_manage(rid);
  elsif kind = 'teams' then return public.rcs_team_manageable(rid);
  elsif kind = 'players' then return public.rcs_team_manageable((select team_id from rcs_players where id = rid));
  end if;
  return false;
end $$;

drop policy if exists rcs_photo_read on storage.objects;
drop policy if exists rcs_photo_insert on storage.objects;
drop policy if exists rcs_photo_update on storage.objects;
drop policy if exists rcs_photo_delete on storage.objects;
create policy rcs_photo_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'rcs-photos');
create policy rcs_photo_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'rcs-photos' and public.rcs_photo_writable(name));
create policy rcs_photo_update on storage.objects for update to authenticated
  using (bucket_id = 'rcs-photos' and public.rcs_photo_writable(name));
create policy rcs_photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'rcs-photos' and public.rcs_photo_writable(name));

---------------------------------------------------------------------------
-- 3. STORAGE USAGE (shown to logged-in users in Account; free plan = 500 MB database, 1 GB files)
---------------------------------------------------------------------------
create or replace function public.rcs_storage_usage() returns jsonb
language sql stable security definer set search_path = public, storage as $$
  select jsonb_build_object(
    'db_bytes',    pg_database_size(current_database()),
    'db_limit',    500::bigint * 1024 * 1024,
    'files_bytes', coalesce((select sum((metadata->>'size')::bigint) from storage.objects), 0),
    'files_limit', 1024::bigint * 1024 * 1024);
$$;
revoke execute on function public.rcs_storage_usage() from public, anon;
grant execute on function public.rcs_storage_usage() to authenticated;

-- PostgREST picks up the new columns straight away.
notify pgrst, 'reload schema';


---------------------------------------------------------------------------
-- PART 2 (OPTIONAL): daily e-mail when the database or photo storage passes 80 %
-- 1. Create a free account at https://resend.com with the owner's e-mail address and copy an API key.
--    (Without a verified domain Resend only delivers to that same address, which is all we need.)
-- 2. Dashboard -> Database -> Extensions: enable pg_cron and pg_net.
-- 3. Replace the two values below, then run this part.
---------------------------------------------------------------------------
/*
select vault.create_secret('re_xxxxxxxxxxxxxxxxxxxxxxxx', 'rcs_resend_api_key');
select vault.create_secret('owner@example.com',            'rcs_alert_email');

create table if not exists public.rcs_alert_log (sent_at timestamptz primary key default now(), detail jsonb);
alter table public.rcs_alert_log enable row level security;   -- no policies: not readable from the app

create or replace function public.rcs_check_storage() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u jsonb := public.rcs_storage_usage();
        db_pct numeric := round(100.0 * (u->>'db_bytes')::numeric / (u->>'db_limit')::numeric, 1);
        fl_pct numeric := round(100.0 * (u->>'files_bytes')::numeric / (u->>'files_limit')::numeric, 1);
        key text; mail text;
begin
  if greatest(db_pct, fl_pct) < 80 then return; end if;
  if exists (select 1 from rcs_alert_log where sent_at > now() - interval '3 days') then return; end if;
  select decrypted_secret into key  from vault.decrypted_secrets where name = 'rcs_resend_api_key';
  select decrypted_secret into mail from vault.decrypted_secrets where name = 'rcs_alert_email';
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'from', 'Robin Crick <onboarding@resend.dev>', 'to', mail,
      'subject', 'Robin Crick: free plan storage at ' || greatest(db_pct, fl_pct) || '%',
      'html', format('<p>Database: <b>%s%%</b> of 500 MB<br>Photos: <b>%s%%</b> of 1 GB</p>'
                     '<p>Upgrade the Supabase plan or delete old tournaments before it is full, '
                     'so scoring keeps saving.</p>', db_pct, fl_pct)));
  insert into rcs_alert_log(detail) values (u);
end $$;

select cron.schedule('rcs-storage-alert', '0 6 * * *', 'select public.rcs_check_storage()');
*/
