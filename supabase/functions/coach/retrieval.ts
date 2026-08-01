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
// memory is a separate collection with different rules and is blocked on real
// authentication; see the M2 notes in the plan.

export interface RetrievedChunk {
  id: string;
  text: string;
  /// Cosine distance. 0 is identical, 1 is unrelated.
  distance: number;
}

/// Swapped for a fake in tests, and the reason a different vector database is a
/// file rather than a rewrite. Chroma is the implementation, not the contract.
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
export const KINDS_FOR_SURFACE: Record<string, string[]> = {
  chat: ["practice", "question"],
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

export class OpenAIEmbedder implements Embedder {
  constructor(
    private readonly apiKey: string,
    private readonly model = "text-embedding-3-small",
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

export class ChromaVectorStore implements VectorStore {
  /// Resolved once and cached: the id is stable for the life of the collection,
  /// and looking it up on every turn would add a round trip to every reply.
  private collectionId: string | null = null;

  constructor(
    private readonly baseUrl: string,
    private readonly collection = "cal_content",
    private readonly tenant = "default_tenant",
    private readonly database = "default_database",
    private readonly token?: string,
  ) {}

  private get collectionsUrl(): string {
    return `${this.baseUrl.replace(/\/$/, "")}/api/v2/tenants/${this.tenant}` +
      `/databases/${this.database}/collections`;
  }

  private headers(): HeadersInit {
    return {
      "Content-Type": "application/json",
      ...(this.token ? { "Authorization": `Bearer ${this.token}` } : {}),
    };
  }

  private async resolveCollection(): Promise<string> {
    if (this.collectionId) return this.collectionId;

    // `get_or_create` rather than a lookup: a function that starts before the
    // seeding script has run should describe an empty collection, not crash.
    const response = await fetch(this.collectionsUrl, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ name: this.collection, get_or_create: true }),
    });
    if (!response.ok) {
      throw new Error(`chroma collection ${response.status}`);
    }
    const json = await response.json();
    this.collectionId = json.id;
    return json.id;
  }

  async query(vector: number[], kinds: string[], k: number): Promise<RetrievedChunk[]> {
    const id = await this.resolveCollection();
    const where = kinds.length === 1
      ? { kind: { $eq: kinds[0] } }
      : { $or: kinds.map((kind) => ({ kind: { $eq: kind } })) };

    const response = await fetch(`${this.collectionsUrl}/${id}/query`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        query_embeddings: [vector],
        n_results: k,
        where,
        include: ["documents", "distances"],
      }),
    });
    if (!response.ok) {
      throw new Error(`chroma query ${response.status}`);
    }

    const json = await response.json();
    // Chroma nests one result array per query embedding; we always send one.
    const ids: string[] = json.ids?.[0] ?? [];
    const documents: string[] = json.documents?.[0] ?? [];
    const distances: number[] = json.distances?.[0] ?? [];

    return ids.map((chunkId, index) => ({
      id: chunkId,
      text: documents[index] ?? "",
      distance: distances[index] ?? 1,
    }));
  }
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
/// **Fails open, always.** Chroma being unreachable, an embeddings call timing
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
    k?: number;
    maxDistance?: number;
  },
): Promise<RetrievedChunk[]> {
  const { surface, query, embedder, store } = input;
  if (!embedder || !store) return [];

  const kinds = KINDS_FOR_SURFACE[surface];
  if (!kinds || !query.trim()) return [];

  try {
    const vector = await embedder.embed(query);
    const hits = await store.query(vector, kinds, input.k ?? TOP_K);
    const kept = hits.filter((hit) => hit.distance <= (input.maxDistance ?? MAX_DISTANCE));

    // Log the outcome, not just the failures.
    //
    // Retrieval degrades to silence by design, which means a total outage and a
    // healthy system that found nothing relevant produce the same reply. Without
    // a line here the difference is invisible, and "retrieval has been off since
    // the deploy" looks exactly like "Cal is a bit vague lately".
    //
    // Ids and distances only. The chunk text is authored content today, but this
    // same path carries the student's own words at M2, and a log is the last
    // place that should be the first to hold them.
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
