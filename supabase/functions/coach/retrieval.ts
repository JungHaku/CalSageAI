// Retrieval over the shared content corpus (ARCHITECTURE.md §8.2).
//
// What this is for, precisely: the system prompt tells Cal "you know these
// practices and can guide them from memory", which is the exact instruction a
// model satisfies by inventing plausible-sounding clinical copy. Decision-log
// #10 says authored content is never generated. Retrieval is how that stops
// being a hope — Dr. Mia's actual script goes in the context, and Cal reads it.
//
// The corpus holds no personal data. It is her practices, the ten coherence
// questions, and 231 campus buildings — identical for every student. Per-user
// memory is a separate table (`memories`) with different rules.

export interface RetrievedChunk {
  id: string;
  text: string;
  /// Cosine distance. 0 is identical, 1 is unrelated.
  distance: number;
}

/// Swapped for a fake in tests, and the reason a different vector database is a
/// file rather than a rewrite. Postgres/pgvector is the implementation, not the
/// contract.
export interface VectorStore {
  query(vector: number[], kinds: string[], k: number): Promise<RetrievedChunk[]>;
}

export interface Embedder {
  embed(text: string): Promise<number[]>;
}

/// Which chunk kinds each surface may see.
///
/// Mirrored by `KINDS` in tools/eval-retrieval.py — if these drift, the eval is
/// measuring something the function does not do.
/// Chat includes `place` because students ask campus questions in the chat tab —
/// `SPEC-free.md` §11 lists "I have three hours between classes" among its own
/// examples, and the tab is called Chat with Cal, not Chat About Feelings.
/// Without it Cal answered "where is Wheeler Hall?" from training data while 231
/// verified buildings sat unread in the corpus.
export const KINDS_FOR_SURFACE: Record<string, string[]> = {
  chat: ["practice", "question", "place"],
  navigate: ["place"],
  journal_reflection: ["practice", "question"],
  weekly_review: ["practice", "question"],
  action_plan: ["practice", "question"],
};

/// How many chunks may reach the prompt.
export const TOP_K = 3;

/// Anything further away than this is dropped, however few results remain.
///
/// Measured, not guessed, and the measurement moved it once already. Across
/// tools/eval-retrieval.py against the real corpus: naming a practice lands at
/// 0.31–0.47, a good symptom-to-area match at 0.58–0.71, and the weakest
/// genuine hit observed is 0.797 ("I hide what I really think around my
/// friends" → the authentic-expression question). Meanwhile a question the
/// corpus simply cannot answer — "what should I have for lunch" — returns its
/// three nearest at 0.839–0.849.
///
/// So the honest boundary sits in the gap between 0.797 and 0.839. An earlier
/// 0.85 let the lunch case through: three irrelevant chunks, paying tokens to
/// point the model at the placeholder practice.
///
/// This is fitted to about twenty cases and should be revisited against real
/// student messages. It is a floor on obvious noise, not a precision instrument.
export const MAX_DISTANCE = 0.82;

export const DEFAULT_EMBED_MODEL = "text-embedding-3-small";

export class OpenAIEmbedder implements Embedder {
  constructor(
    private readonly apiKey: string,
    private readonly model = DEFAULT_EMBED_MODEL,
  ) {}

  async embed(text: string): Promise<number[]> {
    const response = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ model: this.model, input: text }),
    });
    if (!response.ok) {
      throw new Error(`embeddings ${response.status}: ${(await response.text()).slice(0, 200)}`);
    }
    const json = await response.json();
    return json.data[0].embedding;
  }
}

export interface PostgresStoreOptions {
  restUrl: string;
  serviceRoleKey: string;
  fetchImpl?: typeof fetch;
}

/// PostgREST-backed pgvector store. The RPC is service_role only; this client
/// always uses the function's key, never a user JWT.
export class PostgresVectorStore implements VectorStore {
  constructor(private readonly options: PostgresStoreOptions) {}

