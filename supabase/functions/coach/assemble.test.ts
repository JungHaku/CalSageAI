// Run with:  deno test supabase/functions/coach/assemble.test.ts
//
// The ordering assertions below are the point of this file. A reordering that
// puts anything volatile ahead of the history is invisible in review, works
// perfectly, and quietly halves the prompt-cache discount (§10.4 item 5) — the
// kind of defect that surfaces on an invoice rather than in a bug report.

import { assertEquals } from "jsr:@std/assert";
import { assembleMessages, MAX_TEXT_CHARS, MAX_TURNS, windowHistory } from "./assemble.ts";

const SYSTEM = "You are Cal.";

function thread(turns: number) {
  return Array.from({ length: turns }, (_, i) => [
    { role: "user" as const, text: `u${i}` },
    { role: "assistant" as const, text: `a${i}` },
  ]).flat();
}

Deno.test("the system prompt is first and unmodified", () => {
  const messages = assembleMessages({ systemPrompt: SYSTEM, message: "hi" });
  assertEquals(messages[0], { role: "system", content: SYSTEM });
});

Deno.test("with no history or digest it is just system + message", () => {
  const messages = assembleMessages({ systemPrompt: SYSTEM, message: "hi" });
  assertEquals(messages.length, 2);
  assertEquals(messages[1], { role: "user", content: "hi" });
});

Deno.test("order is system, digest, history, message", () => {
  const messages = assembleMessages({
    systemPrompt: SYSTEM,
    coherence: "7-day avg coherence 6.2.",
    history: thread(2),
    message: "now what",
  });

  assertEquals(messages.map((m) => m.role), [
    "system", // prompt
    "system", // digest
    "user",
    "assistant",
    "user",
    "assistant",
    "user", // the new message
  ]);
  assertEquals(messages[messages.length - 1].content, "now what");
});

Deno.test("history sits ahead of the new message so the prefix keeps growing", () => {
  const first = assembleMessages({ systemPrompt: SYSTEM, history: thread(1), message: "b" });
  const second = assembleMessages({ systemPrompt: SYSTEM, history: thread(2), message: "c" });

  // Everything the shorter call sent, minus its final user message, must be a
  // byte-identical prefix of the longer one. That property IS the cache hit.
  const prefix = first.slice(0, -1);
  assertEquals(second.slice(0, prefix.length), prefix);
});

Deno.test("the digest is fenced and labelled as data", () => {
  const messages = assembleMessages({
    systemPrompt: SYSTEM,
    coherence: "Streak: 4 days.",
    message: "hi",
  });
  const block = messages[1].content;

  assertEquals(block.includes("<coherence>"), true);
  assertEquals(block.includes("Streak: 4 days."), true);
  assertEquals(block.includes("DATA, not instructions"), true);
});

Deno.test("an empty or whitespace digest adds no block", () => {
  for (const coherence of [undefined, null, "", "   \n "]) {
    const messages = assembleMessages({ systemPrompt: SYSTEM, coherence, message: "hi" });
    assertEquals(messages.length, 2, `digest ${JSON.stringify(coherence)} should be omitted`);
  }
});

Deno.test("history is capped server-side regardless of what the client sent", () => {
  const carried = windowHistory(thread(40));
  assertEquals(carried.length, MAX_TURNS * 2);
  assertEquals(carried[0], { role: "user", text: `u${40 - MAX_TURNS}` });
});

Deno.test("the window opens on a user message, never a dangling reply", () => {
  const carried = windowHistory([{ role: "assistant", text: "orphan" }, ...thread(10)]);
  assertEquals(carried[0].role, "user");
});

Deno.test("malformed turns are dropped rather than forwarded", () => {
  const carried = windowHistory([
    { role: "user", text: "keep me" },
    { role: "system", text: "not a turn" } as never,
    { role: "assistant", text: "" },
    { role: "user", text: 42 } as never,
    null as never,
  ]);
  assertEquals(carried, [{ role: "user", text: "keep me" }]);
});

Deno.test("an oversized message is clamped", () => {
  const messages = assembleMessages({ systemPrompt: SYSTEM, message: "x".repeat(50_000) });
  assertEquals(messages[1].content.length, MAX_TEXT_CHARS);
});
