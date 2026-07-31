-- Cal Coherence — the columns sync actually needs, and the table that was missing
-- ARCHITECTURE.md §15 steps 4–5
--
-- Written while building the sync engine, because the schema as it stood could
-- not express the sync design §15 describes. Three gaps, all of the kind that
-- only surface when something tries to use them:
--
-- 1. **No `practice_sessions` table.** The client has logged every guided-practice
--    run since MVP-2 — including abandoned ones, which §17 question 5 depends on —
--    and `CalKit.PracticeSession`'s own doc comment says it "mirrors a future
--    practice_sessions table". It was planned and never written, so that data had
--    nowhere to go.
--
-- 2. **No `deleted_at` anywhere.** Deletes could not propagate. A check-in deleted
--    on one device would be resurrected by the next push from another, because a
--    row that is simply absent is indistinguishable from one that was never sent.
--
-- 3. **`updated_at` on four tables out of twenty-two.** An incremental pull needs a
--    watermark. Without one, every sync is a full table download.

-- ---------------------------------------------------------------- practice_sessions ---

create table if not exists public.practice_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  exercise_slug text not null,
  local_date    date not null,
  started_at    timestamptz not null,
  -- Null means abandoned, and that is data rather than an absence: a practice
  -- people consistently quit forty seconds in is mistimed, not unpopular.
  completed_at  timestamptz,
  progress      real not null default 0 check (progress >= 0 and progress <= 1),
  -- Set when the run was the regulation step of a check-in, null when it was
  -- started from the library. This is what makes "most effective regulation
  -- exercises" computable at all (SPEC-premium.md, Weekly Coherence Review).
  --
  -- `on delete set null`, not cascade: deleting a check-in should not delete the
  -- practice the person actually did. It only breaks the link.
  checkin_id    uuid references public.checkins(id) on delete set null
);

comment on column public.practice_sessions.progress is
  'How far through the timeline the student got, 0..1. Meaningful precisely when completed_at is null.';

-- ------------------------------------------------------------------- sync columns ---

-- One trigger function for every synced table, so `updated_at` cannot be
-- forgotten by a client and cannot be spoofed by one either — the server stamps
-- it on every write regardless of what the payload claims.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  t text;
  -- The tables the client actually syncs today. Deliberately not "every table":
  -- server-owned tables (ai_usage, safety_events, subscriptions) are written by
  -- the service role and have no client outbox to reconcile.
  synced text[] := array['profiles', 'checkins', 'checkin_scores', 'practice_sessions'];
  -- Rows the client can delete individually, and which therefore need a tombstone.
  -- `checkin_scores` is absent on purpose: scores are children of a check-in and
  -- go with it via cascade, so a tombstone on the parent is the whole story.
  -- `profiles` is absent because a profile disappears only with the account, and
  -- that is a cascade from auth.users rather than a sync event.
  tombstoned text[] := array['checkins', 'practice_sessions'];
begin
  foreach t in array synced loop
    execute format('alter table public.%I add column if not exists updated_at timestamptz not null default now()', t);

    execute format('drop trigger if exists %I on public.%I', t || '_touch_updated_at', t);
    -- `insert or update`, not update alone. On insert the column default would
    -- otherwise apply only when the client omits the value — and a client that
    -- sends one, from a device with a skewed clock or otherwise, would write a
    -- row a watermark query may never return again. The server stamps both paths.
    execute format(
      'create trigger %I before insert or update on public.%I for each row execute function public.touch_updated_at()',
      t || '_touch_updated_at', t
    );

    -- The watermark query is "everything of mine changed since X", so the index
    -- has to lead with the owner and then the timestamp.
    execute format(
      'create index if not exists %I on public.%I (%I, updated_at)',
      t || '_sync_idx', t, case when t = 'profiles' then 'id' else 'user_id' end
    );
  end loop;

  foreach t in array tombstoned loop
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    -- Partial index: tombstones are the rare case and this keeps the index tiny.
    execute format(
      'create index if not exists %I on public.%I (deleted_at) where deleted_at is not null',
      t || '_tombstone_idx', t
    );
  end loop;
end;
$$;

-- --------------------------------------------------------------------------- RLS ---

-- The generator from 20260729000300, extended — because it turned out to be
-- incomplete in a way that only shows up for tables added after it ran.
--
-- It enables RLS and creates the four policies, but never GRANTs anything. The
-- original tables were reachable anyway: they inherited `authenticated=arwd` from
-- Supabase's default privileges at the time the first migration ran. A table
-- created by a *later* migration does not, so it ends up with a perfect set of
-- policies and no privilege to exercise them — every query fails with "permission
-- denied for table", and the catalog invariants all still pass because the shape
-- is right. `practice_sessions` hit exactly this, and so would every table anyone
-- adds from here on.
--
-- Replacing the function rather than granting once for this table, so the fix
-- applies to the next table too. RLS remains the thing that restricts rows; the
-- grant only says the role may attempt the statement at all.
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

  execute format('grant select, insert, update, delete on %s to authenticated', qualified);

  execute format('create policy "select own" on %s for select to authenticated using (%s)', qualified, predicate);
  execute format('create policy "insert own" on %s for insert to authenticated with check (%s)', qualified, predicate);
  execute format('create policy "update own" on %s for update to authenticated using (%s) with check (%s)', qualified, predicate, predicate);
  execute format('create policy "delete own" on %s for delete to authenticated using (%s)', qualified, predicate);
end;
$$;

select public._cal_apply_owner_policies('public.practice_sessions', 'user_id');

-- ------------------------------------------------------------------ the view ---

-- `daily_coherence` aggregates scores per day. Tombstoned check-ins must drop out
-- of it, or a deleted day keeps showing up in the analytics that read this.
--
-- Recreated rather than altered because a view's column list cannot be changed in
-- place, and `security_invoker` has to survive the recreation — without it the
-- view runs as its owner and bypasses every policy underneath (§5.2, and the
-- invariant that guards it).
drop view if exists public.daily_coherence;

create view public.daily_coherence
with (security_invoker = on)
as
select
  c.user_id,
  c.local_date,
  count(*)                                          as scored_categories,
  avg(coalesce(s.score_after, s.score_before))::numeric(4,2) as mean_effective,
  avg(s.score_before)::numeric(4,2)                 as mean_before,
  avg(s.delta) filter (where s.delta is not null)::numeric(4,2) as mean_delta,
  count(*) filter (where s.regulated)               as regulated_count
from public.checkins c
join public.checkin_scores s on s.checkin_id = c.id
where c.completed_at is not null
  and c.deleted_at is null
group by c.user_id, c.local_date;

comment on view public.daily_coherence is
  'Per-day coherence aggregate. security_invoker = on, so it is filtered by the caller''s RLS rather than the view owner''s.';

-- Granted explicitly, because dropping the view dropped its privileges and the
-- replacement came back with `Dxtm` — truncate, references, trigger, maintain —
-- and no SELECT. The original had inherited SELECT from Supabase's default
-- privileges; the recreation did not, and every read through the view started
-- failing with "permission denied". The isolation suite caught it immediately,
-- which is the entire argument for testing behaviour rather than shape.
--
-- Only `authenticated`. `anon` has no privilege on the underlying tables and is
-- refused there anyway, so granting it here would be privilege for nobody. Safe
-- to grant at all only because the view is `security_invoker` — the caller's own
-- RLS still filters every row it returns.
grant select on public.daily_coherence to authenticated;
