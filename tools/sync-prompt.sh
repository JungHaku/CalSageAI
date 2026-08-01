#!/bin/bash
# Regenerates the Edge Function's prompt from the reviewable markdown.
# Edit docs/PROMPT-cal.md, then run this.
#
# The version is read from the document too, rather than hardcoded here. It is
# declared once, in the file Dr. Mia reads, so a bump is a one-line edit instead
# of something you have to remember to do in a second place. A prompt that
# changed while its version did not would make every `promptVersion` recorded in
# `ai_usage` a lie — two different Cals filed under one name.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, re, sys
md = pathlib.Path("docs/PROMPT-cal.md").read_text()

block = re.search(r"```\n(.*?)\n```", md, re.S)
if not block:
    sys.exit("FAIL: no fenced prompt block in docs/PROMPT-cal.md")
prompt = block.group(1)

declared = re.search(r"\*\*Version:\*\*\s*`([^`]+)`", md)
if not declared:
    sys.exit("FAIL: no '**Version:** `cal-vN`' line in docs/PROMPT-cal.md")
version = declared.group(1)

header = pathlib.Path("supabase/functions/coach/prompt.ts").read_text().split("export const PROMPT_VERSION")[0]
escaped = prompt.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
pathlib.Path("supabase/functions/coach/prompt.ts").write_text(
    header + 'export const PROMPT_VERSION = "' + version + '";\n\n'
    + "export const CAL_SYSTEM_PROMPT = `" + escaped + "`;\n"
)
print(f"synced {len(prompt)} chars as {version}")
PY
