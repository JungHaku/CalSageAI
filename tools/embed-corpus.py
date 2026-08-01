#!/usr/bin/env python3
"""Embed `content/corpus.jsonl` and upsert it into Chroma.

    ./tools/embed-corpus.py --dry-run     # what would change, costs nothing
    ./tools/embed-corpus.py               # embed and upsert

Reads the key from supabase/functions/.env — the same gitignored file the Edge
Function uses, so there is exactly one place a key lives (§10, .env.example).

Only chunks whose text has actually changed are re-embedded. The hash of each
chunk's text rides along in its Chroma metadata, so a re-run after editing one
practice pays for one practice. Deliberate: the alternative is that nobody runs
this because they are not sure what it costs.

Uses only the standard library. The chromadb and openai packages would both work
and neither is worth a dependency for two POSTs.
"""

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed_corpus_lib import (  # noqa: E402
    CORPUS, COLLECTION, EMBED_MODEL,
    collections_url, embed, ensure_collection, get, post, resolve_key,
)

# Well under OpenAI's per-request input cap, and small enough that a failure
# costs one batch rather than the run.
BATCH = 96


def existing_hashes(collection_id):
    """Chunk id -> text hash already stored, so unchanged chunks are skipped."""
    result = post(
        "%s/%s/get" % (collections_url(), collection_id),
        {"include": ["metadatas"], "limit": 100_000},
    )
    ids = result.get("ids") or []
    metadatas = result.get("metadatas") or []
    return {
        chunk_id: (metadata or {}).get("textHash")
        for chunk_id, metadata in zip(ids, metadatas)
    }


def chunk_hash(chunk):
    """Covers both the embedded text and the stored document.

    They are different for places — see `build-content-corpus.py` — and a change
    to either has to reach Chroma. Hashing only the embedded text would leave a
    corrected location sitting in the corpus file and never shipped.
    """
    payload = chunk["text"] + "\x00" + chunk.get("document", chunk["text"])
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def main():
    dry_run = "--dry-run" in sys.argv
    force = "--force" in sys.argv

    if not CORPUS.exists():
        sys.exit("FAIL: %s missing — run ./tools/build-content-corpus.py" % CORPUS)
    chunks = [json.loads(line) for line in CORPUS.read_text().splitlines() if line.strip()]

    collection_id = ensure_collection()
    stored = {} if force else existing_hashes(collection_id)

    pending = [c for c in chunks if stored.get(c["id"]) != chunk_hash(c)]
    unchanged = len(chunks) - len(pending)

    print("collection %s (%s)" % (COLLECTION, collection_id))
    print("  %d chunks in corpus, %d unchanged, %d to embed" % (len(chunks), unchanged, len(pending)))

    if not pending:
        print("nothing to do")
        return
    if dry_run:
        approximate_tokens = sum(len(c["text"]) for c in pending) // 4
        print("  ~%d tokens with %s" % (approximate_tokens, EMBED_MODEL))
        for chunk in pending[:10]:
            print("    %s" % chunk["id"])
        if len(pending) > 10:
            print("    ... and %d more" % (len(pending) - 10))
        print("dry run — nothing embedded, nothing spent")
        return

    api_key = resolve_key()

    for start in range(0, len(pending), BATCH):
        batch = pending[start : start + BATCH]
        # Embeds `text`, stores `document`. For places those differ: the
        # location is what Cal needs to read but would dilute the name signal if
        # it were part of the vector.
        vectors = embed([c["text"] for c in batch], api_key)
        post(
            "%s/%s/upsert" % (collections_url(), collection_id),
            {
                "ids": [c["id"] for c in batch],
                "embeddings": vectors,
                "documents": [c.get("document", c["text"]) for c in batch],
                "metadatas": [
                    dict(c["metadata"], textHash=chunk_hash(c), contentVersion=c["contentVersion"])
                    for c in batch
                ],
            },
        )
        print("  upserted %d/%d" % (min(start + BATCH, len(pending)), len(pending)))

    count = get("%s/%s/count" % (collections_url(), collection_id))
    print("done — collection now holds %s chunks" % count)


if __name__ == "__main__":
    main()
