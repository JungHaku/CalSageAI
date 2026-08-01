// Run with:  deno test --allow-net supabase/functions/coach/retrieval.test.ts
//
// The behaviour worth pinning here is not "retrieval works" — tools/eval-retrieval.py
// measures that against the real corpus and real embeddings. It is what happens
// when retrieval *doesn't* work, because that is the path nobody exercises by
// hand and the one that must never take the coach down with it.

import { assertEquals } from "jsr:@std/assert";
import {
  type Embedder,
  FakeVectorStore,
  KINDS_FOR_SURFACE,
  MAX_DISTANCE,
  retrieve,
  type VectorStore,
} from "./retrieval.ts";

const embedder: Embedder = { embed: () => Promise.resolve([1, 0, 0]) };

const corpus = [
  { id: "practice:a", kind: "practice", text: "practice A", distance: 0.3 },
  { id: "question:b", kind: "question", text: "question B", distance: 0.6 },
  { id: "place:c", kind: "place", text: "place C", distance: 0.2 },
  { id: "practice:far", kind: "practice", text: "barely related", distance: 0.95 },
];

function store(): VectorStore {
  return new FakeVectorStore(corpus);
}

Deno.test("chat sees practices and questions, never places", async () => {
  const hits = await retrieve({ surface: "chat", query: "hi", embedder, store: store() });
  assertEquals(hits.map((h) => h.id), ["practice:a", "question:b"]);
});

Deno.test("navigate sees places only", async () => {
  const hits = await retrieve({ surface: "navigate", query: "where is x", embedder, store: store() });
  assertEquals(hits.map((h) => h.id), ["place:c"]);
});

Deno.test("distant neighbours are dropped rather than padded in", async () => {
  const hits = await retrieve({ surface: "chat", query: "hi", embedder, store: store() });
  assertEquals(hits.some((h) => h.id === "practice:far"), false);
  assertEquals(hits.every((h) => h.distance <= MAX_DISTANCE), true);
});

Deno.test("an unknown surface retrieves nothing instead of guessing", async () => {
  const hits = await retrieve({ surface: "nonsense", query: "hi", embedder, store: store() });
  assertEquals(hits, []);
});

Deno.test("an empty query retrieves nothing", async () => {
  const hits = await retrieve({ surface: "chat", query: "   ", embedder, store: store() });
  assertEquals(hits, []);
});

// --- failing open ----------------------------------------------------------
//
// Each of these is a real outage shape. All four must produce an empty array,
// never a throw: retrieval makes a reply better grounded, it is not what makes a
// reply possible.

Deno.test("no store configured means no retrieval, not an error", async () => {
  assertEquals(await retrieve({ surface: "chat", query: "hi", embedder, store: null }), []);
});

Deno.test("no embedder configured means no retrieval, not an error", async () => {
  assertEquals(await retrieve({ surface: "chat", query: "hi", embedder: null, store: store() }), []);
});

Deno.test("an embeddings failure degrades to no retrieval", async () => {
  const broken: Embedder = { embed: () => Promise.reject(new Error("429 rate limited")) };
  assertEquals(await retrieve({ surface: "chat", query: "hi", embedder: broken, store: store() }), []);
});

Deno.test("a vector store failure degrades to no retrieval", async () => {
  const broken: VectorStore = { query: () => Promise.reject(new Error("connection refused")) };
  assertEquals(await retrieve({ surface: "chat", query: "hi", embedder, store: broken }), []);
});

Deno.test("surface routing matches what the eval measures", () => {
  // tools/eval-retrieval.py hard-codes these. If they drift, the eval is
  // measuring a pipeline the function does not have.
  assertEquals(KINDS_FOR_SURFACE.chat, ["practice", "question"]);
  assertEquals(KINDS_FOR_SURFACE.navigate, ["place"]);
});
