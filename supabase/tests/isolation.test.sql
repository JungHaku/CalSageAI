-- Cal Coherence — RLS behaviour, not RLS structure
-- ARCHITECTURE.md §11.6, §5.2
--
-- `rls.test.sql` proves the catalog is shaped correctly: policies exist, they are
-- role-scoped, views carry security_invoker. None of that proves the policies
-- actually *isolate anyone*. A policy can exist, be role-scoped, wrap auth.uid()
-- in a subselect, and still be wrong — `using (true)` satisfies every structural
-- invariant in that file and exposes the entire table.
--
-- So this file does the other half: it becomes two different users and checks
-- what each can actually see and write. These are the assertions that would have
-- to fail before anyone's coherence scores leaked.
--
--   supabase test db

begin;
create extension if not exists pgtap;
select plan(19);

-- Two users. The first is the seeded tester; the second is created here so the
-- test does not depend on seed order.

insert into auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-4000-a000-000000000002',
  'authenticated', 'authenticated', 'mallory@example.com',
  crypt('password123', gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now()
) on conflict (id) do nothing;

-- Give Alice a practice session, so "Mallory sees none" is distinguishable from
-- "there are none".
insert into public.practice_sessions (user_id, exercise_slug, local_date, started_at, completed_at, progress)
values ('00000000-0000-4000-a000-000000000001', 'presence-of-light', current_date, now(), now(), 1);

-- Give Mallory one check-in of her own, so "sees nothing" can be distinguished
-- from "sees only her own".
insert into public.checkins (user_id, kind, local_date, timezone, started_at, completed_at)
values ('00000000-0000-4000-a000-000000000002', 'quick', current_date, 'America/Los_Angeles', now(), now());

