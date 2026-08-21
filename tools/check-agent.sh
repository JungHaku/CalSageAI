#!/bin/bash
# Fails if the agent Dr. Mia reviews has drifted from the agent that would be
# deployed.
#
# Two failures this catches, both silent otherwise:
#
#   1. The prompt was edited and the agent was not regenerated. Cal then sounds
#      like a version of himself nobody signed off, and the file that was
#      reviewed describes someone else.
#   2. A tool was added, renamed, or had its arguments changed in Swift, and the
#      agent still has the old schema. That one has no symptom at all — Cal calls
#      a tool, the app rejects it, and the screen simply does not move.
#
# Regenerates into a temp file and diffs. No network, no key, no cost; safe to
# run in CI and cheap enough to run before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f elevenlabs/agent.json ]]; then
    echo "FAIL: elevenlabs/agent.json does not exist — run ./tools/sync-agent.sh" >&2
    exit 1
fi

BEFORE="$(mktemp)"
trap 'rm -f "$BEFORE"' EXIT
cp elevenlabs/agent.json "$BEFORE"

# Regenerate in place, then compare and restore. Restoring matters: a check that
# leaves the working tree modified is a check people stop running.
./tools/sync-agent.sh >/dev/null

if ! diff -q "$BEFORE" elevenlabs/agent.json >/dev/null; then
    diff -u "$BEFORE" elevenlabs/agent.json | head -60 || true
    cp "$BEFORE" elevenlabs/agent.json
    echo >&2
    echo "FAIL: elevenlabs/agent.json is stale." >&2
    echo "      The prompts and CalToolDescriptor are canonical — run ./tools/sync-agent.sh" >&2
    exit 1
fi

python3 - <<'PY'
import json, pathlib

config = json.loads(pathlib.Path("elevenlabs/agent.json").read_text())
prompt = config["conversation_config"]["agent"]["prompt"]
print(
    "OK: agent.json matches its sources (%d chars, %d tools)"
    % (len(prompt["prompt"]), len(prompt["tools"]))
)
PY
