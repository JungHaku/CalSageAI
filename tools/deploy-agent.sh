#!/bin/bash
# Pushes elevenlabs/agent.json to ElevenLabs — creating the agent the first time,
# updating it after.
#
# Kept separate from `sync-agent.sh` on purpose. Sync is offline, free and safe
# to run in a loop; this one mutates a resource on a paid account and changes
# what students hear. It should be something you type deliberately, not something
# that happens as a side effect of regenerating a file.
#
# Needs ELEVENLABS_API_KEY in the environment. That key never enters the app —
# an `.ipa` is a zip and a shipped key is one a stranger can spend
# (ARCHITECTURE.md §8.1). The phone gets a short-lived signed URL from the
# `voice-token` Edge Function instead.
set -euo pipefail
cd "$(dirname "$0")/.."

API="https://api.elevenlabs.io/v1/convai/agents"
ID_FILE="elevenlabs/agent-id.txt"

if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
    echo "FAIL: ELEVENLABS_API_KEY is not set." >&2
    echo "      export ELEVENLABS_API_KEY=... — see elevenlabs/README.md" >&2
    exit 1
fi

# Never deploy something that does not match its sources. Deploying a stale
# agent is how the reviewed prompt and the running prompt come apart in the one
# direction nobody notices: the repo looks right.
./tools/check-agent.sh

# A voice is a decision, not a default. Cal's voice is the most visible thing
# about him, so creating him with whatever was first in a list is not something
# this script will do quietly.
if grep -q '"voice_id": "REPLACE_ME"' elevenlabs/agent.settings.json; then
    echo "FAIL: no voice chosen." >&2
    echo "      Set voice_id in elevenlabs/agent.settings.json, then re-sync." >&2
    echo "      See PLAN-voice-first.md — this is a decision, not a placeholder." >&2
    exit 1
fi

RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

if [[ -f "$ID_FILE" ]]; then
    AGENT_ID="$(tr -d '[:space:]' < "$ID_FILE")"
    echo "updating agent $AGENT_ID"
    STATUS="$(curl -sS -o "$RESPONSE" -w '%{http_code}' -X PATCH "$API/$AGENT_ID" \
        -H "xi-api-key: $ELEVENLABS_API_KEY" \
        -H "Content-Type: application/json" \
        --data @elevenlabs/agent.json)"
else
    echo "creating a new agent"
    STATUS="$(curl -sS -o "$RESPONSE" -w '%{http_code}' -X POST "$API/create" \
        -H "xi-api-key: $ELEVENLABS_API_KEY" \
        -H "Content-Type: application/json" \
        --data @elevenlabs/agent.json)"
fi

if [[ "$STATUS" != 2* ]]; then
    echo "FAIL: ElevenLabs returned $STATUS" >&2
    echo >&2
    cat "$RESPONSE" >&2
    echo >&2
    echo "      The request envelope is ElevenLabs' shape and theirs to change." >&2
    echo "      Fix agent.settings.json or AgentSchema.swift — never CalTool." >&2
    exit 1
fi

RESPONSE="$RESPONSE" ID_FILE="$ID_FILE" python3 - <<'PY'
import json, os, pathlib, re, sys

body = json.loads(pathlib.Path(os.environ["RESPONSE"]).read_text())
id_file = pathlib.Path(os.environ["ID_FILE"])

agent_id = body.get("agent_id") or body.get("id")
if not agent_id:
    if not id_file.exists():
        sys.exit("FAIL: deployed, but the response carried no agent id:\n" + json.dumps(body)[:500])
    agent_id = id_file.read_text().strip()
id_file.write_text(agent_id + "\n")


def version(path):
    found = re.search(r"\*\*Version:\*\*\s*`([^`]+)`", pathlib.Path(path).read_text())
    return found.group(1) if found else "unknown"


# What is actually live, recorded where it can be read without an API call.
# ElevenLabs does not keep our version numbers, so if this file is not written
# nothing anywhere says which Cal is answering the phone.
pathlib.Path("elevenlabs/deployed.json").write_text(
    json.dumps(
        {
            "agent_id": agent_id,
            "prompt_version": version("docs/PROMPT-cal.md"),
            "voice_prompt_version": version("docs/PROMPT-cal-voice.md"),
        },
        indent=2,
    )
    + "\n"
)
print(f"deployed {agent_id}")
print("recorded in elevenlabs/deployed.json — commit it")
PY
