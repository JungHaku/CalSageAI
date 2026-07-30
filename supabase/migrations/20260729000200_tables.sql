-- Cal Coherence — core schema
-- ARCHITECTURE.md §5.2
--
-- Two conventions applied throughout, both load-bearing:
--
-- 1. `user_id` is denormalised onto every user-owned child table so RLS policies
--    are a single-column comparison with no join. Supabase measures "avoid joins
--    in policies" at a 99.78% improvement.
-- 2. Every FK to a user cascades on delete, so account deletion is one call and
--    the whole graph goes with it (§5.4). There is a pgTAP test for this.

-- ---------------------------------------------------------------- profiles ---

create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  display_name   text,
  major          text,
  grad_year      smallint check (grad_year between 2020 and 2100),
  goals          text,
  interests      text[]      not null default '{}',
  favorite_spots uuid[]      not null default '{}',
  timezone       text        not null default 'America/Los_Angeles',
  onboarded_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- Same pattern already proven in CuffMaxx: security definer with an empty
-- search_path so the function can't be hijacked by a shadowed relation.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- check-ins ---

-- Deliberately NOT unique per (user, day): Dr. Mia's flow has the user re-rate,
-- and an evening check-in is legitimate. Streaks count distinct local_date.
create table public.checkins (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  kind         public.checkin_kind not null,
  local_date   date not null,             -- the user's calendar day (CalKit.LocalDate)
  timezone     text not null,
  started_at   timestamptz not null default now(),
  completed_at timestamptz
);
create index checkins_user_date_idx on public.checkins (user_id, local_date desc);

-- The heart of the product. Before/after live on ONE row because the delta is the
-- claim: "Both scores are saved so the user can see how much their coherence
-- improved in just a few minutes."
create table public.checkin_scores (
  id            uuid primary key default gen_random_uuid(),
  checkin_id    uuid not null references public.checkins (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  category      public.coherence_category not null,
  score_before  smallint not null check (score_before between 0 and 10),
  score_after   smallint          check (score_after  between 0 and 10),
  exercise_slug text,
  delta     smallint generated always as (score_after - score_before) stored,
  regulated boolean  generated always as (score_after is not null) stored,
  answered_at   timestamptz not null default now(),
  unique (checkin_id, category)
);
create index checkin_scores_user_cat_idx on public.checkin_scores (user_id, category, answered_at desc);

-- `security_invoker = on` is MANDATORY. Without it a view runs with the view
-- owner's privileges and silently bypasses RLS on the tables underneath, which
-- would expose every user's coherence scores to any authenticated caller. There
-- is a pgTAP test asserting this across the whole catalog.
create view public.daily_coherence with (security_invoker = on) as
select
  c.user_id,
  c.local_date,
  round(avg(s.score_before)::numeric, 2)                          as avg_before,
  round(avg(coalesce(s.score_after, s.score_before))::numeric, 2)  as avg_after,
  count(*) filter (where s.score_after is not null)                as categories_regulated,
  count(*)                                                        as categories_answered
from public.checkins c
join public.checkin_scores s on s.checkin_id = c.id
where c.completed_at is not null
group by c.user_id, c.local_date;

-- ------------------------------------------------ journal, chat, AI surfaces ---

create table public.journal_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  local_date    date not null,
  body          text not null,
  ai_reflection text,
  themes        text[] not null default '{}',
  reflected_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index journal_user_date_idx on public.journal_entries (user_id, local_date desc);

create table public.chat_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  title           text,
  last_message_at timestamptz,
  created_at      timestamptz not null default now()
);

create table public.chat_messages (
  id             uuid primary key default gen_random_uuid(),
  thread_id      uuid not null references public.chat_threads (id) on delete cascade,
  user_id        uuid not null references auth.users (id) on delete cascade,
  role           text not null check (role in ('user', 'assistant')),
  content        text not null,
  model          text,
  prompt_version text,
  tokens_in      integer,
  -- Recorded so a prompt reordering that silently killed the provider cache shows
  -- up as a metric rather than as a surprise invoice (§10.4).
  cached_tokens  integer,
  tokens_out     integer,
  cost_micros    integer,
  safety_level   smallint not null default 0,
  created_at     timestamptz not null default now()
);
create index chat_messages_thread_idx on public.chat_messages (thread_id, created_at);

-- Read before every model call to enforce the per-user budget. Client may SELECT
-- its own rows (so the UI can show remaining messages) but never write them —
-- otherwise a user resets their own budget. Writes are service_role only.
create table public.ai_usage (
  user_id     uuid not null references auth.users (id) on delete cascade,
  usage_date  date not null,
  surface     text not null,
  requests    integer not null default 0,
  tokens_in   bigint  not null default 0,
  tokens_out  bigint  not null default 0,
  cost_micros bigint  not null default 0,
  primary key (user_id, usage_date, surface)
);

