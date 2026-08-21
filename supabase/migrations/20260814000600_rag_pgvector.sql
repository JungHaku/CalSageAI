-- RAG: OpenAI embeddings in pgvector.
--
-- Two stores, never mixed. `content_chunks` is Dr. Mia's authored corpus
-- (practices, coherence questions, campus places) — identical for every
-- student. `memories.embedding` is per-user standing facts. A shared collection
-- would make a metadata filter look like access control.
--
-- Clients do not query either path. The coach embeds with the server-side
-- OpenAI key and calls these RPCs as service_role. Granting match_memories to
-- authenticated would let a caller pass someone else's uuid.

-- ---------------------------------------------------------- shared corpus ---

create table public.content_chunks (
  id         text primary key,
  kind       text not null check (kind in ('practice', 'question', 'place')),
  text       text not null,
  text_hash  text not null,
  embedding  vector(1536) not null,
  updated_at timestamptz not null default now()
);

create index content_chunks_embedding_hnsw_idx
  on public.content_chunks
  using hnsw (embedding vector_cosine_ops);

create index content_chunks_kind_idx on public.content_chunks (kind);

alter table public.content_chunks enable row level security;
alter table public.content_chunks force row level security;

revoke all on table public.content_chunks from public, anon, authenticated;
grant select, insert, update, delete on table public.content_chunks to service_role;

create function public.match_content_chunks(
  query_embedding vector(1536),
  match_kinds text[],
  match_count int default 3
)
returns table (
  id text,
  body text,
  distance double precision
)
language sql
stable
set search_path = public, extensions
as $$
  select
    c.id,
    c.text,
    (c.embedding <=> query_embedding) as distance
  from public.content_chunks c
  where c.kind = any(match_kinds)
  order by c.embedding <=> query_embedding
  limit match_count;
$$;

revoke all on function public.match_content_chunks(vector, text[], int)
  from public, anon, authenticated;
grant execute on function public.match_content_chunks(vector, text[], int)
  to service_role;

-- ---------------------------------------------------------- personal facts ---

alter table public.memories
  add column embedding vector(1536);

create index memories_embedding_hnsw_idx
  on public.memories
  using hnsw (embedding vector_cosine_ops)
  where embedding is not null;

create function public.match_memories(
  query_embedding vector(1536),
  match_user_id uuid,
  match_count int default 5
)
returns table (
  id text,
  body text,
  distance double precision,
  created_at timestamptz
)
language sql
stable
set search_path = public, extensions
as $$
  select
    m.id::text,
    m.text,
    (m.embedding <=> query_embedding) as distance,
    m.created_at
  from public.memories m
  where m.user_id = match_user_id
    and m.embedding is not null
  order by m.embedding <=> query_embedding
  limit match_count;
$$;

revoke all on function public.match_memories(vector, uuid, int)
  from public, anon, authenticated;
grant execute on function public.match_memories(vector, uuid, int)
  to service_role;
