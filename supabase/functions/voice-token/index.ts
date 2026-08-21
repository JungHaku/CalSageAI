// Cal — the voice session opener.
//
// The only reason this exists: an iOS binary cannot hold an API key. An `.ipa` is
// a zip and strings come out of it in minutes, so a shipped key is one a stranger
// can spend on our account (ARCHITECTURE.md §8.1). This holds the ElevenLabs key
// and hands the phone short-lived credentials instead.
//
// Two transports, same function:
//   - `token`         — WebRTC conversation token (device voice path)
//   - `signed_url`    — signed WebSocket URL (text-only; Simulator uses this
//                       because LiveKit WebRTC times out on the sim)
//
// Voice uses WebRTC (ElevenLabs Swift SDK / LiveKit). That path needs a
// conversation token from `/v1/convai/conversation/token`. Signed URLs are
// text-only in the SDK.
//
// It is NOT folded into `coach`, for the reason that function's own header gives:
// different cadence, different failure mode. A voice outage must not take typed
// chat down with it, and typed chat is the fallback the whole voice-first design
// leans on when the microphone or the network is missing.
//
// Why a token rather than a public agent id: a public agent is one anyone can
// talk to, for as long as they like, on our bill. `PLAN-voice-first.md` §8
// records that there is still no budget enforcement, no rate limit and no kill
// switch anywhere in this stack — which makes the difference between a demo and
// an open tap about thirty lines, and this is them.
//
// Run it:
//   supabase functions serve --env-file supabase/functions/.env --no-verify-jwt
//
// ⚠️ Still missing, and deliberately named rather than quietly absent:
//   - per-user session budgets. Anyone who can reach this can open sessions.
//   - a kill switch. Turning voice off today means undeploying this.
//   - session length caps. The client enforces one; the client is not a control.
// None of that is needed to put Cal in front of Dr. Mia. All of it is needed
// before a student who is not in the room uses this.

const ELEVENLABS_API_KEY = Deno.env.get("ELEVENLABS_API_KEY");
const AGENT_ID = Deno.env.get("ELEVENLABS_AGENT_ID");

const CONVERSATION_TOKEN_ENDPOINT =
  "https://api.elevenlabs.io/v1/convai/conversation/token";
const SIGNED_URL_ENDPOINT =
  "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url";

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

async function elevenFetch(url: string): Promise<Response> {
  return await fetch(`${url}?agent_id=${encodeURIComponent(AGENT_ID!)}`, {
    headers: { "xi-api-key": ELEVENLABS_API_KEY! },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  // Misconfiguration is ours, not the student's. It is reported as a distinct
  // failure so the app can say "Cal's voice isn't available" rather than
  // "check your connection" — `VoiceFailure.authenticationFailed` and
  // `.offline` are different sentences to a person, and guessing wrong sends
  // someone to fiddle with their wifi over a missing environment variable.
  if (!ELEVENLABS_API_KEY || !AGENT_ID) {
    console.error("voice-token: ELEVENLABS_API_KEY or ELEVENLABS_AGENT_ID is unset");
    return json({ error: "voice_unconfigured" }, 503);
  }

  // Mint both credentials in parallel. The phone picks: WebRTC token on device,
  // signed WebSocket URL on Simulator (LiveKit times out there).
  let tokenResponse: Response;
  let signedResponse: Response;
  try {
    [tokenResponse, signedResponse] = await Promise.all([
      elevenFetch(CONVERSATION_TOKEN_ENDPOINT),
      elevenFetch(SIGNED_URL_ENDPOINT),
    ]);
  } catch (error) {
    console.error("voice-token: could not reach ElevenLabs", error);
    return json({ error: "voice_unavailable" }, 502);
  }

  if (!tokenResponse.ok) {
    console.error(
      "voice-token: token endpoint returned",
      tokenResponse.status,
      await tokenResponse.text(),
    );
    return json({ error: "voice_unavailable" }, 502);
  }
  if (!signedResponse.ok) {
    console.error(
      "voice-token: signed-url endpoint returned",
      signedResponse.status,
      await signedResponse.text(),
    );
    return json({ error: "voice_unavailable" }, 502);
  }

  const tokenBody = await tokenResponse.json();
  const signedBody = await signedResponse.json();
  const token = tokenBody?.token;
  const signedUrl = signedBody?.signed_url;

  if (typeof token !== "string" || token.length === 0) {
    console.error("voice-token: no token in the response", tokenBody);
    return json({ error: "voice_unavailable" }, 502);
  }
  if (typeof signedUrl !== "string" || signedUrl.length === 0) {
    console.error("voice-token: no signed_url in the response", signedBody);
    return json({ error: "voice_unavailable" }, 502);
  }

  // Short-lived credentials only. Nothing else from ElevenLabs is forwarded.
  return json({ token, signed_url: signedUrl });
});
