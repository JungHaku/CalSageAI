#!/bin/bash
# Point the *hosted* Supabase Auth mailer at Resend SMTP.
#
# Dashboard equivalent: Authentication → Email → SMTP Settings.
# This script exists so the values are not typed into a form that nobody can
# review. It does not commit a key.
#
# Prerequisites:
#   1. A Resend API key (https://resend.com/api-keys)
#   2. A verified domain in Resend (https://resend.com/domains)
#      `onboarding@resend.dev` only delivers to the Resend account owner.
#   3. `npx supabase login` (or SUPABASE_ACCESS_TOKEN)
#
# Usage:
#   export RESEND_API_KEY=re_...
#   ./tools/configure-resend-smtp.sh cal@your-verified-domain.com
#
set -euo pipefail
cd "$(dirname "$0")/.."

FROM="${1:-}"
if [ -z "$FROM" ] || [ -z "${RESEND_API_KEY:-}" ]; then
    echo "Usage: RESEND_API_KEY=re_... $0 cal@your-verified-domain.com" >&2
    echo "" >&2
    echo "Or set it in the dashboard:" >&2
    echo "  https://supabase.com/dashboard/project/woudmxksrkrzjnmlfven/auth/smtp" >&2
    echo "  Host     smtp.resend.com" >&2
    echo "  Port     465" >&2
    echo "  User     resend" >&2
    echo "  Password your Resend API key" >&2
    echo "  Sender   an address on a domain you verified in Resend" >&2
    exit 1
fi

REF="$(cat supabase/.temp/project-ref 2>/dev/null || true)"
if [ -z "$REF" ]; then
    echo "FAIL: no linked project (supabase/.temp/project-ref)" >&2
    exit 1
fi

TOKEN="${SUPABASE_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.supabase/access-token" ]; then
    TOKEN="$(cat "$HOME/.supabase/access-token")"
fi
if [ -z "$TOKEN" ]; then
    echo "FAIL: log in first (\`npx supabase login\`) or export SUPABASE_ACCESS_TOKEN" >&2
    exit 1
fi

echo "PATCH auth SMTP on $REF  from=$FROM"

curl -sS -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 - <<PY
import json, os
print(json.dumps({
    "external_email_enabled": True,
    "smtp_host": "smtp.resend.com",
    "smtp_port": "465",
    "smtp_user": "resend",
    "smtp_pass": os.environ["RESEND_API_KEY"],
    "smtp_admin_email": "$FROM",
    "smtp_sender_name": "C.A.L",
}))
PY
)" | python3 -c '
import json, sys
body = sys.stdin.read()
try:
    data = json.loads(body)
except json.JSONDecodeError:
    print(body)
    sys.exit(1)
# Never print the password if the API echoes config back.
for key in ("smtp_pass", "smtp_pass_encrypted"):
    if key in data:
        data[key] = "(set)"
print(json.dumps({k: data[k] for k in data if k.startswith("smtp_") or k == "external_email_enabled"}, indent=2))
'

echo ""
echo "Done. Raise the email rate limit if Auth still caps at 30/hour:"
echo "  https://supabase.com/dashboard/project/$REF/auth/rate-limits"
echo "Then create a new account in the app (an existing unconfirmed user will"
echo "not get a second signup mail — delete them in Authentication → Users first)."
