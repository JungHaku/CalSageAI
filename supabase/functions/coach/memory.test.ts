// Run with:  deno test --allow-net supabase/functions/coach/memory.test.ts

import { assertEquals, assertRejects } from "jsr:@std/assert";
import { type VerifiedUser, verifyUser } from "./identity.ts";
import {
  type MemoryBackend,
  type MemoryRecord,
  MEMORY_CONSENT_DOC_TYPE,
  MEMORY_CONSENT_VERSION,
  MEMORY_DIGEST_N,
  MEMORY_SIMILAR_K,
  normalize,
  personalMemoryFor,
  PostgresMemoryBackend,
  shouldRemember,
  ingestTurn,
} from "./memory.ts";
import type { RecalledMemory } from "./memory.ts";
import type { Embedder } from "./retrieval.ts";

class FakeBackend implements MemoryBackend {
  readonly byProfile = new Map<string, MemoryRecord[]>();
  readonly queriedProfiles: string[] = [];
  readonly similarProfiles: string[] = [];
  embeddings = new Map<string, number[]>();

  query(profileId: string, k: number): Promise<RecalledMemory[]> {
    this.queriedProfiles.push(profileId);
    const records = (this.byProfile.get(profileId) ?? [])
      .slice()
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, k);
    return Promise.resolve(
      records.map((record) => ({
        id: record.id,
        text: record.text,
        distance: 0,
        createdAt: record.createdAt,
      })),
    );
  }

  querySimilar(profileId: string, vector: number[], k: number): Promise<RecalledMemory[]> {
    this.similarProfiles.push(profileId);
    const records = this.byProfile.get(profileId) ?? [];
    const scored: RecalledMemory[] = [];
    for (const record of records) {
      const embedding = this.embeddings.get(record.id) ?? record.embedding;
      if (!embedding?.length) continue;
      scored.push({
        id: record.id,
        text: record.text,
        distance: cosineDistance(vector, embedding),
        createdAt: record.createdAt,
      });
    }
    scored.sort((a, b) => a.distance - b.distance);
    return Promise.resolve(scored.slice(0, k));
  }

  upsert(profileId: string, record: MemoryRecord): Promise<void> {
    const records = this.byProfile.get(profileId) ?? [];
    records.push(record);
    this.byProfile.set(profileId, records);
    return Promise.resolve();
  }

  setEmbedding(_profileId: string, id: string, vector: number[]): Promise<void> {
    this.embeddings.set(id, vector);
    return Promise.resolve();
  }

  deleteAll(profileId: string): Promise<void> {
    this.byProfile.delete(profileId);
    return Promise.resolve();
  }
}

function cosineDistance(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom === 0 ? 1 : 1 - dot / denom;
}

const alice: VerifiedUser = { id: "aaaaaaaa-0000-0000-0000-000000000001" };
const bob: VerifiedUser = { id: "bbbbbbbb-0000-0000-0000-000000000002" };

function write(text: string, createdAt = "2026-08-01T00:00:00Z") {
  return { id: crypto.randomUUID(), text, createdAt };
}

Deno.test("isolation: one person's memory is never returned to another", async () => {
  const backend = new FakeBackend();

  await personalMemoryFor(alice, backend).remember(
    write("my roommate keeps having people over late"),
  );

  const before = backend.queriedProfiles.length;
  const recalled = await personalMemoryFor(bob, backend).recall("roommate");

  assertEquals(recalled, [], "Bob must not see Alice's memory");
  assertEquals(
    backend.queriedProfiles.slice(before),
    [bob.id],
    "Bob's recall must query only Bob",
  );
});

Deno.test("isolation: the profile id comes from the verified user, not a caller", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend).remember(write("something about my week"));

  const before = backend.queriedProfiles.length;
  await personalMemoryFor(bob, backend).recall("week");
  assertEquals(backend.queriedProfiles.slice(before).every((id) => id === bob.id), true);
});

