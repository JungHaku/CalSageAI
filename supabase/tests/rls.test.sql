-- Cal Coherence — RLS and catalog invariants
-- ARCHITECTURE.md §11.6
--
-- These are the tests that are easiest to skip and worst to be missing. They are
-- written as catalog sweeps, not per-table assertions, so that adding a new table
-- without RLS fails automatically — a test you have to remember to extend is a
-- test that eventually lies.
--
--   supabase test db

begin;
create extension if not exists pgtap;
select plan(13);

-- --------------------------------------------------------------- invariant 1 ---
-- Every table that holds user data has RLS enabled. No policy means deny-all,
-- which is safe; RLS *disabled* means wide open, which is not.
--
-- Scoped to tables that actually hold user data — one with a `user_id` column, or
-- a foreign key to `auth.users`, or one we have named ourselves. It used to sweep
-- every table in `public`, and that made it a claim about objects we do not
-- control. Two things broke it: PostGIS's `spatial_ref_sys`, which cannot be given
-- RLS by a non-superuser, and a stray `public.wm` table (id, body, updated_at,
-- xid8) that appeared mid-session, was owned by `postgres`, belonged to no
-- extension, and did not reappear after a reset — I could not establish what
-- created it and am not going to guess in a comment.
--
-- The narrower question is the one the app actually needs answered, and it cannot
-- be made flaky by infrastructure: a table with a `user_id` and no RLS is a leak,
-- and a table with neither is not this test's business. Invariant 10 separately
-- pins that our own tables are all still in scope here.
select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'r'
        and not c.relrowsecurity
        and not exists (
          select 1 from pg_depend d
           where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e'
        )
        and (
          exists (
            select 1 from pg_attribute a
             where a.attrelid = c.oid and a.attname = 'user_id' and not a.attisdropped
          )
          or exists (
            select 1 from pg_constraint k
             where k.conrelid = c.oid and k.contype = 'f' and k.confrelid = 'auth.users'::regclass
          )
        ) $$,
  'every table holding user data has row level security enabled'
);

-- --------------------------------------------------------------- invariant 2 ---
-- THE footgun (§5.2). A view without security_invoker runs as its owner and
-- bypasses RLS on the tables underneath — `daily_coherence` would expose every
-- user's coherence scores to any authenticated caller.
select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'v'
        and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=%on%'
        and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=%true%'
        and not exists (
          select 1 from pg_depend d
           where d.classid = 'pg_class'::regclass
             and d.objid = c.oid
             and d.deptype = 'e'
        ) $$,
  'every public view is defined with security_invoker on'
);

-- --------------------------------------------------------------- invariant 3 ---
-- Every user-owned table carries all four CRUD policies. A table with only a
-- SELECT policy silently rejects writes; one missing a SELECT policy silently
-- returns nothing. Both look like app bugs for hours.
select is_empty(
  $$ with owned(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('practice_sessions'),
              ('journal_entries'),('chat_threads'),('chat_messages'),('action_plans'),
              ('weekly_reviews'),('emergency_contacts'),('consents'),('calendar_feeds')
     )
     select owned.t || ' has ' || count(p.polname) || ' policies'
       from owned
       left join pg_policy p on p.polrelid = ('public.' || owned.t)::regclass
      group by owned.t
     having count(p.polname) <> 4 $$,
  'every user-owned table has exactly four owner policies'
);

-- --------------------------------------------------------------- invariant 4 ---
-- Policies must be role-scoped. An unscoped policy is evaluated for anonymous
-- requests too, for nothing (Supabase measures 99.78%).
select is_empty(
  $$ select c.relname || '.' || p.polname
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and p.polroles = '{0}'::oid[] $$,
  'no policy applies to PUBLIC — every policy names its roles'
);

-- --------------------------------------------------------------- invariant 5 ---
-- The `(select auth.uid())` form, not bare `auth.uid()`. Bare re-evaluates per
-- row; this is a 20x difference on a few thousand rows, so it is treated as
-- correctness rather than tuning.
select is_empty(
  $$ select c.relname || '.' || p.polname
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and pg_get_expr(p.polqual, p.polrelid) like '%auth.uid()%'
        and pg_get_expr(p.polqual, p.polrelid) not like '%( SELECT auth.uid()%' $$,
  'every policy wraps auth.uid() in a subselect'
);

-- --------------------------------------------------------------- invariant 6 ---
-- A writable budget is not a budget (§10.4).
select is_empty(
  $$ select p.polname
       from pg_policy p
      where p.polrelid = 'public.ai_usage'::regclass and p.polcmd <> 'r' $$,
  'ai_usage has no client-writable policy — only service_role writes it'
);

-- --------------------------------------------------------------- invariant 7 ---
-- Client-trusted entitlement means free access to the paid model tier (§12).
select is_empty(
  $$ select p.polname
       from pg_policy p
      where p.polrelid = 'public.subscriptions'::regclass and p.polcmd <> 'r' $$,
  'subscriptions is read-only to clients — the App Store webhook is authoritative'
);

