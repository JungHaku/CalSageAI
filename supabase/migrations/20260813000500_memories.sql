-- Personal memory — standing facts, not embeddings (PLAN-personal-memory.md).
--
-- Client may SELECT its own rows (Settings: what Cal remembers). Inserts,
-- updates and deletes are service_role only, matching `ai_usage`: a client that
-- can insert poisons its prompt; a client that can delete wipes the store
-- without going through the coach. Account deletion still cascades.

create table public.memories (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  text       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index memories_user_created_idx
  on public.memories (user_id, created_at desc);

alter table public.memories enable row level security;
alter table public.memories force row level security;

create policy "select own" on public.memories
  for select to authenticated using ((select auth.uid()) = user_id);

grant select on public.memories to authenticated;

-- The client cannot DELETE from the table, but "forget me" / revoke / account
-- wipe on the phone still has to reach these rows. This runs as definer so it
-- bypasses RLS, and is constrained to auth.uid() so it cannot take anyone else's.
create function public.forget_memories()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.memories where user_id = (select auth.uid());
end;
$$;

revoke all on function public.forget_memories() from public, anon;
grant execute on function public.forget_memories() to authenticated;