Deno.test("isolation: forgetting one person leaves the other untouched", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend)
    .remember(write("my roommate has loud guests on weeknights"));
  await personalMemoryFor(bob, backend)
    .remember(write("my chemistry midterm is on Thursday morning"));

  await personalMemoryFor(alice, backend).forgetEverything();

  assertEquals(backend.byProfile.has(alice.id), false);
  assertEquals(backend.byProfile.get(bob.id)?.length, 1);
});

Deno.test("a crisis is never written to memory", () => {
  assertEquals(shouldRemember("I want to end my life", "acute"), false);
  assertEquals(shouldRemember("some days I want to die", "elevated"), false);
  assertEquals(shouldRemember("my chemistry midterm is on Thursday", "none"), true);
  assertEquals(shouldRemember("my chemistry midterm is on Thursday"), true);
});

Deno.test("remember() refuses flagged text rather than relying on the caller", async () => {
  const backend = new FakeBackend();
  const wrote = await personalMemoryFor(alice, backend).remember({
    ...write("I want to kill myself"),
    severity: "acute",
  });

  assertEquals(wrote, false);
  assertEquals(backend.byProfile.get(alice.id), undefined);
});

Deno.test("trivial fragments are not stored", () => {
  assertEquals(shouldRemember("ok", "none"), false);
  assertEquals(shouldRemember("   ", "none"), false);
  assertEquals(shouldRemember(""), false);
});

Deno.test("recall returns the newest facts first", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  await memory.remember(write("my chemistry midterm is on Thursday morning", "2026-07-01T00:00:00Z"));
  await memory.remember(write("my roommate keeps having people over late", "2026-08-01T00:00:00Z"));

  const recalled = await memory.recall("anything");
  assertEquals(recalled[0].text.includes("roommate"), true);
  assertEquals(recalled.length, 2);
});

Deno.test("recall still works when the query is empty — recency does not need it", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend).remember(
    write("my roommate keeps having people over late"),
  );
  const recalled = await personalMemoryFor(alice, backend).recall("  ");
  assertEquals(recalled.length, 1);
});

Deno.test("a backend failure degrades to no memory rather than no reply", async () => {
  const backend: MemoryBackend = {
    query: () => Promise.reject(new Error("postgres is down")),
    querySimilar: () => Promise.reject(new Error("postgres is down")),
    upsert: () => Promise.resolve(),
    setEmbedding: () => Promise.resolve(),
    deleteAll: () => Promise.resolve(),
  };
  assertEquals(await personalMemoryFor(alice, backend).recall("anything"), []);
});

Deno.test("forgetEverything propagates failure instead of pretending to succeed", async () => {
  const backend: MemoryBackend = {
    query: () => Promise.resolve([]),
    querySimilar: () => Promise.resolve([]),
    upsert: () => Promise.resolve(),
    setEmbedding: () => Promise.resolve(),
    deleteAll: () => Promise.reject(new Error("delete failed")),
  };
  await assertRejects(() => personalMemoryFor(alice, backend).forgetEverything());
});

function requestWith(authorization?: string): Request {
  return new Request("https://example.invalid/", {
    headers: authorization ? { Authorization: authorization } : {},
  });
}

const identityOptions = {
  supabaseUrl: "https://auth.invalid",
  anonKey: "anon-key",
};

Deno.test("no Authorization header means no user", async () => {
  assertEquals(await verifyUser(requestWith(), identityOptions), null);
});

Deno.test("the anon key is not a user", async () => {
  let called = false;
  const result = await verifyUser(requestWith("Bearer anon-key"), {
    ...identityOptions,
    fetchImpl: () => {
      called = true;
      return Promise.resolve(new Response("{}", { status: 200 }));
    },
  });
  assertEquals(result, null);
  assertEquals(called, false, "the anon key must be rejected without a round trip");
});

Deno.test("a rejected token means no user", async () => {
  const result = await verifyUser(requestWith("Bearer forged"), {
    ...identityOptions,
    fetchImpl: () => Promise.resolve(new Response("no", { status: 403 })),
  });
  assertEquals(result, null);
});

