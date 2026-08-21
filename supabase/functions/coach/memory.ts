// Personal memory — standing facts in Postgres (PLAN-personal-memory.md).
//
// A `PersonalMemory` can only be constructed from a `VerifiedUser`. Every read
// and write is filtered by that verified id. There is no way to call it without
// an identity because there is no way to build it without one.
//
// Consent is a second check, on the server: the coach function must see a
// current `consents` row before constructing this. A bearer token alone is not
// permission to remember.
//
// Chat recall is k-NN when a query embedding is available, recency otherwise.
// Voice still prefetches last-N at session start — never a mid-turn embed tool.
//
// ⚠️ Writes for real students stay dark until counsel replaces MemoryConsentCopy
// (LAUNCH-REQUIREMENTS §18). The plumbing is what this file is.

import type { Embedder, RetrievedChunk } from "./retrieval.ts";
import type { VerifiedUser } from "./identity.ts";
import { distill, isDurable } from "./distillation.ts";

/// How many standing facts may reach a voice digest. Recency, not k-NN.
export const MEMORY_DIGEST_N = 10;

/// Chat k-NN cap. Tighter than the recency window: similarity is the point.
export const MEMORY_SIMILAR_K = 5;

/// Must match `MemoryConsent.currentVersion` in CalKit.
export const MEMORY_CONSENT_VERSION = "memory-v1";

export const MEMORY_CONSENT_DOC_TYPE = "memory";

export interface MemoryRecord {
  id: string;
  text: string;
  createdAt: string;
  embedding?: number[];
}

export interface RecalledMemory extends RetrievedChunk {
  createdAt?: string;
}

export interface MemoryBackend {
  query(profileId: string, k: number): Promise<RecalledMemory[]>;
  querySimilar(profileId: string, vector: number[], k: number): Promise<RecalledMemory[]>;
  upsert(profileId: string, record: MemoryRecord): Promise<void>;
  setEmbedding(profileId: string, id: string, vector: number[]): Promise<void>;
  deleteAll(profileId: string): Promise<void>;
}

export class PersonalMemory {
  private constructor(
    private readonly profileId: string,
    private readonly backend: MemoryBackend,
    private readonly embedder: Embedder | null,
  ) {}

  static create(
    user: VerifiedUser,
    backend: MemoryBackend,
    embedder: Embedder | null = null,
  ): PersonalMemory {
    return new PersonalMemory(user.id, backend, embedder);
  }

  /// Standing facts for this person. With a query vector, nearest neighbours;
  /// otherwise last N. Empty or failed k-NN falls back to recency so a row
  /// without an embedding is still visible.
  async recall(
    _query: string,
    options?: { k?: number; vector?: number[] | null },
  ): Promise<RetrievedChunk[]> {
    try {
      const vector = options?.vector;
      if (vector?.length) {
        try {
          const hits = await this.backend.querySimilar(
            this.profileId,
            vector,
            options?.k ?? MEMORY_SIMILAR_K,
          );
          if (hits.length) {
            console.log(
              `memory.recall knn ${hits.length} kept for profile ${redact(this.profileId)}`,
            );
            return hits;
          }
        } catch (error) {
          console.error("memory k-NN failed, falling back to recency:", error);
        }
      }

      const hits = await this.backend.query(this.profileId, MEMORY_DIGEST_N);
      console.log(
        `memory.recall recency ${hits.length} kept for profile ${redact(this.profileId)}`,
      );
      return hits;
    } catch (error) {
      console.error("memory recall failed, continuing without it:", error);
      return [];
    }
  }

  async remember(input: {
    id: string;
    text: string;
    createdAt: string;
    severity?: string;
  }): Promise<boolean> {
    if (!shouldRemember(input.text, input.severity)) return false;
    try {
      const recent = await this.backend.query(this.profileId, MEMORY_DIGEST_N * 2);
      const incoming = normalize(input.text);
      if (recent.some((hit) => normalize(hit.text) === incoming)) {
        console.log("memory.remember skipped as duplicate");
        return false;
      }

      await this.backend.upsert(
        this.profileId,
        { id: input.id, text: input.text, createdAt: input.createdAt },
      );
      // Off the caller's hot path. A failed embed leaves a null vector; recency
      // still finds the row. Do not await this from the coach stream.
      void this.indexEmbedding(input.id, input.text);
      return true;
    } catch (error) {
      console.error("memory write failed:", error);
      return false;
    }
  }

  private async indexEmbedding(id: string, text: string): Promise<void> {
    if (!this.embedder) return;
    try {
      const vector = await this.embedder.embed(text);
      await this.backend.setEmbedding(this.profileId, id, vector);
    } catch (error) {
      console.error("memory embed failed, row kept without vector:", error);
    }
  }

  async forgetEverything(): Promise<void> {
    await this.backend.deleteAll(this.profileId);
  }
}

export function personalMemoryFor(
  user: VerifiedUser,
  backend: MemoryBackend,
  embedder: Embedder | null = null,
): PersonalMemory {
  return PersonalMemory.create(user, backend, embedder);
}

export function shouldRemember(text: string, severity?: string): boolean {
  if (!text || !text.trim()) return false;
  if (severity && severity !== "none") return false;
  return isDurable(text);
}

