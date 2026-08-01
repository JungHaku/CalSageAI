// Personal memory — the `cal_memory` collection (M2).
//
// Separate from `cal_content` in every way that matters. The content corpus is
// authored, shared, and identical for every student; this holds the student's
// own words. So the rules here are different and stricter, and the type is shaped
// so that the important one cannot be forgotten: a `PersonalMemory` can only be
// constructed from a `VerifiedUser`, and every read and write it performs is
// filtered by that verified id. There is no way to call it without an identity
// because there is no way to build it without one.
//
// ⚠️ NOT YET REACHABLE FROM THE APP, and deliberately. Writing here means a
// student's chat text leaves their phone and persists under an account, which is
// the exact moment ARCHITECTURE §14 and LAUNCH-REQUIREMENTS §18 attach: a CMIA
// authorization screen, separate MHMDA opt-ins for collection and sharing, and
// the App Privacy label flipping off "Data Not Collected". None of those exist.
// The code is built and tested; turning it on is a product and legal decision,
// not a code change.

import type { Embedder, RetrievedChunk, VectorStore } from "./retrieval.ts";
import type { VerifiedUser } from "./identity.ts";

/// How many remembered fragments may reach a prompt.
export const MEMORY_TOP_K = 3;

/// Tighter than the content corpus's 0.82.
///
/// A wrong practice suggestion is a bad answer; a wrong memory is Cal telling
/// someone it remembers something they never said, which is worse than saying
/// nothing and is the kind of thing that ends trust in a coach permanently.
export const MEMORY_MAX_DISTANCE = 0.75;

export interface MemoryRecord {
  id: string;
  text: string;
  createdAt: string;
}

/// A Chroma-backed store scoped to one verified person.
export interface MemoryBackend {
  query(
    profileId: string,
    vector: number[],
    k: number,
  ): Promise<RetrievedChunk[]>;
  upsert(
    profileId: string,
    record: MemoryRecord,
    vector: number[],
  ): Promise<void>;
  deleteAll(profileId: string): Promise<void>;
}

/// Memory for exactly one person.
///
/// Construct it with `personalMemoryFor`, which requires a `VerifiedUser`. The
/// profile id is captured here and passed to every backend call; nothing in this
/// class accepts an id from a caller.
export class PersonalMemory {
  private constructor(
    private readonly profileId: string,
    private readonly backend: MemoryBackend,
    private readonly embedder: Embedder,
  ) {}

  static create(user: VerifiedUser, backend: MemoryBackend, embedder: Embedder): PersonalMemory {
    return new PersonalMemory(user.id, backend, embedder);
  }

  /// Fragments of this person's own past conversation relevant to `query`.
  ///
  /// Fails open like content retrieval: memory makes Cal better, it is not what
  /// makes Cal work, and a vector store outage must not cost someone their
  /// coach.
  async recall(query: string, k = MEMORY_TOP_K): Promise<RetrievedChunk[]> {
    if (!query.trim()) return [];
    try {
      const vector = await this.embedder.embed(query);
      const hits = await this.backend.query(this.profileId, vector, k);
      const kept = hits.filter((hit) => hit.distance <= MEMORY_MAX_DISTANCE);
      console.log(
        `memory.recall ${kept.length}/${hits.length} kept for profile ${redact(this.profileId)}`,
      );
      return kept;
    } catch (error) {
      console.error("memory recall failed, continuing without it:", error);
      return [];
    }
  }

  /// Records a turn, unless the safety rules forbid it.
  ///
  /// `severity` is the on-device assessment that already travelled with the
  /// request. Anything the prefilter flagged is never written — see
  /// `shouldRemember`.
  async remember(input: {
    id: string;
    text: string;
    createdAt: string;
    severity?: string;
  }): Promise<boolean> {
    if (!shouldRemember(input.text, input.severity)) return false;
    try {
      const vector = await this.embedder.embed(input.text);
      await this.backend.upsert(
        this.profileId,
        { id: input.id, text: input.text, createdAt: input.createdAt },
        vector,
      );
      return true;
    } catch (error) {
      console.error("memory write failed:", error);
      return false;
    }
  }

