-- Ambassador program sign-ups. One row per account; the typed email is stored
-- even when it differs from the login address.

create table public.ambassador_signups (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null unique references auth.users (id) on delete cascade,
  email      text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ambassador_email_shape check (
    char_length(email) between 3 and 254
    and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  )
);

create unique index ambassador_signups_email_idx
  on public.ambassador_signups (lower(email));

comment on table public.ambassador_signups is
  'Interest list for the ambassador program. Client-writable for the signed-in owner only.';

select public._cal_apply_owner_policies('public.ambassador_signups', 'user_id');
