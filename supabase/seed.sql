-- Cal Coherence — local development seed
-- ARCHITECTURE.md §11.6
--
-- LOCAL ONLY. This writes directly into auth.users, which is fine against
-- `supabase start` and must never run against staging or production.
--
-- The point of this file: one deterministic user with 60 days of realistic
-- check-ins makes the analytics screens, streaks, trends, and the weekly review
-- real — in previews, in UI tests, and when demoing to Dr. Mia. Without it every
-- chart is empty and you end up hand-tapping data to see anything.
--
-- Deterministic on purpose. The scores come from a hash of (day, category), not
-- random(), so the same chart renders on every reset and snapshot tests of it
-- can't flake.

-- Fixed UUID so tests can reference the user without a lookup.
--
-- Written out in full rather than held in a client variable, and that is not a
-- style choice. Backslash meta-commands and colon-prefixed interpolation are
-- *psql client* constructs: piping this file through psql works, but
-- `supabase start` seeds over a direct SQL connection with no psql involved, so
-- they never expand and the whole batch fails with a bare "failed to send
-- batch". Keep this file free of client-side syntax.
--   test user:  00000000-0000-4000-a000-000000000001
--   test email: cal.tester@example.com

insert into auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-4000-a000-000000000001',
  'authenticated', 'authenticated', 'cal.tester@example.com',
  crypt('password123', gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}',
  now(), now()
)
on conflict (id) do nothing;

-- The on_auth_user_created trigger creates the profile row; fill in the details.
update public.profiles
   set display_name = 'Cal Tester',
       major        = 'Molecular & Cell Biology',
       grad_year    = 2028,
       goals        = 'Sleep more. Panic less.',
       interests    = array['climbing', 'ceramics'],
       onboarded_at = now()
 where id = '00000000-0000-4000-a000-000000000001';

-- 60 consecutive days of completed full check-ins, ending today.
with days as (
  select (current_date - offset_days) as local_date, offset_days
    from generate_series(0, 59) as offset_days
),
inserted as (
  insert into public.checkins (user_id, kind, local_date, timezone, started_at, completed_at)
  select '00000000-0000-4000-a000-000000000001', 'full', d.local_date, 'America/Los_Angeles',
         d.local_date + time '08:00', d.local_date + time '08:04'
    from days d
  returning id, local_date
)
insert into public.checkin_scores (checkin_id, user_id, category, score_before, score_after, exercise_slug)
select
  i.id,
  '00000000-0000-4000-a000-000000000001',
  cat.category,
  before_score.value,
  -- Only regulated when the premium rule fires (score <= 5), and the improvement
  -- is bounded so `avg delta` looks like a plausible clinical effect rather than
  -- a miracle.
  case when before_score.value <= 5
       then least(10, before_score.value + 2 + (hashtext(i.local_date::text || cat.category::text) & 2))
       else null end,
  case when before_score.value <= 5 then 'seed-placeholder' else null end
from inserted i
cross join (
  select unnest(enum_range(null::public.coherence_category)) as category
) cat
cross join lateral (
  -- Gentle upward drift over the 60 days plus a deterministic per-category wobble,
  -- so trend lines have a real shape.
  select greatest(0, least(10,
    3
    + ((current_date - i.local_date) * -1 + 59) / 15          -- drift: ~+4 over 60 days
    + (hashtext(i.local_date::text || cat.category::text) & 3) -- wobble: 0..3
  )) as value
) before_score
where cat.category <> 'overall';   -- 'overall' belongs to the free quick check-in

-- A couple of feature flags so the kill switch (§10.4) exists from day one.
insert into public.feature_flags (key, enabled, rollout_pct, notes) values
  ('ai_coach_enabled',        true,  100, 'Master switch for all LLM surfaces. Off => authored fallbacks.'),
  ('on_device_prefilter',     false,   0, 'Apple Foundation Models for the crisis prefilter (§8.5).')
on conflict (key) do nothing;

-- One authored exercise so the check-in flow has something real to route into.
-- Structured steps, not prose (§13) — this shape drives the timed UI, the haptic
-- breath pacing, VoiceOver, and the audio track from one definition.
insert into public.exercises (slug, title, category, tier, script, duration_s, version) values (
  'seed-placeholder',
  'One Minute Together (placeholder)',
  'overall',
  'free',
  '[
     {"kind":"cue","text":"Let''s take one minute together.","seconds":4},
     {"kind":"inhale","text":"Breathe in through your nose","seconds":4},
     {"kind":"hold","text":"Hold","seconds":2},
     {"kind":"exhale","text":"Out slowly through your mouth","seconds":6},
     {"kind":"repeat","times":4},
     {"kind":"cue","text":"Let your shoulders drop.","seconds":4}
   ]'::jsonb,
  60,
  1
)
on conflict (slug) do nothing;

-- NOTE: placeholder copy, pending Dr. Mia's word-for-word scripts (§20 item 5).
-- Nothing clinical ships generated or invented — this exists only so Phase 1 has a
-- routable exercise, and it is labelled in the title so it can't be mistaken for
-- approved content.