/// Store a turn if the safety rules allow. Distill is optional and off the
/// caller's hot path — the coach and voice ingest both fire this after the
/// student has already been answered.
export async function ingestTurn(
  memory: PersonalMemory,
  message: string,
  severity: string | undefined,
  options?: { apiKey: string; distillModel?: string },
): Promise<boolean> {
  const durable = !severity || severity === "none" ? isDurable(message) : false;
  let text = message;
  if (durable && options?.distillModel && options.apiKey) {
    const distilled = await distill(message, {
      apiKey: options.apiKey,
      model: options.distillModel,
    });
    if (!distilled) return false;
    text = distilled;
  }
  return memory.remember({
    id: crypto.randomUUID(),
    text,
    createdAt: new Date().toISOString(),
    severity,
  });
}

export function normalize(text: string): string {
  return text.trim().toLowerCase().replace(/\s+/g, " ");
}

function redact(profileId: string): string {
  return profileId.length <= 8 ? "********" : `${profileId.slice(0, 8)}…`;
}

export interface PostgresOptions {
  restUrl: string;
  serviceRoleKey: string;
  fetchImpl?: typeof fetch;
}

/// PostgREST-backed store. Every call takes `profileId` and puts it in the
/// filter. There is deliberately no method that queries without one.
export class PostgresMemoryBackend implements MemoryBackend {
  constructor(private readonly options: PostgresOptions) {}

  private get fetchImpl(): typeof fetch {
    return this.options.fetchImpl ?? fetch;
  }

  private headers(prefer?: string): HeadersInit {
    return {
      apikey: this.options.serviceRoleKey,
      Authorization: `Bearer ${this.options.serviceRoleKey}`,
      "Content-Type": "application/json",
      ...(prefer ? { Prefer: prefer } : {}),
    };
  }

  async query(profileId: string, k: number): Promise<RecalledMemory[]> {
    const url =
      `${this.options.restUrl}/memories?user_id=eq.${encodeURIComponent(profileId)}` +
      `&select=id,text,created_at&order=created_at.desc&limit=${k}`;
    const response = await this.fetchImpl(url, { headers: this.headers() });
    if (!response.ok) throw new Error(`memories query ${response.status}`);
    const rows: { id: string; text: string; created_at: string }[] = await response.json();
    return rows.map((row) => ({
      id: row.id,
      text: row.text,
      distance: 0,
      createdAt: row.created_at,
    }));
  }

  async querySimilar(
    profileId: string,
    vector: number[],
    k: number,
  ): Promise<RecalledMemory[]> {
    const response = await this.fetchImpl(`${this.options.restUrl}/rpc/match_memories`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        query_embedding: vector,
        match_user_id: profileId,
        match_count: k,
      }),
    });
    if (!response.ok) throw new Error(`match_memories ${response.status}`);
    const rows: {
      id: string;
      body: string;
      distance: number;
      created_at: string;
    }[] = await response.json();
    return rows.map((row) => ({
      id: row.id,
      text: row.body ?? "",
      distance: row.distance ?? 1,
      createdAt: row.created_at,
    }));
  }

  async upsert(profileId: string, record: MemoryRecord): Promise<void> {
    const response = await this.fetchImpl(`${this.options.restUrl}/memories`, {
      method: "POST",
      headers: this.headers("return=minimal"),
      body: JSON.stringify({
        id: record.id,
        user_id: profileId,
        text: record.text,
        created_at: record.createdAt,
      }),
    });
    if (!response.ok) throw new Error(`memories upsert ${response.status}`);
  }

  async setEmbedding(profileId: string, id: string, vector: number[]): Promise<void> {
    const url =
      `${this.options.restUrl}/memories?id=eq.${encodeURIComponent(id)}` +
      `&user_id=eq.${encodeURIComponent(profileId)}`;
    const response = await this.fetchImpl(url, {
      method: "PATCH",
      headers: this.headers("return=minimal"),
      body: JSON.stringify({ embedding: vector }),
    });
    if (!response.ok) throw new Error(`memories embed ${response.status}`);
  }

  async deleteAll(profileId: string): Promise<void> {
    const url =
      `${this.options.restUrl}/memories?user_id=eq.${encodeURIComponent(profileId)}`;
    const response = await this.fetchImpl(url, {
      method: "DELETE",
      headers: this.headers(),
    });
    if (!response.ok) throw new Error(`memories delete ${response.status}`);
  }

  async hasCurrentConsent(profileId: string): Promise<boolean> {
    const url =
      `${this.options.restUrl}/consents?user_id=eq.${encodeURIComponent(profileId)}` +
      `&doc_type=eq.${MEMORY_CONSENT_DOC_TYPE}` +
      `&doc_version=eq.${MEMORY_CONSENT_VERSION}` +
      `&select=id&limit=1`;
    try {
      const response = await this.fetchImpl(url, { headers: this.headers() });
      if (!response.ok) {
        console.error(`memory consent lookup ${response.status}`);
        return false;
      }
      const rows: unknown[] = await response.json();
      return rows.length > 0;
    } catch (error) {
      console.error("memory consent lookup failed:", error);
      return false;
    }
  }
}

export function postgresMemoryFromEnv(
  env: { get(key: string): string | undefined } = Deno.env,
  fetchImpl?: typeof fetch,
): PostgresMemoryBackend | null {
  const supabaseUrl = env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    console.error(
      "memory: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is unset — personal memory is off",
    );
    return null;
  }
  return new PostgresMemoryBackend({
    restUrl: `${supabaseUrl.replace(/\/$/, "")}/rest/v1`,
    serviceRoleKey,
    fetchImpl,
  });
}
