// What is worth remembering, and in what form (M3).
//
// M2 stored every acceptable turn verbatim, and the live test showed the cost
// immediately: asking "what did I tell you about my roommate?" filed the
// *question* as a memory. Ask it twice and the store fills with a student
// interrogating Cal about a fact, alongside the fact.
//
// Two stages, cheap first. The heuristic gate is free, deterministic and
// testable, and removes the whole class of defect above. Distillation is a model
// call and is off unless configured, because a second call per turn roughly
// doubles the per-message cost that §10.5 budgets at under $0.50/user/month.

/// Openers that make a sentence a request to Cal rather than a fact about the
/// student. Matched only at the start, so "I know where the gym is" survives
/// while "where is the gym" does not.
const INTERROGATIVE_OPENERS = [
  "what", "where", "when", "why", "how", "who", "which",
  "did", "do", "does", "is", "are", "was", "were", "can", "could",
  "will", "would", "should", "have", "has", "am",
];

/// Things said *to* Cal that describe nothing about the person.
const DIRECTIVE_OPENERS = [
  "tell me", "guide me", "walk me", "show me", "explain", "help me with",
  "can you", "could you", "please ", "remind me",
];

const PLEASANTRIES = [
  "hi", "hey", "hello", "yo", "thanks", "thank you", "ty", "ok", "okay",
  "cool", "nice", "sure", "yes", "no", "yeah", "nope", "got it", "sounds good",
  "good morning", "good night", "bye", "see you",
];

/// Below this a fragment cannot carry a fact worth recalling weeks later.
export const MIN_DURABLE_CHARS = 20;

function normalize(text: string): string {
  return text.trim().toLowerCase().replace(/\s+/g, " ");
}

/// Is this a statement about the student worth keeping?
///
/// Tuned to under-collect. A fact wrongly dropped costs one recall that never
/// happens; a question wrongly kept becomes noise that competes with real
/// memories forever, and — because this is health data — every stored row is
/// also a row that has to be disclosed, exported and deleted. When in doubt,
/// do not keep it.
export function isDurable(text: string): boolean {
  const normalized = normalize(text);
  if (normalized.length < MIN_DURABLE_CHARS) return false;

  // A question is a request for information, not information.
  if (normalized.endsWith("?")) return false;

  const firstWord = normalized.split(" ")[0].replace(/[^a-z']/g, "");
  if (INTERROGATIVE_OPENERS.includes(firstWord)) return false;

  if (DIRECTIVE_OPENERS.some((opener) => normalized.startsWith(opener))) return false;

  // Pleasantries, allowing for trailing punctuation and an emoji or two.
  const stripped = normalized.replace(/[^a-z ]/g, "").trim();
  if (PLEASANTRIES.includes(stripped)) return false;

  return true;
}

/// A first-person fact, or `null` if the model decided there was nothing durable.
///
/// Off by default — see `CAL_DISTILL_MODEL`. When enabled it turns a turn into
/// something worth recalling months later: "my roommate keeps having loud people
/// over past midnight and I cannot sleep" becomes a standing fact rather than a
/// sentence in the present tense that may not be true tomorrow.
///
/// Fails to `null` rather than to the raw text. Falling back to raw would mean a
/// model outage silently changes what is stored, and the store is the thing we
/// have to be able to describe accurately in a privacy policy.
export async function distill(
  text: string,
  options: { apiKey: string; model: string; fetchImpl?: typeof fetch },
): Promise<string | null> {
  const doFetch = options.fetchImpl ?? fetch;
  try {
    const response = await doFetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${options.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: options.model,
        // 60 was too tight and it failed silently. On a reasoning model the
        // budget covers reasoning tokens as well as the reply, so a short cap
        // can be spent entirely before a single visible character is emitted —
        // the call succeeds, `content` is empty, and nothing is stored. Found by
        // sending five messages and getting one memory.
        max_completion_tokens: 400,
        messages: [
          {
            role: "system",
            content: [
              "Rewrite the student's message as one short standing fact about",
              "them, in the third person, that would still be worth knowing in a",
              "month. Keep names and specifics. Do not add anything they did not",
              "say. Do not give advice.",
              "",
              "If the message contains no durable fact — a question, a greeting,",
              "a passing mood, a request — reply with exactly: NONE",
            ].join("\n"),
          },
          { role: "user", content: text },
        ],
      }),
    });
    // Every path out of here that stores nothing says so. Silence was how the
    // first version lost two memories out of five with no sign anything had
    // happened: `!response.ok` returned null without a word, and an empty
    // completion was indistinguishable from a deliberate NONE.
    if (!response.ok) {
      console.error(
        `distillation ${response.status}, storing nothing: ` +
          (await response.text().catch(() => "")).slice(0, 200),
      );
      return null;
    }

    const json = await response.json();
    const distilled = (json.choices?.[0]?.message?.content ?? "").trim();
    if (!distilled) {
      console.error(
        "distillation returned no content, storing nothing " +
          `(finish_reason=${json.choices?.[0]?.finish_reason ?? "?"})`,
      );
      return null;
    }
    if (distilled.toUpperCase().startsWith("NONE")) {
      console.log("distillation found nothing durable");
      return null;
    }
    return distilled;
  } catch (error) {
    console.error("distillation failed, storing nothing:", error);
    return null;
  }
}
