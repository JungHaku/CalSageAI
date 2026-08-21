#!/bin/bash
# Regenerates the voice agent's configuration from its sources.
#
# Edit `docs/PROMPT-cal.md`, `docs/PROMPT-cal-voice.md`,
# `elevenlabs/agent.settings.json` or `CalToolDescriptor.all`, then run this.
#
# Same bargain as `sync-prompt.sh`: the reviewable text is canonical and the
# deployed artifact is generated from it, because a prompt review is worthless if
# the reviewed text is not the text that runs. The voice path adds a second thing
# that must not drift — the tool schema, which is the list of what Cal may do to
# a student's app and their data. That is generated too, out of the same Swift
# descriptors `CalTool.init` validates against, so the agent can never be told
# about a tool the app will reject.
#
# No network, no key, no cost. Deploying is `./tools/deploy-agent.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build first, so a compile error is a compile error rather than empty JSON
# silently becoming the agent's entire tool list.
TOOLS_ERR="$(mktemp)"
trap 'rm -f "$TOOLS_ERR"' EXIT
if ! TOOLS_JSON="$(swift run --package-path Packages/CalVoice CalAgentTools 2>"$TOOLS_ERR")"; then
    echo "FAIL: could not render the tool schema" >&2
    cat "$TOOLS_ERR" >&2
    exit 1
fi

TOOLS_JSON="$TOOLS_JSON" python3 - <<'PY'
import json, os, pathlib, re, sys


def fenced(path):
    """The reviewable prompt text and the version it is filed under."""
    text = pathlib.Path(path).read_text()
    block = re.search(r"```\n(.*?)\n```", text, re.S)
    if not block:
        sys.exit(f"FAIL: no fenced prompt block in {path}")
    version = re.search(r"\*\*Version:\*\*\s*`([^`]+)`", text)
    if not version:
        sys.exit(f"FAIL: no '**Version:** `...`' line in {path}")
    return block.group(1), version.group(1)


base, base_version = fenced("docs/PROMPT-cal.md")
voice, voice_version = fenced("docs/PROMPT-cal-voice.md")

tools = json.loads(os.environ["TOOLS_JSON"])
if not tools:
    sys.exit("FAIL: the tool schema is empty")

config = json.loads(pathlib.Path("elevenlabs/agent.settings.json").read_text())

# The addendum is appended, never merged. It is a diff against Cal's character,
# and the character has to arrive first or the model reads the voice rules as the
# whole brief.
prompt = config["conversation_config"]["agent"]["prompt"]
if "prompt" in prompt or "tools" in prompt:
    sys.exit(
        "FAIL: agent.settings.json must not contain 'prompt' or 'tools' under\n"
        "      conversation_config.agent.prompt — those are generated, and a\n"
        "      hand-written copy is exactly the drift this script exists to stop."
    )
prompt["prompt"] = base + "\n\n" + voice
prompt["tools"] = tools

pathlib.Path("elevenlabs/agent.json").write_text(
    json.dumps(config, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
)
print(
    "synced elevenlabs/agent.json — %s + %s, %d chars, %d tools"
    % (base_version, voice_version, len(prompt["prompt"]), len(tools))
)
PY
