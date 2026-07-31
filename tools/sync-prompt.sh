#!/bin/bash
# Regenerates the Edge Function's prompt from the reviewable markdown.
# Edit docs/PROMPT-cal-v1.md, then run this.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, re
md = pathlib.Path("docs/PROMPT-cal-v1.md").read_text()
block = re.search(r"```\n(.*?)\n```", md, re.S)
assert block, "no fenced prompt block in docs/PROMPT-cal-v1.md"
prompt = block.group(1)
header = pathlib.Path("supabase/functions/coach/prompt.ts").read_text().split("export const PROMPT_VERSION")[0]
escaped = prompt.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
pathlib.Path("supabase/functions/coach/prompt.ts").write_text(
    header + 'export const PROMPT_VERSION = "cal-v1";\n\nexport const CAL_SYSTEM_PROMPT = `' + escaped + "`;\n"
)
print(f"synced {len(prompt)} chars")
PY
