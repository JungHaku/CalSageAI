# Cal's voice agent

The agent is a file, not a dashboard.

An agent built by clicking around ElevenLabs' web UI has two problems that matter
more here than they would elsewhere. `docs/PROMPT-cal.md` stops being the prompt
Cal actually uses, so the thing Dr. Mia reviews and the thing students hear are
only related by memory. And the tool schema — the list of what Cal is allowed to
do to someone's app and their data — becomes text on a web page that nobody can
diff, review, or roll back.

So: edit the sources, regenerate, deploy.

| File | Who owns it |
|---|---|
| `docs/PROMPT-cal.md` | Dr. Mia. Cal's character, unchanged from the text path. |
| `docs/PROMPT-cal-voice.md` | Dr. Mia. Only what changes when Cal is spoken. |
| `Packages/CalVoice` `CalToolDescriptor.all` | Engineering. What Cal can do. |
| `elevenlabs/agent.settings.json` | Engineering. Voice, model, turn-taking. |
| **`elevenlabs/agent.json`** | **Generated. Do not edit.** |

## The three commands

```bash
./tools/sync-agent.sh     # regenerate agent.json from the sources. No network.
./tools/check-agent.sh    # fail if agent.json is stale. No network.
./tools/deploy-agent.sh   # push it to ElevenLabs. Needs a key. Costs money.
```

The split is deliberate. The first two are free, offline and safe to run in CI;
the third creates or mutates a resource on a paid account, so it is a separate
thing you type on purpose.

## Before the first deploy

1. **Pick a voice.** `voice_id` in `agent.settings.json` is `REPLACE_ME`, and
   `deploy-agent.sh` refuses to run until it isn't. Creating Cal with whatever
   voice happened to be first in a list is not a decision anyone should make by
   accident — Cal's voice is a product decision, not a deploy default.
2. **Export a key**: `export ELEVENLABS_API_KEY=...`. It is never committed and
   never reaches the app — the phone gets a short-lived signed URL from the
   `voice-token` Edge Function instead (`PLAN-voice-first.md` §8, and §8.1's
   argument that an `.ipa` is a zip).
3. Run `./tools/deploy-agent.sh`. It writes the new agent's id to
   `elevenlabs/agent-id.txt` and a record of what was deployed to
   `elevenlabs/deployed.json`.

## When the API shape is wrong

The envelope in `agent.settings.json` and the tool schema in
`AgentSchema.swift` are ElevenLabs' formats, and they are ElevenLabs' to change.
If a deploy comes back 4xx, the response body is printed verbatim — the fix is
almost certainly in one of those two places, and never in `CalTool` or the
descriptors, which are the app's own contract.
