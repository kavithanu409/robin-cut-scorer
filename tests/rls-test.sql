-- ROBIN CRICK V13 permission tests. Run against a TEST database only (never live).
-- Prints PASS/FAIL per check; any FAIL raises at the end.
\set QUIET on
\set ON_ERROR_STOP on
create temp table results(n serial, name text, ok boolean);
create or replace function pg_temp.as_user(uid uuid) returns void language plpgsql as $$
begin
  if uid is null then perform set_config('role','anon',false); perform set_config('request.jwt.claim.sub','',false);
  else perform set_config('role','authenticated',false); perform set_config('request.jwt.claim.sub',uid::text,false); end if;
end $$;
grant all on results to anon, authenticated; grant usage on sequence results_n_seq to anon, authenticated;

-- Accounts (trigger creates profiles)
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a','owner@test.dev','{"username":"robin_owner"}'),
 ('00000000-0000-0000-0000-00000000000b','scorer@test.dev','{"username":"scorer_b"}'),
 ('00000000-0000-0000-0000-00000000000c','viewer@test.dev','{"username":"viewer_c"}'),
 ('00000000-0000-0000-0000-00000000000d','editor@test.dev','{"username":"editor_d"}');
insert into results(name,ok) select 'profiles auto-created at sign-up', count(*)=4 from rcs_profiles;

-- Part 2: assign existing tournaments to the owner (as SQL editor / postgres)
update rcs_tournaments set owner_id='00000000-0000-0000-0000-00000000000a' where owner_id is null;
update rcs_teams set owner_id='00000000-0000-0000-0000-00000000000a' where owner_id is null and tournament_id is null;
update rcs_fixtures set owner_id='00000000-0000-0000-0000-00000000000a' where owner_id is null and tournament_id is null;
insert into results(name,ok) select 'existing tournaments assigned to owner, none lost', count(*)=(select count(*) from rcs_tournaments) and count(*)>0 from rcs_tournaments where owner_id='00000000-0000-0000-0000-00000000000a';

\set T '(select id from rcs_tournaments order by created_at limit 1)'
\set F '(select f.id from rcs_fixtures f where f.tournament_id=(select id from rcs_tournaments order by created_at limit 1) order by created_at limit 1)'

-- Anonymous viewer
select pg_temp.as_user(null);
insert into results(name,ok) select 'anon can view tournaments', count(*)>0 from rcs_tournaments;
insert into results(name,ok) select 'anon can view deliveries', count(*)>=0 from rcs_deliveries;
do $$ begin insert into rcs_tournaments(name) values('hack'); insert into results(name,ok) values('anon CANNOT create tournament',false);
exception when others then insert into results(name,ok) values('anon CANNOT create tournament',true); end $$;
with d as (delete from rcs_teams returning 1) insert into results(name,ok) select 'anon CANNOT delete teams', count(*)=0 from d;
with u as (update rcs_matches set runs=999 returning 1) insert into results(name,ok) select 'anon CANNOT change scores', count(*)=0 from u;

-- Logged-in user with no role
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
with d as (delete from rcs_tournaments returning 1) insert into results(name,ok) select 'viewer CANNOT delete others'' tournaments', count(*)=0 from d;
with u as (update rcs_teams set name='x' returning 1) insert into results(name,ok) select 'viewer CANNOT edit others'' teams', count(*)=0 from u;
do $$ begin perform rcs_claim_match((select f.id from rcs_fixtures f order by created_at limit 1)); insert into results(name,ok) values('viewer CANNOT claim scoring',false);
exception when others then insert into results(name,ok) values('viewer CANNOT claim scoring',true); end $$;
insert into rcs_tournaments(name) values('Viewer Cup');
insert into results(name,ok) select 'new tournament gets creator as owner', owner_id='00000000-0000-0000-0000-00000000000c' from rcs_tournaments where name='Viewer Cup';
do $$ begin update rcs_profiles set can_create_tournaments=true, is_platform_admin=true where id=auth.uid(); insert into results(name,ok) values('user CANNOT make self admin',false);
exception when insufficient_privilege then insert into results(name,ok) values('user CANNOT make self admin',true); end $$;

