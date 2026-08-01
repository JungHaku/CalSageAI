#!/bin/bash
# Fails if the retrieval corpus has drifted from the content it was built from.
#
# Same argument as check-prompt.sh. These chunks are what Cal is handed as ground
# truth about Dr. Mia's practices, so if she edits a script and nobody rebuilds,
# the app plays the new words while Cal recites the old ones — and neither file
# looks wrong on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./tools/build-content-corpus.py --check