-- Audit trail for the safety pipeline (§9.4). Also the source for the crisis
-- referral counts California SB 243 requires reporting from 2027-07-01 (§9.1),
-- which is why severity and created_at are indexed together.
create table public.safety_events (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  chat_message_id uuid references public.chat_messages (id) on delete set null,
  severity        smallint not null check (severity between 0 and 2),
  matched_rule    text,
  action_taken    text not null,
  created_at      timestamptz not null default now()
);
create index safety_events_severity_idx on public.safety_events (severity, created_at desc);

-- ------------------------------------------------------- plans and reviews ---

create table public.action_plans (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  local_date    date not null,
  items         jsonb not null default '[]',
  completed_ids text[] not null default '{}',
  created_at    timestamptz not null default now(),
  unique (user_id, local_date)
);

create table public.weekly_reviews (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  week_start      date not null,
  strongest       text[] not null default '{}',
  needs_attention text[] not null default '{}',
  summary         text,
  top_exercises   text[] not null default '{}',
  focus           text,
  generated_at    timestamptz not null default now(),
  unique (user_id, week_start)
);

-- ------------------------------------------ account, consent, entitlements ---

create table public.emergency_contacts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  label      text not null,
  phone      text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

-- Versioned because CMIA authorisation is a formal document (§18.2): you must be
-- able to prove which text a given user accepted, and when.
create table public.consents (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  doc_type    text not null,
  doc_version text not null,
  accepted_at timestamptz not null default now(),
  unique (user_id, doc_type, doc_version)
);

create table public.subscriptions (
  user_id                  uuid primary key references auth.users (id) on delete cascade,
  product_id               text not null,
  status                   public.sub_status not null default 'none',
  expires_at               timestamptz,
  original_transaction_id  text unique,
  environment              text not null default 'Production',
  updated_at               timestamptz not null default now()
);

-- Encrypted at rest: a Canvas feed_code or a Google secret iCal address is a
-- bearer-equivalent credential — anyone holding one reads the user's whole
-- calendar with no login (§14).
create table public.calendar_feeds (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  kind               text not null check (kind in ('canvas', 'google', 'ics')),
  feed_url_encrypted bytea not null,
  last_synced_at     timestamptz,
  created_at         timestamptz not null default now()
);

-- ------------------------------------------------------- authored content ---
-- Public-read, service_role-write. Lives in the database so Dr. Mia can edit copy
-- without an App Store release (§8.4, §13).

-- `script` is structured steps, not prose, so one authored script drives the timed
-- UI, haptic breath pacing, VoiceOver, and the audio track (§13).
create table public.exercises (
  slug       text primary key,
  title      text not null,
  category   public.coherence_category,
  tier       public.content_tier not null default 'premium',
  script     jsonb not null default '[]',
  audio_path text,
  duration_s integer,
  version    integer not null default 1,
  updated_at timestamptz not null default now()
);

-- Versioned prompts, so tone can be rolled back in seconds and any stored message
-- can be reproduced exactly (§8.4).
create table public.prompt_versions (
  id            uuid primary key default gen_random_uuid(),
  surface       text not null,
  version       text not null,
  system_prompt text not null,
  model         text not null,
  params        jsonb not null default '{}',
  approved_by   text,
  approved_at   timestamptz,
  active        boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (surface, version)
);
create unique index prompt_versions_one_active_per_surface
  on public.prompt_versions (surface) where active;

create table public.campus_places (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,
  name          text not null,
  aliases       text[] not null default '{}',
  category      text,
  geom          geography(point, 4326),
  hours         jsonb,
  notes         text,
  accessibility text,
  indoor        boolean,
  -- Set only once a human has confirmed the pin and any number on it (§9.3).
  verified_at   timestamptz
);
create index campus_places_geom_idx on public.campus_places using gist (geom);

create table public.campus_resources (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  category    text,
  phone       text,
  url         text,
  hours       jsonb,
  location_id uuid references public.campus_places (id) on delete set null,
  description text,
  verified_at timestamptz
);

create table public.campus_events (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz,
  location_id uuid references public.campus_places (id) on delete set null,
  url         text,
  category    text
);

create table public.discounts (
  id          uuid primary key default gen_random_uuid(),
  merchant    text not null,
  offer       text not null,
  terms       text,
  location_id uuid references public.campus_places (id) on delete set null,
  expires_on  date
);

create table public.motivations (
  id     uuid primary key default gen_random_uuid(),
  body   text not null,
  tags   text[] not null default '{}',
  active boolean not null default true
);

-- The kill switch from §10.4 lives here: flip a boolean to fall back to authored
-- content, instead of shipping a build at 2am.
create table public.feature_flags (
  key         text primary key,
  enabled     boolean not null default false,
  rollout_pct smallint not null default 0 check (rollout_pct between 0 and 100),
  notes       text
);