  private get fetchImpl(): typeof fetch {
    return this.options.fetchImpl ?? fetch;
  }

  async query(vector: number[], kinds: string[], k: number): Promise<RetrievedChunk[]> {
    const response = await this.fetchImpl(
      `${this.options.restUrl}/rpc/match_content_chunks`,
      {
        method: "POST",
        headers: {
          apikey: this.options.serviceRoleKey,
          Authorization: `Bearer ${this.options.serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          query_embedding: vector,
          match_kinds: kinds,
          match_count: k,
        }),
      },
    );
    if (!response.ok) {
      throw new Error(`match_content_chunks ${response.status}`);
    }
    const rows: { id: string; body: string; distance: number }[] = await response.json();
    return rows.map((row) => ({
      id: row.id,
      text: row.body ?? "",
      distance: row.distance ?? 1,
    }));
  }
}

export function postgresVectorStoreFromEnv(
  env: { get(key: string): string | undefined } = Deno.env,
  fetchImpl?: typeof fetch,
): PostgresVectorStore | null {
  const supabaseUrl = env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    console.error(
      "retrieval: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is unset — content RAG is off",
    );
    return null;
  }
  return new PostgresVectorStore({
    restUrl: `${supabaseUrl.replace(/\/$/, "")}/rest/v1`,
    serviceRoleKey,
    fetchImpl,
  });
}

/// Deterministic store for tests. Returns what it was given, nearest first.
export class FakeVectorStore implements VectorStore {
  constructor(private readonly chunks: (RetrievedChunk & { kind: string })[] = []) {}

  query(_vector: number[], kinds: string[], k: number): Promise<RetrievedChunk[]> {
    return Promise.resolve(
      this.chunks
        .filter((chunk) => kinds.includes(chunk.kind))
        .sort((a, b) => a.distance - b.distance)
        .slice(0, k)
        .map(({ id, text, distance }) => ({ id, text, distance })),
    );
  }
}

/// Retrieve for one turn, or return nothing.
///
/// **Fails open, always.** Postgres being unreachable, an embeddings call timing
/// out, or an unknown surface all produce an empty array rather than an error.
/// Retrieval makes a reply better grounded; it is not what makes a reply
/// possible, and a student at 1am should not lose their coach because a vector
/// database is down. The failure is logged, because failing open silently is how
/// you discover six weeks later that retrieval has been off the whole time.
export async function retrieve(
  input: {
    surface: string;
    query: string;
    embedder: Embedder | null;
    store: VectorStore | null;
    /// Precomputed query embedding. When set, the embedder is not called — chat
    /// reuses one OpenAI request for content RAG and personal k-NN.
    vector?: number[] | null;
    k?: number;
    maxDistance?: number;
  },
): Promise<RetrievedChunk[]> {
  const { surface, query, embedder, store } = input;
  if (!store) return [];

  const kinds = KINDS_FOR_SURFACE[surface];
  if (!kinds || !query.trim()) return [];

  try {
    const vector = input.vector?.length
      ? input.vector
      : embedder
      ? await embedder.embed(query)
      : null;
    if (!vector) return [];

    const hits = await store.query(vector, kinds, input.k ?? TOP_K);
    const kept = hits.filter((hit) => hit.distance <= (input.maxDistance ?? MAX_DISTANCE));

    // Log the outcome, not just the failures.
    //
    // Retrieval degrades to silence by design, which means a total outage and a
    // healthy system that found nothing relevant produce the same reply. Without
    // a line here the difference is invisible, and "retrieval has been off since
    // the deploy" looks exactly like "Cal is a bit vague lately".
    //
    // Ids and distances only. Chunk text is authored content; personal words
    // never travel this path.
    console.log(
      `retrieval[${surface}] ${kept.length}/${hits.length} kept: ` +
        (kept.map((h) => `${h.id}@${h.distance.toFixed(3)}`).join(" ") || "none"),
    );
    return kept;
  } catch (error) {
    console.error("retrieval failed, continuing without it:", error);
    return [];
  }
}
