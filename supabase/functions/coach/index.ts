// Cal — the coach proxy.
//
// The only reason this exists: an iOS binary cannot hold an API key. An `.ipa` is
// a zip and strings come out of it in minutes, so a shipped key is one a stranger
// can spend on our account. The app calls this; this holds the key
// (ARCHITECTURE.md §8.1).
//
// Deliberately small. §8 and §10 describe a server-side classifier, per-user
// budgets in `ai_usage`, prompt versioning and a kill switch. None of that is
// here yet, because none of it is needed to put real replies in front of Dr. Mia,
// and shipping half of a budget system is worse than shipping none. What IS here
// is the key boundary, a hard cap on a single reply, and honest failure.
//
// Run it:
//   supabase functions serve --env-file supabase/functions/.env --no-verify-jwt
//
// The crisis prefilter is NOT here. It runs on the device, before a message is
// ever sent — which is the only place it can work with no network, and the only
// place it works before a token is spent.

import { CAL_SYSTEM_PROMPT, PROMPT_VERSION } from "./prompt.ts";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const DEFAULT_MODEL = "gpt-5.6-luna";

/// A single reply is capped. Not a budget — a blast radius. Without it one
/// malformed request can run until the model decides to stop, and during
/// development that is real money for output nobody reads.
const MAX_OUTPUT_TOKENS = 400;

interface CoachBody {
  message?: string;
  threadId?: string;
  /// Prior turns, oldest first. The app sends these because the function keeps no
  /// state — there is no session here, deliberately.
  history?: { role: "user" | "assistant"; text: string }[];
}

function sse(event: Record<string, unknown>): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`);
}

/// Errors the *client* should show as Cal speaking rather than as a crash.
/// A student should never see a stack trace because our key expired.
function fallbackStream(text: string): Response {
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(sse({ type: "fallback", text }));
      controller.enqueue(sse({ type: "done" }));
      controller.close();
    },
  });
  return new Response(body, {
    headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("POST only", { status: 405 });
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  // Fail loudly in the log, gently on screen. A missing key is our problem, and
  // the person holding the phone can do nothing about it.
  if (!apiKey || apiKey === "sk-replace-me") {
    console.error("OPENAI_API_KEY is missing or still the placeholder");
    return fallbackStream(
      "I'm not able to think right now. Your practices and check-in are all still here.",
    );
  }

  let body: CoachBody;
  try {
    body = await req.json();
  } catch {
    return new Response("bad JSON", { status: 400 });
  }

  const message = (body.message ?? "").trim();
  if (!message) return new Response("empty message", { status: 400 });

  const model = Deno.env.get("CAL_MODEL") ?? DEFAULT_MODEL;

  // System prompt first and byte-identical every time: prompt caching keys on a
  // stable prefix, so anything that reorders or interpolates into it silently
  // destroys the discount (§10.4).
  const messages = [
    { role: "system", content: CAL_SYSTEM_PROMPT },
    ...(body.history ?? []).map((m) => ({ role: m.role, content: m.text })),
    { role: "user", content: message },
  ];

  let upstream: Response;
  try {
    upstream = await fetch(OPENAI_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages,
        stream: true,
        // Without this the usage object never arrives on a streamed response and
        // cost-per-reply is unknowable.
        stream_options: { include_usage: true },
        max_completion_tokens: MAX_OUTPUT_TOKENS,
      }),
    });
  } catch (error) {
    console.error("upstream fetch failed:", error);
    return fallbackStream("I couldn't reach my thoughts just then. Try me again in a moment.");
  }

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => "");
    console.error(`upstream ${upstream.status}: ${detail.slice(0, 500)}`);
    // 429 and 5xx are transient; anything else is likely our configuration.
    return fallbackStream(
      upstream.status === 429
        ? "A lot of people are talking to me right now. Give me a minute?"
        : "I'm not able to think right now. Your practices and check-in are all still here.",
    );
  }

  // Relay, rather than buffer. The whole point of streaming is that the first
  // words appear while the rest is still being written; awaiting the full body
  // here would throw that away and leave the student watching a spinner.
  const stream = new ReadableStream({
    async start(controller) {
      const reader = upstream.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });

          // SSE events are separated by a blank line. Anything after the last
          // separator is a partial event and must stay in the buffer — splitting
          // on newline alone is the classic way to corrupt a stream.
          const events = buffer.split("\n\n");
          buffer = events.pop() ?? "";

          for (const raw of events) {
            const line = raw.split("\n").find((l) => l.startsWith("data:"));
            if (!line) continue;
            const payload = line.slice(5).trim();
            if (payload === "[DONE]") continue;

            try {
              const chunk = JSON.parse(payload);
              const delta = chunk.choices?.[0]?.delta?.content;
              if (delta) controller.enqueue(sse({ type: "delta", text: delta }));

              if (chunk.usage) {
                controller.enqueue(sse({
                  type: "usage",
                  model,
                  promptVersion: PROMPT_VERSION,
                  inputTokens: chunk.usage.prompt_tokens ?? 0,
                  cachedTokens: chunk.usage.prompt_tokens_details?.cached_tokens ?? 0,
                  outputTokens: chunk.usage.completion_tokens ?? 0,
                }));
              }
            } catch {
              // A single unparseable chunk is not worth killing a reply that is
              // otherwise arriving fine.
              console.warn("skipped unparseable chunk");
            }
          }
        }
        controller.enqueue(sse({ type: "done" }));
      } catch (error) {
        console.error("stream relay failed:", error);
        controller.enqueue(sse({ type: "error", message: "stream interrupted" }));
      } finally {
        controller.close();
        reader.releaseLock();
      }
    },

    // Fires when the client goes away — the student left the chat screen. Without
    // this the upstream request keeps running and keeps billing for output
    // nobody will ever read.
    cancel(reason) {
      console.log("client disconnected:", reason);
      upstream.body?.cancel().catch(() => {});
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
});
