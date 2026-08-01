// Run with:  deno test --allow-net supabase/functions/coach/distillation.test.ts

import { assertEquals } from "jsr:@std/assert";
import { distill, isDurable, MIN_DURABLE_CHARS } from "./distillation.ts";

// --- the gate --------------------------------------------------------------

Deno.test("the case this was built for: a question is not a memory", () => {
  // Produced by the first live M2 run — the question was filed alongside the
  // fact it was asking about.
  assertEquals(isDurable("what did I tell you about my roommate?"), false);
  assertEquals(isDurable("what did I tell you about my roommate"), false);
});

Deno.test("statements about the student are kept", () => {
  for (
    const text of [
      "my roommate keeps having loud people over past midnight and I cannot sleep",
      "I have a chemistry midterm on Thursday and I am dreading it",
      "I moved into Unit 3 this semester and I miss my family",
      "my parents are getting divorced and nobody at home will talk about it",
    ]
  ) {
    assertEquals(isDurable(text), true, text);
  }
});

Deno.test("requests aimed at Cal are not facts about the student", () => {
  for (
    const text of [
      "can you guide me through the golden spark visualization please",
      "tell me something calming about breathing exercises",
      "walk me through solar plexus light one line at a time",
      "remind me how the breathing practice goes again",
    ]
  ) {
    assertEquals(isDurable(text), false, text);
  }
});

Deno.test("pleasantries are not memories", () => {
  for (const text of ["hi", "thanks!", "ok cool", "good morning", "sounds good", "yeah"]) {
    assertEquals(isDurable(text), false, text);
  }
});

/// The gate is deliberately tuned to under-collect: this is health data, and
/// every stored row is one that has to be disclosed, exported and deleted.
Deno.test("a statement opening with an interrogative word still counts", () => {
  assertEquals(isDurable("I know where the gym is, I just cannot make myself go"), true);
  assertEquals(isDurable("how do I sign up for the gym"), false);
});

Deno.test("fragments below the length floor are dropped", () => {
  assertEquals(isDurable("x".repeat(MIN_DURABLE_CHARS - 1)), false);
  assertEquals(isDurable("I am struggling a lot lately"), true);
});

// --- distillation ----------------------------------------------------------

function fakeCompletion(content: string) {
  return () =>
    Promise.resolve(
      new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 }),
    );
}

Deno.test("a durable fact comes back rewritten", async () => {
  const result = await distill("my roommate keeps having people over past midnight", {
    apiKey: "k",
    model: "m",
    fetchImpl: fakeCompletion("Their roommate hosts loud guests after midnight, disrupting sleep."),
  });
  assertEquals(result, "Their roommate hosts loud guests after midnight, disrupting sleep.");
});

Deno.test("NONE means store nothing", async () => {
  for (const reply of ["NONE", "none", "NONE.", " NONE "]) {
    const result = await distill("hey", { apiKey: "k", model: "m", fetchImpl: fakeCompletion(reply) });
    assertEquals(result, null, reply);
  }
});

/// Falling back to the raw text would mean a model outage silently changes what
/// is stored — and the store is the thing a privacy policy has to describe
/// accurately.
Deno.test("a distillation failure stores nothing rather than the raw turn", async () => {
  const failures = [
    () => Promise.resolve(new Response("nope", { status: 500 })),
    () => Promise.reject(new Error("connection refused")),
    () => Promise.resolve(new Response(JSON.stringify({ choices: [] }), { status: 200 })),
  ];
  for (const fetchImpl of failures) {
    assertEquals(await distill("something real", { apiKey: "k", model: "m", fetchImpl }), null);
  }
});
