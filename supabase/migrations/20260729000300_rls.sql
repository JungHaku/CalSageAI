-- Cal Coherence — Row Level Security
-- ARCHITECTURE.md §5.3
--
-- Policies are generated from a table list rather than copy-pasted 25 times. Two
-- reasons: every table gets the identical, correct policy shape, and adding a
-- table to the wrong list is a visible one-line diff instead of a subtly missing
-- policy. The pgTAP suite independently verifies that every user table is
-- actually covered, so this generation can't quietly skip one.
--
-- Every policy uses `(select auth.uid())`, not bare `auth.uid()`. The subselect
-- lets Postgres evaluate it once as an InitPlan instead of once per row —
-- Supabase measures 179ms → 9ms (94.97%). Every policy also names `to
-- authenticated`, worth a further 99.78%, because otherwise the policy is
-- evaluated for anonymous requests too.

-- Tables owned by a user, keyed by `user_id`.
create or replace function public._cal_apply_owner_policies(target regclass, owner_column text)
returns void
language plpgsql
as $$
declare
  qualified text := target::text;
  predicate text := format('(select auth.uid()) = %I', owner_column);
begin
  execute format('alter table %s enable row level security', qualified);
  -- Belt and braces: RLS is bypassed for a table's owner unless forced, which
  -- matters if a migration ever runs as the table owner via PostgREST.
  execute format('alter table %s force row level security', qualified);

  execute format('create policy "select own" on %s for select to authenticated using (%s)', qualified, predicate);
  execute format('create policy "insert own" on %s for insert to authenticated with check (%s)', qualified, predicate);
  execute format('create policy "update own" on %s for update to authenticated using (%s) with check (%s)', qualified, predicate, predicate);
  execute format('create policy "delete own" on %s for delete to authenticated using (%s)', qualified, predicate);
end;
$$;

-- Read-only reference content: readable by everyone, writable only by
-- service_role (which bypasses RLS entirely, so it needs no policy).
create or replace function public._cal_apply_public_read_policies(target regclass)
returns void
language plpgsql
as $$
begin
  execute format('alter table %s enable row level security', target::text);
  execute format('create policy "public read" on %s for select to anon, authenticated using (true)', target::text);
end;
$$;

do $$
declare
  t text;
begin
  -- `profiles` is keyed by `id`, everything else by `user_id`.
  perform public._cal_apply_owner_policies('public.profiles', 'id');

  foreach t in array array[
    'checkins',
    'checkin_scores',
    'journal_entries',
    'chat_threads',
    'chat_messages',
    'action_plans',
    'weekly_reviews',
    'emergency_contacts',
    'consents',
    'calendar_feeds'
  ] loop
    perform public._cal_apply_owner_policies(format('public.%I', t)::regclass, 'user_id');
  end loop;

  foreach t in array array[
    'exercises',
    'prompt_versions',
    'campus_places',
    'campus_resources',
    'campus_events',
    'discounts',
    'motivations',
    'feature_flags'
  ] loop
    perform public._cal_apply_public_read_policies(format('public.%I', t)::regclass);
  end loop;
end;
$$;

-- ------------------------------------------------------------ special cases ---

-- ai_usage: the client may READ its own usage so the UI can show remaining
-- messages, but must never write it — a writable budget is not a budget.
-- Service_role does the writing and bypasses RLS.
alter table public.ai_usage enable row level security;
alter table public.ai_usage force row level security;
create policy "select own" on public.ai_usage
  for select to authenticated using ((select auth.uid()) = user_id);

-- safety_events: append-only from the client's perspective, and NOT readable by
-- it. This is an audit trail; a user editing or deleting their own safety history
-- would defeat the purpose, and surfacing it in-app is a clinical decision for
-- Dr. Mia, not a default.
alter table public.safety_events enable row level security;
alter table public.safety_events force row level security;

-- subscriptions: read-only to the owner. Entitlement is decided by the App Store
-- Server Notifications webhook (§12); a client that can write this grants itself
-- premium.
alter table public.subscriptions enable row level security;
alter table public.subscriptions force row level security;
create policy "select own" on public.subscriptions
  for select to authenticated using ((select auth.uid()) = user_id);

-- ------------------------------------------------------------------- grants ---

-- Revoke the permissive defaults, then grant deliberately. RLS filters rows; it
-- does not grant table access, so both are needed.
revoke all on all tables in schema public from anon, authenticated;

grant select on
  public.exercises, public.prompt_versions, public.campus_places,
  public.campus_resources, public.campus_events, public.discounts,
  public.motivations, public.feature_flags
  to anon, authenticated;

grant select, insert, update, delete on
  public.profiles, public.checkins, public.checkin_scores,
  public.journal_entries, public.chat_threads, public.chat_messages,
  public.action_plans, public.weekly_reviews, public.emergency_contacts,
  public.consents, public.calendar_feeds
  to authenticated;

grant select on public.ai_usage, public.subscriptions, public.daily_coherence to authenticated;

-- The helper functions are migration-time tooling, not API surface.
revoke all on function public._cal_apply_owner_policies(regclass, text) from anon, authenticated;
revoke all on function public._cal_apply_public_read_policies(regclass) from anon, authenticated;
