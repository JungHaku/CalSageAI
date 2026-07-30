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
select plan(9);

-- --------------------------------------------------------------- invariant 1 ---
-- Every table in `public` has RLS enabled. No policy means deny-all, which is
-- safe; RLS *disabled* means wide open, which is not.
select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  'every public table has row level security enabled'
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
        and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=%true%' $$,
  'every public view is defined with security_invoker on'
);

-- --------------------------------------------------------------- invariant 3 ---
-- Every user-owned table carries all four CRUD policies. A table with only a
-- SELECT policy silently rejects writes; one missing a SELECT policy silently
-- returns nothing. Both look like app bugs for hours.
select is_empty(
  $$ with owned(t) as (
       values ('profiles'),('checkins'),('checkin_scores'),('journal_entries'),
              ('chat_threads'),('chat_messages'),('action_plans'),('weekly_reviews'),
              ('emergency_contacts'),('consents'),('calendar_feeds')
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
       values ('profiles'),('checkins'),('checkin_scores'),('journal_entries'),
              ('chat_threads'),('chat_messages'),('action_plans'),('weekly_reviews'),
              ('emergency_contacts'),('consents'),('calendar_feeds'),
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

select * from finish();
rollback;
