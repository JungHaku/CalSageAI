#!/bin/bash
# Fails if the prompt Dr. Mia reviews has drifted from the one that runs.
#
# Not bureaucracy. A prompt review is only worth something if the reviewed text
# is the deployed text, and these are two files that a hurried edit can separate
# without either looking wrong.
#
# Checks the version too. A changed prompt filed under an unchanged version is
# the subtler failure of the two: nothing looks wrong anywhere, and every
# `promptVersion` in `ai_usage` quietly stops meaning anything.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, re, sys
md = pathlib.Path("docs/PROMPT-cal.md").read_text()
ts = pathlib.Path("supabase/functions/coach/prompt.ts").read_text()

block = re.search(r"```\n(.*?)\n```", md, re.S)
if not block:
    sys.exit("FAIL: no fenced prompt block in docs/PROMPT-cal.md")
reviewed = block.group(1)

running = re.search(r"CAL_SYSTEM_PROMPT = `(.*)`;\s*$", ts, re.S)
if not running:
    sys.exit("FAIL: could not read the prompt out of prompt.ts")
running = running.group(1).replace("\\`", "`").replace("\\${", "${").replace("\\\\", "\\")

if reviewed != running:
    sys.exit(
        "FAIL: the reviewed prompt and the running prompt have drifted.\n"
        "      docs/PROMPT-cal.md is canonical — run ./tools/sync-prompt.sh"
    )

declared = re.search(r"\*\*Version:\*\*\s*`([^`]+)`", md)
if not declared:
    sys.exit("FAIL: no '**Version:** `cal-vN`' line in docs/PROMPT-cal.md")
shipped = re.search(r'PROMPT_VERSION = "([^"]+)"', ts)
if not shipped:
    sys.exit("FAIL: could not read PROMPT_VERSION out of prompt.ts")
if declared.group(1) != shipped.group(1):
    sys.exit(
        "FAIL: the document declares %s but the function reports %s.\n"
        "      Run ./tools/sync-prompt.sh" % (declared.group(1), shipped.group(1))
    )

print("OK: reviewed and running prompts match (%d chars, %s)" % (len(reviewed), declared.group(1)))
PY