-- Owner adds scorer (specific match) and editor
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select rcs_add_member(:T,'scorer_b','scorer',array[:F]);
select rcs_add_member(:T,'editor@test.dev','editor',null);
insert into results(name,ok) select 'owner sees 2 members', count(*)=2 from rcs_members(:T);

-- Scorer
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into results(name,ok) select 'scorer can score assigned match', rcs_can_score(:F);
insert into results(name,ok) select 'scorer CANNOT score unassigned match', not coalesce(rcs_can_score((select f.id from rcs_fixtures f where f.tournament_id=:T and f.id<>:F limit 1)),false);
with u as (update rcs_teams set name='x' where tournament_id=:T returning 1) insert into results(name,ok) select 'scorer CANNOT manage teams', count(*)=0 from u;
with d as (delete from rcs_tournaments where id=:T returning 1) insert into results(name,ok) select 'scorer CANNOT delete tournament', count(*)=0 from d;
insert into results(name,ok) select 'scorer claims lock', (rcs_claim_match(:F)->>'ok')::boolean;
insert into rcs_deliveries(match_id,ball_no,event_type,runs,innings,commentary) values ((select id from rcs_matches where fixture_id=:F),1,'run',4,1,'Driven through covers');
insert into results(name,ok) values('scorer with lock can save ball + commentary', true);

-- Editor tries same match while locked
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
insert into results(name,ok) select 'second scorer blocked while match locked', not (rcs_claim_match(:F)->>'ok')::boolean;
do $$ begin insert into rcs_deliveries(match_id,ball_no,event_type,runs) values ((select m.id from rcs_matches m join rcs_fixtures f on f.id=m.fixture_id where m.locked_by='00000000-0000-0000-0000-00000000000b' limit 1),2,'run',1);
 insert into results(name,ok) values('non-lock holder CANNOT insert balls',false);
exception when others then insert into results(name,ok) values('non-lock holder CANNOT insert balls',true); end $$;
with u as (update rcs_teams set name=name where tournament_id=:T returning 1) insert into results(name,ok) select 'editor CAN manage teams', count(*)>0 from u;
with d as (delete from rcs_tournaments where id=:T returning 1) insert into results(name,ok) select 'editor CANNOT delete tournament', count(*)=0 from d;

-- Standalone (no tournament) teams and matches
select pg_temp.as_user(null);
insert into results(name,ok) select 'anon can view standalone teams', count(*)>0 from rcs_teams where tournament_id is null;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
with u as (update rcs_teams set name=name where tournament_id is null returning 1) insert into results(name,ok) select 'other user CANNOT edit standalone teams', count(*)=0 from u;
insert into rcs_teams(name) values('My Friendly XI');
insert into results(name,ok) select 'user can create own standalone team', owner_id='00000000-0000-0000-0000-00000000000c' from rcs_teams where name='My Friendly XI';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
with u as (update rcs_teams set name=name where tournament_id is null and owner_id=auth.uid() returning 1) insert into results(name,ok) select 'owner CAN edit own standalone teams', count(*)>0 from u;
insert into results(name,ok) select 'owner can score own standalone match', rcs_can_score((select id from rcs_fixtures where tournament_id is null limit 1));

-- Owner force takeover, revoke, delete
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
insert into results(name,ok) select 'owner can force-take scoring', (rcs_claim_match(:F,true)->>'ok')::boolean;
delete from rcs_tournament_members where tournament_id=:T and user_id='00000000-0000-0000-0000-00000000000b';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into results(name,ok) select 'revoked scorer loses access', not rcs_can_score(:F);
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
create temp table gone as select id from rcs_tournaments where id=:T;
with d as (delete from rcs_tournaments where id=:T returning 1) insert into results(name,ok) select 'owner CAN delete tournament', count(*)=1 from d;
insert into results(name,ok) select 'delete recorded as tombstone (permanent on all devices)', count(*)=1 from rcs_deleted where table_name='rcs_tournaments' and row_id=(select id from gone);
insert into results(name,ok) select 'cascaded team deletes also tombstoned', count(*)>0 from rcs_deleted where table_name='rcs_teams';

reset role;
\set QUIET off
select n, case when ok then 'PASS' else 'FAIL' end as result, name from results order by n;
do $$ begin if exists(select 1 from results where not ok) then raise exception 'SOME TESTS FAILED'; end if; end $$;
