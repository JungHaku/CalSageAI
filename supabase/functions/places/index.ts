// Cal — campus place search.
//
// Deliberately NOT the coach. A student typing "where's the gym" wants pins on a
// map, and retrieval alone answers that: embed the query, ask the vector store,
// return slugs. Routing it through a chat completion would add a model's latency
// and cost to produce prose the Navigate screen does not display.
//
// So this endpoint spends one embedding call — a rounding error — and returns
// JSON rather than a stream.
//
// It returns slugs, never place data. The client already has all 231 places
// bundled and resolves them locally, which keeps the coordinates it renders the
// same ones its map and its offline search use. One source of truth for where a
// building is.
//
// Run it:
//   supabase functions serve --env-file supabase/functions/.env --no-verify-jwt

import {
  DEFAULT_EMBED_MODEL,
  OpenAIEmbedder,
  postgresVectorStoreFromEnv,
  retrieve,
} from "../coach/retrieval.ts";

const EMBED_MODEL = Deno.env.get("CAL_EMBED_MODEL") ?? DEFAULT_EMBED_MODEL;

/// More than a phone screen shows at once, and few enough that the tail is still
/// plausibly relevant.
const DEFAULT_LIMIT = 8;
const MAX_LIMIT = 20;

const vectorStore = postgresVectorStoreFromEnv();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-cache" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  let body: { query?: string; limit?: number };
  try {
    body = await req.json();
  } catch {
    return new Response("bad JSON", { status: 400 });
  }

  const query = (body.query ?? "").trim();
  if (!query) return json({ places: [] });

  const limit = Math.min(Math.max(body.limit ?? DEFAULT_LIMIT, 1), MAX_LIMIT);

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  const configured = apiKey && apiKey !== "sk-replace-me" && vectorStore;

  // An unconfigured deployment answers "no matches", not an error. The client
  // falls back to its own offline search, which is the path that has to work on
  // a bus anyway — so a missing key degrades this to exactly the behaviour the
  // app had before semantic search existed.
  if (!configured) {
    console.warn("place search is not configured; returning no matches");
    return json({ places: [] });
  }

  const hits = await retrieve({
    surface: "navigate",
    query,
    embedder: new OpenAIEmbedder(apiKey!, EMBED_MODEL),
    store: vectorStore,
    k: limit,
  });

  return json({
    places: hits
      // Ids are "place:<slug>"; the client keys off the bare slug.
      .filter((hit) => hit.id.startsWith("place:"))
      .map((hit) => hit.id.slice("place:".length)),
  });
});
