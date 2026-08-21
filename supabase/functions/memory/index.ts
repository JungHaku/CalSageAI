// Voice ingest — store a standing fact without generating a reply.
//
// Typed chat remembers inside `coach` after the stream starts. Voice cannot
// wait on that function: the spoken turn is already in flight, and a second
// completion would be a bill and a delay. This endpoint is remember-only.
//
// Identity and consent are the same gates as coach. Fail closed on auth,
// fail open on store errors (204 still — the student already spoke).

import { verifyUser } from "../coach/identity.ts";
import { ingestTurn, personalMemoryFor, postgresMemoryFromEnv } from "../coach/memory.ts";
import { DEFAULT_EMBED_MODEL, OpenAIEmbedder } from "../coach/retrieval.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }
  if (req.method !== "POST") {
    return new Response("POST only", { status: 405, headers: CORS });
  }

  const user = await verifyUser(req);
  if (!user) return json({ stored: false, reason: "anonymous" }, 200);

  const backend = postgresMemoryFromEnv();
  if (!backend) return json({ stored: false, reason: "unconfigured" }, 200);

  const consented = await backend.hasCurrentConsent(user.id);
  if (!consented) return json({ stored: false, reason: "no_consent" }, 200);

  let body: { text?: string; severity?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const text = (body.text ?? "").trim();
  if (!text) return json({ stored: false, reason: "empty" }, 200);

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  const distillModel = Deno.env.get("CAL_DISTILL_MODEL");
  const embedder = apiKey && apiKey !== "sk-replace-me"
    ? new OpenAIEmbedder(apiKey, Deno.env.get("CAL_EMBED_MODEL") ?? DEFAULT_EMBED_MODEL)
    : null;
  const memory = personalMemoryFor(user, backend, embedder);
  const stored = await ingestTurn(memory, text, body.severity, {
    apiKey: apiKey && apiKey !== "sk-replace-me" ? apiKey : "",
    distillModel: distillModel || undefined,
  }).catch((error) => {
    console.error("memory ingest failed:", error);
    return false;
  });

  return json({ stored });
});
