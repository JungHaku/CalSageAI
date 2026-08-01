// Run with:  deno test --allow-net supabase/functions/coach/memory.test.ts
//
// The test that matters here is `isolation`. Everything else in this file is
// ordinary; that one is the difference between a memory feature and a data
// breach involving students' mental health.

import { assertEquals, assertRejects } from "jsr:@std/assert";
import { type VerifiedUser, verifyUser } from "./identity.ts";
import {
  agedDistance,
  type MemoryBackend,
  MEMORY_MAX_DISTANCE,
  type MemoryRecord,
  personalMemoryFor,
  shouldRemember,
} from "./memory.ts";
import type { Embedder, RetrievedChunk } from "./retrieval.ts";

const embedder: Embedder = { embed: () => Promise.resolve([1, 0, 0]) };

/// Stores per profile and, crucially, only ever returns what was filed under the
/// profile it is asked for — the same contract Chroma's `where` clause provides.
class FakeBackend implements MemoryBackend {
  readonly byProfile = new Map<string, MemoryRecord[]>();
  readonly queriedProfiles: string[] = [];

  query(profileId: string, _vector: number[], k: number): Promise<RetrievedChunk[]> {
    this.queriedProfiles.push(profileId);
    const records = this.byProfile.get(profileId) ?? [];
    return Promise.resolve(
      // 0.6 because that is roughly where genuinely distinct memories sit —
      // measured live, two unrelated topics in one store are ~0.73 apart, while
      // the same fact retold is ~0.23. An arbitrary 0.3 sat right on the dedupe
      // threshold and made this fixture change meaning when the threshold moved.
      records.slice(0, k).map((record) => ({ id: record.id, text: record.text, distance: 0.6 })),
    );
  }

  upsert(profileId: string, record: MemoryRecord): Promise<void> {
    const records = this.byProfile.get(profileId) ?? [];
    records.push(record);
    this.byProfile.set(profileId, records);
    return Promise.resolve();
  }

  deleteAll(profileId: string): Promise<void> {
    this.byProfile.delete(profileId);
    return Promise.resolve();
  }
}

const alice: VerifiedUser = { id: "aaaaaaaa-0000-0000-0000-000000000001" };
const bob: VerifiedUser = { id: "bbbbbbbb-0000-0000-0000-000000000002" };

function write(text: string) {
  return { id: crypto.randomUUID(), text, createdAt: "2026-08-01T00:00:00Z" };
}

// --- isolation -------------------------------------------------------------

Deno.test("isolation: one person's memory is never returned to another", async () => {
  const backend = new FakeBackend();

  const aliceMemory = personalMemoryFor(alice, backend, embedder);
  await aliceMemory.remember(write("my roommate keeps having people over late"));

  const bobMemory = personalMemoryFor(bob, backend, embedder);
  // Writing also queries now (M3 dedupe), so measure only what Bob's recall did.
  const before = backend.queriedProfiles.length;
  const recalled = await bobMemory.recall("roommate");

  assertEquals(recalled, [], "Bob must not see Alice's memory");
  assertEquals(
    backend.queriedProfiles.slice(before),
    [bob.id],
    "Bob's recall must query only Bob",
  );
});

Deno.test("isolation: the profile id comes from the verified user, not a caller", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend, embedder).remember(write("something about my week"));

  // There is no API surface that accepts a profile id — the only way to reach
  // memory is to hold a VerifiedUser. This asserts the shape stays that way.
  const memory = personalMemoryFor(bob, backend, embedder);
  const before = backend.queriedProfiles.length;
  await memory.recall("week");
  assertEquals(backend.queriedProfiles.slice(before).every((id) => id === bob.id), true);
});

Deno.test("isolation: forgetting one person leaves the other untouched", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend, embedder)
    .remember(write("my roommate has loud guests on weeknights"));
  await personalMemoryFor(bob, backend, embedder)
    .remember(write("my chemistry midterm is on Thursday morning"));

  await personalMemoryFor(alice, backend, embedder).forgetEverything();

  assertEquals(backend.byProfile.has(alice.id), false);
  assertEquals(backend.byProfile.get(bob.id)?.length, 1);
});

// --- what may be remembered ------------------------------------------------

Deno.test("a crisis is never written to memory", () => {
  // Stricter than ConversationWindow on purpose. There, elevated content still
  // travels because the model is answering that message. Here the question is
  // whether it should resurface unprompted weeks later, and the answer is no.
  assertEquals(shouldRemember("I want to end my life", "acute"), false);
  assertEquals(shouldRemember("some days I want to die", "elevated"), false);
  assertEquals(shouldRemember("my chemistry midterm is on Thursday", "none"), true);
  assertEquals(shouldRemember("my chemistry midterm is on Thursday"), true);
});

Deno.test("remember() refuses flagged text rather than relying on the caller", async () => {
  const backend = new FakeBackend();
  const memory = personalMemoryFor(alice, backend, embedder);

  const wrote = await memory.remember({ ...write("I want to kill myself"), severity: "acute" });

  assertEquals(wrote, false);
  assertEquals(backend.byProfile.get(alice.id), undefined);
});

Deno.test("trivial fragments are not stored", () => {
  assertEquals(shouldRemember("ok", "none"), false);
  assertEquals(shouldRemember("   ", "none"), false);
  assertEquals(shouldRemember(""), false);
});