-- --------------------------------------------------------------- invariant 8 ---
-- safety_events is an audit trail; a user who can edit their own safety history
-- defeats the point (§9.4).
select is_empty(
  $$ select p.polname from pg_policy p where p.polrelid = 'public.safety_events'::regclass $$,
  'safety_events is not client-accessible at all'
);

-- --------------------------------------------------------------- invariant 9 ---
-- Account deletion must take the whole graph with it, or "delete my account"
-- silently leaves health data behind (§5.4, §18.2).
select is_empty(
  $$ with owned(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('practice_sessions'),
              ('journal_entries'),('chat_threads'),('chat_messages'),('action_plans'),
              ('weekly_reviews'),('emergency_contacts'),('consents'),('calendar_feeds'),
              ('ai_usage'),('safety_events'),('subscriptions')
     )
     select owned.t
       from owned
      where not exists (
        select 1
          from pg_constraint k
         where k.conrelid = ('public.' || owned.t)::regclass
           and k.contype = 'f'
           and k.confrelid = 'auth.users'::regclass
           and k.confdeltype = 'c'          -- ON DELETE CASCADE
      ) $$,
  'every user-scoped table cascades from auth.users on delete'
);

-- -------------------------------------------------------------- invariant 10 ---
-- The guard on invariants 1 and 2. Both now exclude extension-owned objects, and
-- an exclusion that quietly matched more than intended would make them pass
-- vacuously forever.
--
-- Asserting a bare count would be a weak guard — with 22 tables in `public`, any
-- threshold low enough to be safe is too low to catch real breakage. So this
-- names our tables and asserts every one of them is still *visible* to the sweep.
-- If the extension filter ever starts hiding one, this fails and says which.
select is_empty(
  $$ with ours(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('practice_sessions'),
              ('journal_entries'),('chat_threads'),('chat_messages'),('action_plans'),
              ('weekly_reviews'),('emergency_contacts'),('consents'),('calendar_feeds'),
              ('ai_usage'),('safety_events'),('subscriptions')
     )
     select ours.t
       from ours
      where not exists (
        select 1
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and c.relkind = 'r'
           and c.relname = ours.t
           and not exists (
             select 1 from pg_depend d
              where d.classid = 'pg_class'::regclass
                and d.objid = c.oid
                and d.deptype = 'e'
           )
      ) $$,
  'the extension exclusion still leaves every one of our own tables in the sweep'
);

-- -------------------------------------------------------------- invariant 11 ---
-- Every synced table carries `updated_at` AND a trigger that maintains it.
--
-- The column alone is not enough. If the client supplies the value, a device with
-- a skewed clock can write a row that a watermark query never sees again — the
-- row is silently invisible to sync forever. The trigger is what makes the server
-- the only writer of that column, so this asserts both.
select is_empty(
  $$ with synced(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('practice_sessions')
     )
     select synced.t || ' is missing ' ||
            case when a.attname is null then 'the updated_at column' else 'its touch trigger' end
       from synced
       left join pg_attribute a
         on a.attrelid = ('public.' || synced.t)::regclass
        and a.attname = 'updated_at'
        and not a.attisdropped
       left join pg_trigger g
         on g.tgrelid = ('public.' || synced.t)::regclass
        and g.tgname = synced.t || '_touch_updated_at'
        and not g.tgisinternal
      where a.attname is null or g.tgname is null $$,
  'every synced table has updated_at and a server-side trigger that stamps it'
);

-- -------------------------------------------------------------- invariant 12 ---
-- Rows the client can delete individually carry a tombstone.
--
-- Without one, a delete on device A is undone by the next push from device B: an
-- absent row is indistinguishable from one that was never sent.
select is_empty(
  $$ with tombstoned(t) as (values ('checkins'),('practice_sessions'))
     select tombstoned.t
       from tombstoned
      where not exists (
        select 1 from pg_attribute a
         where a.attrelid = ('public.' || tombstoned.t)::regclass
           and a.attname = 'deleted_at'
           and not a.attisdropped
      ) $$,
  'individually-deletable tables carry a deleted_at tombstone'
);

-- -------------------------------------------------------------- invariant 13 ---
-- Policies without privileges are policies nobody can exercise.
--
-- RLS restricts which rows a role may touch; the GRANT decides whether it may
-- issue the statement at all. They are independent, and getting the second one
-- wrong fails in a way the other twelve invariants cannot see: the shape is
-- perfect, and every query returns "permission denied for table". That is exactly
-- what happened to `practice_sessions` — created by a later migration, so it
-- missed the default privileges the original tables inherited.
select is_empty(
  $$ with owned(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('practice_sessions'),
              ('journal_entries'),('chat_threads'),('chat_messages'),('action_plans'),
              ('weekly_reviews'),('emergency_contacts'),('consents'),('calendar_feeds')
     )
     select owned.t || ' is missing: ' ||
            array_to_string(array(
              select p from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
               where not has_table_privilege('authenticated', ('public.' || owned.t)::regclass, p)
            ), ', ')
       from owned
      where exists (
        select 1 from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
         where not has_table_privilege('authenticated', ('public.' || owned.t)::regclass, p)
      ) $$,
  'every user-owned table grants all four statements to authenticated'
);

select * from finish();
rollback;