-- Becoming a user, the way PostgREST does it: the `authenticated` role plus a
-- JWT claims blob. `set local` so it unwinds with the transaction.
create or replace function test_become(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end $$;

create or replace function test_become_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Back to the session superuser, which bypasses RLS — used to read ground truth
-- after an attack attempt, rather than asking the attacker what happened.
create or replace function test_reset() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ------------------------------------------------------------------ reading ---

select test_become('00000000-0000-4000-a000-000000000002');

select is(
  (select count(*)::int from public.checkins),
  1,
  'Mallory sees exactly her own check-in, not the 60 seeded for the other user'
);

select is(
  (select count(*)::int from public.checkin_scores),
  0,
  'Mallory sees none of the other user''s 600 category scores'
);

select is(
  (select count(*)::int from public.profiles),
  1,
  'Mallory sees exactly one profile — her own'
);

-- The view is the §5.2 footgun: without security_invoker it runs as its owner and
-- bypasses every policy underneath it.
select is(
  (select count(*)::int from public.daily_coherence),
  0,
  'the daily_coherence view does not leak the other user''s rows'
);

-- ------------------------------------------------------------------ writing ---

-- Forging a row under someone else's id is the attack the WITH CHECK clause
-- exists to stop. It must be refused, not silently rewritten.
select throws_ok(
  $$ insert into public.checkins (user_id, kind, local_date, timezone, started_at)
     values ('00000000-0000-4000-a000-000000000001', 'quick', current_date, 'UTC', now()) $$,
  '42501',
  null,
  'Mallory cannot insert a check-in owned by another user'
);

-- An UPDATE or DELETE that matches no *visible* row is not an error — RLS filters
-- it to zero rows and it succeeds quietly. So the assertion cannot be "did it
-- throw"; it has to be "did the victim's data survive". Both statements are run
-- as Mallory, then ground truth is read back with RLS bypassed.
select lives_ok(
  $$ update public.profiles set display_name = 'pwned'
      where id = '00000000-0000-4000-a000-000000000001' $$,
  'a cross-user UPDATE is filtered to zero rows rather than rejected'
);

select lives_ok(
  $$ delete from public.checkins
      where user_id = '00000000-0000-4000-a000-000000000001' $$,
  'a cross-user DELETE is filtered to zero rows rather than rejected'
);

select test_reset();

select is(
  (select display_name from public.profiles where id = '00000000-0000-4000-a000-000000000001'),
  'Cal Tester',
  'the other user''s profile name survived the attempt to overwrite it'
);

select is(
  (select count(*)::int from public.checkins where user_id = '00000000-0000-4000-a000-000000000001'),
  60,
  'all 60 of the other user''s check-ins survived the attempt to delete them'
);

select test_become('00000000-0000-4000-a000-000000000002');

-- --------------------------------------------------- service-role-only tables ---

select is(
  (select count(*)::int from public.subscriptions),
  0,
  'entitlement is not readable across users'
);

select throws_ok(
  $$ insert into public.ai_usage (user_id, usage_date, surface, requests, tokens_in, tokens_out, cost_micros)
     values ('00000000-0000-4000-a000-000000000002', current_date, 'chat', 1, 10, 10, 100) $$,
  '42501',
  null,
  'a client cannot write its own AI usage — a writable budget is not a budget'
);

select throws_ok(
  $$ select count(*) from public.safety_events $$,
  '42501',
  null,
  'safety_events is not readable by a client at all'
);

-- ------------------------------------------------------- the sync contract ---

select is(
  (select count(*)::int from public.practice_sessions),
  0,
  'Mallory sees none of the other user''s practice sessions'
);

-- `updated_at` is the sync watermark. If a client can set it, a device with a
-- skewed clock can write a row that a "changed since X" query never returns
-- again — the row becomes permanently invisible to sync rather than conflicted.
-- The trigger fires on insert as well as update, and this proves it.
-- The insert is its own statement for the same reason as the tombstone below:
-- a data-modifying CTE cannot sit inside a subquery. `timezone = 'Etc/UTC'` is
-- the marker that finds this row again — Mallory's setup row uses a different one.
insert into public.checkins (user_id, kind, local_date, timezone, started_at, updated_at)
values ('00000000-0000-4000-a000-000000000002', 'quick', current_date, 'Etc/UTC', now(),
        '2001-01-01T00:00:00Z');

select ok(
  (select updated_at > now() - interval '1 minute'
     from public.checkins
    where user_id = '00000000-0000-4000-a000-000000000002'
      and timezone = 'Etc/UTC'),
  'a client-supplied updated_at is overwritten by the server on insert'
);

select test_reset();

-- The tombstone has to actually remove the day from the analytics, or a deleted
-- check-in keeps showing up in the charts that read this view.
select test_become('00000000-0000-4000-a000-000000000001');

select is(
  (select count(*)::int from public.daily_coherence),
  60,
  'Alice sees all 60 of her own coherence days before any deletion'
);

-- Two statements, not a data-modifying CTE inside a subquery: Postgres rejects
-- that with "WITH clause containing a data-modifying statement must be at the top
-- level". Same mistake as the cross-user UPDATE above, same fix — do the write,
-- then assert on what it left behind.
select lives_ok(
  $$ update public.checkins set deleted_at = now()
      where user_id = '00000000-0000-4000-a000-000000000001'
        and local_date = current_date $$,
  'a person can tombstone their own check-in'
);

select is(
  (select count(*)::int from public.daily_coherence),
  59,
  'a tombstoned check-in drops out of daily_coherence rather than lingering in the analytics'
);

select test_reset();

-- ---------------------------------------------------------------- anonymous ---

select test_become_anon();

-- Note these are `throws_ok`, not "returns zero rows". An anonymous caller is
-- refused at the GRANT layer — the `anon` role holds no table privilege at all,
-- so PostgreSQL rejects the statement before RLS is ever consulted. That is a
-- stronger posture than an empty result, and worth asserting in the form it
-- actually takes: if a future migration grants `anon` a SELECT and relies on RLS
-- to filter it, these fail and someone has to justify the change.
select throws_ok(
  $$ select count(*) from public.checkins $$,
  '42501',
  null,
  'an anonymous caller is refused check-ins outright, not merely filtered'
);

select throws_ok(
  $$ select count(*) from public.profiles $$,
  '42501',
  null,
  'an anonymous caller is refused profiles outright, not merely filtered'
);

select * from finish();
rollback;