Deno.test("a 200 without an id is still not a user", async () => {
  const result = await verifyUser(requestWith("Bearer odd"), {
    ...identityOptions,
    fetchImpl: () =>
      Promise.resolve(new Response(JSON.stringify({ email: "x@y.z" }), { status: 200 })),
  });
  assertEquals(result, null);
});

Deno.test("a valid token yields the id the auth server reports", async () => {
  const result = await verifyUser(requestWith("Bearer good"), {
    ...identityOptions,
    fetchImpl: () =>
      Promise.resolve(new Response(JSON.stringify({ id: alice.id }), { status: 200 })),
  });
  assertEquals(result, { id: alice.id });
});

Deno.test("an unreachable auth server fails closed", async () => {
  const result = await verifyUser(requestWith("Bearer good"), {
    ...identityOptions,
    fetchImpl: () => Promise.reject(new Error("connection refused")),
  });
  assertEquals(result, null, "an auth outage must not grant an identity");
});

Deno.test("saying the same thing twice does not store it twice", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  const text = "my roommate keeps having people over late at night";
  assertEquals(await memory.remember(write(text)), true);
  assertEquals(await memory.remember(write(`  ${text.toUpperCase()}  `)), false);
  assertEquals(backend.byProfile.get(alice.id)?.length, 1);
});

Deno.test("a genuinely different memory is still written", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend).remember(
    write("my roommate has loud guests late"),
  );
  const wrote = await personalMemoryFor(alice, backend).remember(
    write("my chemistry midterm is on Thursday and I am dreading it"),
  );

  assertEquals(wrote, true);
  assertEquals(backend.byProfile.get(alice.id)?.length, 2);
});

Deno.test("normalize collapses case and whitespace for dedupe", () => {
  assertEquals(
    normalize("  My Roommate  keeps having people over  "),
    "my roommate keeps having people over",
  );
});

Deno.test("MEMORY_DIGEST_N is the recency window, not a vector top-k of 3", () => {
  assertEquals(MEMORY_DIGEST_N, 10);
  assertEquals(MEMORY_SIMILAR_K, 5);
});

Deno.test("recall with a query vector returns nearest facts, not the newest", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  const older = write("my chemistry midterm is on Thursday morning", "2026-07-01T00:00:00Z");
  const newer = write("my roommate keeps having people over late", "2026-08-01T00:00:00Z");
  await memory.remember(older);
  await memory.remember(newer);
  backend.embeddings.set(older.id, [1, 0]);
  backend.embeddings.set(newer.id, [0, 1]);

  const recalled = await memory.recall("midterm", { vector: [1, 0] });
  assertEquals(recalled[0].text.includes("chemistry"), true);
  assertEquals(backend.similarProfiles.includes(alice.id), true);
});

Deno.test("k-NN that returns nothing falls back to recency", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  await memory.remember(write("my roommate keeps having people over late"));
  const recalled = await memory.recall("roommate", { vector: [1, 0] });
  assertEquals(recalled.length, 1);
  assertEquals(recalled[0].text.includes("roommate"), true);
});

Deno.test("a k-NN failure falls back to recency rather than empty", async () => {
  const backend: MemoryBackend = {
    query: () =>
      Promise.resolve([{ id: "1", text: "my chemistry midterm is Thursday", distance: 0 }]),
    querySimilar: () => Promise.reject(new Error("rpc down")),
    upsert: () => Promise.resolve(),
    setEmbedding: () => Promise.resolve(),
    deleteAll: () => Promise.resolve(),
  };
  const recalled = await personalMemoryFor(alice, backend).recall("midterm", { vector: [1] });
  assertEquals(recalled.length, 1);
});

Deno.test("remember indexes an embedding without blocking the caller on failure", async () => {
  const backend = new FakeBackend();
  const embedder: Embedder = { embed: () => Promise.resolve([0.2, 0.8]) };
  const memory = personalMemoryFor(alice, backend, embedder);
  const record = write("my chemistry midterm is on Thursday morning");
  assertEquals(await memory.remember(record), true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assertEquals(backend.embeddings.get(record.id), [0.2, 0.8]);
});

Deno.test("ingestTurn stores a durable none-severity turn", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  const stored = await ingestTurn(
    memory,
    "my chemistry midterm is on Thursday morning",
    "none",
  );
  assertEquals(stored, true);
  assertEquals(backend.byProfile.get(alice.id)?.length, 1);
});