// --- recall behaviour ------------------------------------------------------

Deno.test("distant memories are dropped, and the bar is higher than for content", async () => {
  const backend: MemoryBackend = {
    query: () =>
      Promise.resolve([
        { id: "near", text: "close enough", distance: 0.4 },
        { id: "far", text: "not really related", distance: 0.8 },
      ]),
    upsert: () => Promise.resolve(),
    deleteAll: () => Promise.resolve(),
  };

  const recalled = await personalMemoryFor(alice, backend, embedder).recall("anything");

  assertEquals(recalled.map((r) => r.id), ["near"]);
  assertEquals(MEMORY_MAX_DISTANCE < 0.82, true, "memory must be stricter than content retrieval");
});

Deno.test("an empty query recalls nothing", async () => {
  const backend = new FakeBackend();
  assertEquals(await personalMemoryFor(alice, backend, embedder).recall("  "), []);
});

Deno.test("a backend failure degrades to no memory rather than no reply", async () => {
  const backend: MemoryBackend = {
    query: () => Promise.reject(new Error("chroma is down")),
    upsert: () => Promise.resolve(),
    deleteAll: () => Promise.resolve(),
  };
  assertEquals(await personalMemoryFor(alice, backend, embedder).recall("anything"), []);
});

Deno.test("forgetEverything propagates failure instead of pretending to succeed", async () => {
  // The opposite of recall on purpose. Silently failing to delete is the one
  // outcome that turns a deletion promise into a false statement.
  const backend: MemoryBackend = {
    query: () => Promise.resolve([]),
    upsert: () => Promise.resolve(),
    deleteAll: () => Promise.reject(new Error("delete failed")),
  };
  await assertRejects(() => personalMemoryFor(alice, backend, embedder).forgetEverything());
});

// --- identity --------------------------------------------------------------

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
  // Clients that are not signed in send the anon key as their bearer token. It
  // is a valid JWT, so if this were not rejected every anonymous device on the
  // planet would share one memory store.
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
    fetchImpl: () => Promise.resolve(new Response(JSON.stringify({ email: "x@y.z" }), { status: 200 })),
  });
  assertEquals(result, null);
});

Deno.test("a valid token yields the id the auth server reports", async () => {
  const result = await verifyUser(requestWith("Bearer good"), {
    ...identityOptions,
    fetchImpl: () => Promise.resolve(new Response(JSON.stringify({ id: alice.id }), { status: 200 })),
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

// --- M3: dedupe and decay --------------------------------------------------

Deno.test("saying the same thing twice does not store it twice", async () => {
  // A worry repeated three nights running is the normal shape of a worry. Stored
  // three times it crowds everything else out of the top-3.
  const backend: MemoryBackend = {
    query: () => Promise.resolve([{ id: "existing", text: "same worry", distance: 0.05 }]),
    upsert: () => {
      throw new Error("a near-duplicate must not be written");
    },
    deleteAll: () => Promise.resolve(),
  };

  const wrote = await personalMemoryFor(alice, backend, embedder)
    .remember(write("my roommate is still having people over late"));

  assertEquals(wrote, false);
});

Deno.test("a genuinely different memory is still written", async () => {
  const backend = new FakeBackend();
  await personalMemoryFor(alice, backend, embedder).remember(write("my roommate has loud guests late"));
  // FakeBackend reports 0.6, comfortably outside the dedupe radius.
  const wrote = await personalMemoryFor(alice, backend, embedder)
    .remember(write("my chemistry midterm is on Thursday and I am dreading it"));

  assertEquals(wrote, true);
  assertEquals(backend.byProfile.get(alice.id)?.length, 2);
});

Deno.test("age penalises a memory without ever hard-dropping it", () => {
  const now = new Date("2026-08-01T00:00:00Z");
  const fresh = agedDistance(0.40, "2026-07-31T00:00:00Z", now);
  const old = agedDistance(0.40, "2024-08-01T00:00:00Z", now);

  assertEquals(fresh < old, true, "a fresher memory must rank ahead of an identical old one");
  assertEquals(Math.abs(fresh - 0.40) < 0.001, true, "yesterday is essentially unpenalised");
  assertEquals(old > 0.59 && old < 0.61, true, `two years should cost ~0.2, got ${old}`);
});

Deno.test("a recent, slightly-worse match beats a stale, slightly-better one", async () => {
  const now = new Date("2026-08-01T00:00:00Z");
  const backend: MemoryBackend = {
    query: () =>
      Promise.resolve([
        { id: "stale", text: "from two years ago", distance: 0.30, createdAt: "2024-08-01T00:00:00Z" },
        { id: "recent", text: "from last week", distance: 0.38, createdAt: "2026-07-25T00:00:00Z" },
      ]),
    upsert: () => Promise.resolve(),
    deleteAll: () => Promise.resolve(),
  };

  const recalled = await personalMemoryFor(alice, backend, embedder).recall("anything", 2, now);
  assertEquals(recalled[0].id, "recent");
});

Deno.test("a malformed timestamp leaves the distance alone rather than corrupting it", () => {
  assertEquals(agedDistance(0.4, "not a date", new Date()), 0.4);
});
