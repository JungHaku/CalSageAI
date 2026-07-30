-- Cal Coherence — extensions and domain enums
-- ARCHITECTURE.md §5.2
--
-- Enum raw values are the wire format shared with CalKit's Swift enums. Changing
-- one here without changing CoherenceCategory/CheckInKind breaks decoding
-- silently; CalKit has a test pinning these strings.

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists postgis;    -- campus place geography(point)
create extension if not exists vector;     -- retrieval over campus/resource content (§8.2)

create type public.coherence_category as enum (
  'overall',              -- the free tier's single daily question
  'safety',
  'breath',
  'presence',
  'emotional_flow',
  'body_awareness',
  'choice',
  'connection',
  'energy',
  'inner_knowing',
  'authentic_expression'
);

create type public.checkin_kind as enum ('quick', 'full');
create type public.content_tier  as enum ('free', 'premium');
create type public.sub_status    as enum ('none', 'trialing', 'active', 'grace', 'expired', 'revoked');

-- Mirrors CalKit's CrisisSeverity. Stored as smallint on safety_events so the
-- ordering is queryable, but named here for documentation.
comment on type public.coherence_category is
  'Dr. Mia''s ten premium dimensions plus `overall` for the free quick check-in. Mirrors CalKit.CoherenceCategory.';