Deno.test("ingestTurn does not store crisis or elevated turns", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend);
  assertEquals(
    await ingestTurn(memory, "I want to kill myself", "acute"),
    false,
  );
  assertEquals(
    await ingestTurn(memory, "some days I just want to die", "elevated"),
    false,
  );
  assertEquals(backend.byProfile.get(alice.id), undefined);
});

// --- Postgres REST backend -------------------------------------------------

Deno.test("PostgresMemoryBackend scopes every request by profile id", async () => {
  const urls: string[] = [];
  const backend = new PostgresMemoryBackend({
    restUrl: "https://stack.invalid/rest/v1",
    serviceRoleKey: "service",
    fetchImpl: (input, init) => {
      const url = String(input);
      urls.push(`${init?.method ?? "GET"} ${url}`);
      if (url.includes("/consents")) {
        return Promise.resolve(new Response("[]", { status: 200 }));
      }
      if (url.includes("match_memories")) {
        return Promise.resolve(
          new Response(
            JSON.stringify([{ id: "1", body: "fact", distance: 0.1, created_at: "2026-08-01T00:00:00Z" }]),
            { status: 200 },
          ),
        );
      }
      if (
        url.includes("/memories") &&
        (init?.method === "POST" || init?.method === "DELETE" || init?.method === "PATCH")
      ) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      return Promise.resolve(
        new Response(
          JSON.stringify([{ id: "1", text: "fact", created_at: "2026-08-01T00:00:00Z" }]),
          { status: 200 },
        ),
      );
    },
  });

  await backend.query(alice.id, 10);
  await backend.querySimilar(alice.id, [0.1, 0.2], 5);
  await backend.upsert(alice.id, write("my chemistry midterm is on Thursday morning"));
  await backend.setEmbedding(alice.id, "1", [0.1, 0.2]);
  await backend.deleteAll(alice.id);
  await backend.hasCurrentConsent(alice.id);

  assertEquals(urls.some((line) => line.includes("GET") && line.includes(alice.id)), true);
  assertEquals(urls.some((line) => line.includes("DELETE") && line.includes(alice.id)), true);
  assertEquals(urls.some((line) => line.includes("POST") && line.includes("/memories")), true);
  assertEquals(urls.some((line) => line.includes("POST") && line.includes("match_memories")), true);
  assertEquals(urls.some((line) => line.includes("PATCH") && line.includes(alice.id)), true);
  assertEquals(urls.some((line) => line.includes(bob.id)), false);
  assertEquals(
    urls.some((line) =>
      line.includes(`doc_type=eq.${MEMORY_CONSENT_DOC_TYPE}`) &&
      line.includes(`doc_version=eq.${MEMORY_CONSENT_VERSION}`)
    ),
    true,
  );
});

Deno.test("consent lookup fails closed when the row is missing", async () => {
  const backend = new PostgresMemoryBackend({
    restUrl: "https://stack.invalid/rest/v1",
    serviceRoleKey: "service",
    fetchImpl: () => Promise.resolve(new Response("[]", { status: 200 })),
  });
  assertEquals(await backend.hasCurrentConsent(alice.id), false);
});

Deno.test("consent lookup succeeds when a current row exists", async () => {
  const backend = new PostgresMemoryBackend({
    restUrl: "https://stack.invalid/rest/v1",
    serviceRoleKey: "service",
    fetchImpl: () =>
      Promise.resolve(new Response(JSON.stringify([{ id: "c1" }]), { status: 200 })),
  });
  assertEquals(await backend.hasCurrentConsent(alice.id), true);
});

Deno.test("consent lookup fails closed on an outage", async () => {
  const backend = new PostgresMemoryBackend({
    restUrl: "https://stack.invalid/rest/v1",
    serviceRoleKey: "service",
    fetchImpl: () => Promise.reject(new Error("down")),
  });
  assertEquals(await backend.hasCurrentConsent(alice.id), false);
});