  /// Erases everything held for this person.
  ///
  /// Required, not optional. MHMDA deletion has to reach every processor, and
  /// `PersonalDataService` already owns "delete everything" on the device — this
  /// is the half of that promise which lives off it.
  async forgetEverything(): Promise<void> {
    await this.backend.deleteAll(this.profileId);
  }
}

export function personalMemoryFor(
  user: VerifiedUser,
  backend: MemoryBackend,
  embedder: Embedder,
): PersonalMemory {
  return PersonalMemory.create(user, backend, embedder);
}

/// Whether a message may be written to long-term memory.
///
/// The severity rule is the one that matters and it is stricter than the one
/// `ConversationWindow` applies on the device. There, `.elevated` still travels,
/// because the model is answering that message and needs to see it. Here the
/// question is different — should this be recalled and re-surfaced weeks later,
/// unprompted, in an unrelated conversation? For anything the safety pipeline
/// touched, no. A crisis is a moment to respond to, not a fact to file.
export function shouldRemember(text: string, severity?: string): boolean {
  if (!text || !text.trim()) return false;
  if (severity && severity !== "none") return false;
  // Fragments too short to carry meaning cost tokens and recall noise.
  return text.trim().length >= 12;
}

/// Profile ids are pseudonymous but they are still identifiers, and this line is
/// written on every recall. Enough to correlate a session in a log, not enough
/// to be a list of who uses the app.
function redact(profileId: string): string {
  return profileId.length <= 8 ? "********" : `${profileId.slice(0, 8)}…`;
}

/// Chroma-backed implementation.
///
/// Every call takes `profileId` as its first argument and puts it in the `where`
/// clause. There is deliberately no method that queries without one.
export class ChromaMemoryBackend implements MemoryBackend {
  private collectionId: string | null = null;

  constructor(
    private readonly baseUrl: string,
    private readonly collection = "cal_memory",
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
    const response = await fetch(this.collectionsUrl, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        name: this.collection,
        get_or_create: true,
        configuration: { hnsw: { space: "cosine" } },
      }),
    });
    if (!response.ok) throw new Error(`chroma memory collection ${response.status}`);
    this.collectionId = (await response.json()).id;
    return this.collectionId!;
  }

  async query(profileId: string, vector: number[], k: number): Promise<RetrievedChunk[]> {
    const id = await this.resolveCollection();
    const response = await fetch(`${this.collectionsUrl}/${id}/query`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        query_embeddings: [vector],
        n_results: k,
        // The isolation boundary, and the only one there is.
        where: { profileId: { $eq: profileId } },
        include: ["documents", "distances"],
      }),
    });
    if (!response.ok) throw new Error(`chroma memory query ${response.status}`);

    const json = await response.json();
    const ids: string[] = json.ids?.[0] ?? [];
    const documents: string[] = json.documents?.[0] ?? [];
    const distances: number[] = json.distances?.[0] ?? [];
    return ids.map((chunkId, index) => ({
      id: chunkId,
      text: documents[index] ?? "",
      distance: distances[index] ?? 1,
    }));
  }

  async upsert(profileId: string, record: MemoryRecord, vector: number[]): Promise<void> {
    const id = await this.resolveCollection();
    const response = await fetch(`${this.collectionsUrl}/${id}/upsert`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        // Namespaced by profile so two people cannot collide on an id, and so a
        // stray id from one account cannot address another's record.
        ids: [`${profileId}:${record.id}`],
        embeddings: [vector],
        documents: [record.text],
        metadatas: [{ profileId, createdAt: record.createdAt }],
      }),
    });
    if (!response.ok) throw new Error(`chroma memory upsert ${response.status}`);
  }

  async deleteAll(profileId: string): Promise<void> {
    const id = await this.resolveCollection();
    const response = await fetch(`${this.collectionsUrl}/${id}/delete`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ where: { profileId: { $eq: profileId } } }),
    });
    if (!response.ok) throw new Error(`chroma memory delete ${response.status}`);
  }
}
