#!/bin/bash
# Fails if the prompt Dr. Mia reviews has drifted from the one that runs.
#
# Not bureaucracy. A prompt review is only worth something if the reviewed text
# is the deployed text, and these are two files that a hurried edit can separate
# without either looking wrong.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, re, sys
md = pathlib.Path("docs/PROMPT-cal-v1.md").read_text()
ts = pathlib.Path("supabase/functions/coach/prompt.ts").read_text()

block = re.search(r"```\n(.*?)\n```", md, re.S)
if not block:
    sys.exit("FAIL: no fenced prompt block in docs/PROMPT-cal-v1.md")
reviewed = block.group(1)

running = re.search(r"CAL_SYSTEM_PROMPT = `(.*)`;\s*$", ts, re.S)
if not running:
    sys.exit("FAIL: could not read the prompt out of prompt.ts")
running = running.group(1).replace("\\`", "`").replace("\\${", "${").replace("\\\\", "\\")

if reviewed != running:
    sys.exit(
        "FAIL: the reviewed prompt and the running prompt have drifted.\n"
        "      docs/PROMPT-cal-v1.md is canonical — run ./tools/sync-prompt.sh"
    )
print(f"OK: reviewed and running prompts match ({len(reviewed)} chars)")
PY
