#!/usr/bin/env python3
"""Embed `content/corpus.jsonl` and upsert it into Supabase pgvector.

    ./tools/embed-corpus.py --dry-run     # what would change, costs nothing
    ./tools/embed-corpus.py --verify      # is every stored row reachable? costs nothing
    ./tools/embed-corpus.py --rebuild     # truncate the table and re-seed it
    ./tools/embed-corpus.py               # embed, upsert, and verify

Reads keys from supabase/functions/.env — the same gitignored file the Edge
Function uses, so there is exactly one place a key lives (§10, .env.example).

Only chunks whose text has actually changed are re-embedded. The hash of each
chunk's text is stored on the row, so a re-run after editing one practice pays
for one practice.

Uses only the standard library.
"""

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed_corpus_lib import (  # noqa: E402
    CORPUS, EMBED_MODEL,
    embed, existing_hashes, match_content_chunks, parse_vector,
    resolve_key, resolve_supabase, stored_chunks, truncate_content_chunks,
    upsert_chunks,
)


# Well under OpenAI's per-request input cap, and small enough that a failure
# costs one batch rather than the run.
BATCH = 96


def chunk_hash(chunk):
    """Covers both the embedded text and the stored document.

    They are different for places — see `build-content-corpus.py` — and a change
    to either has to reach the table. Hashing only the embedded text would leave
    a corrected location sitting in the corpus file and never shipped.
    """
    payload = chunk["text"] + "\x00" + chunk.get("document", chunk["text"])
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def chunk_kind(chunk):
    return chunk.get("metadata", {}).get("kind") or chunk["id"].split(":", 1)[0]


def main():
    dry_run = "--dry-run" in sys.argv
    force = "--force" in sys.argv
    verify_only = "--verify" in sys.argv
    rebuild = "--rebuild" in sys.argv

    if not CORPUS.exists():
        sys.exit("FAIL: %s missing — run ./tools/build-content-corpus.py" % CORPUS)
    chunks = [json.loads(line) for line in CORPUS.read_text().splitlines() if line.strip()]

    supabase_url, service_key = resolve_supabase()

    if rebuild:
        truncate_content_chunks(supabase_url, service_key)
        print("truncated content_chunks")

    if verify_only:
        print("table content_chunks @ %s" % supabase_url)
        verify(supabase_url, service_key, chunks)
        return

    stored = {} if (force or rebuild) else existing_hashes(supabase_url, service_key)

    pending = [c for c in chunks if stored.get(c["id"]) != chunk_hash(c)]
    unchanged = len(chunks) - len(pending)

    print("table content_chunks @ %s" % supabase_url)
    print("  %d chunks in corpus, %d unchanged, %d to embed" % (len(chunks), unchanged, len(pending)))

    if not pending:
        print("nothing to do")
        verify(supabase_url, service_key, chunks)
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
        rows = [
            {
                "id": chunk["id"],
                "kind": chunk_kind(chunk),
                "text": chunk.get("document", chunk["text"]),
                "text_hash": chunk_hash(chunk),
                "embedding": vector,
            }
            for chunk, vector in zip(batch, vectors)
        ]
        upsert_chunks(supabase_url, service_key, rows)
        print("  upserted %d/%d" % (min(start + BATCH, len(pending)), len(pending)))

    print("done — verifying")
    verify(supabase_url, service_key, chunks)


def verify(supabase_url, service_key, chunks):
    """Fail when a stored row is not its own nearest neighbour.

    pgvector's HNSW index is approximate, but at this corpus size a record is
    its own nearest neighbour at distance 0 if it is in the index at all.
    """
    stored = stored_chunks(supabase_url, service_key)
    if not stored:
        print("index empty — nothing to verify")
        return

    missing = []
    for row in stored:
        kind = row.get("kind") or row["id"].split(":", 1)[0]
        try:
            vector = parse_vector(row["embedding"])
        except (TypeError, json.JSONDecodeError, KeyError):
            missing.append(row["id"])
            continue
        hits = match_content_chunks(supabase_url, service_key, vector, [kind], 1)
        if not hits or hits[0]["id"] != row["id"]:
            missing.append(row["id"])

    if missing:
        print("WARNING: %d chunk(s) are stored but not returned as self-nearest:" % len(missing))
        for chunk_id in missing[:10]:
            print("    %s" % chunk_id)
        print("")
        print("Rebuild the table:")
        print("    ./tools/embed-corpus.py --rebuild")
        sys.exit(1)

    expected = {chunk["id"] for chunk in chunks}
    present = {row["id"] for row in stored}
    extra = present - expected
    absent = expected - present
    if extra or absent:
        print("WARNING: table and corpus.jsonl disagree")
        if absent:
            print("  missing from table: %d" % len(absent))
        if extra:
            print("  extra in table: %d" % len(extra))
        sys.exit(1)

    print("index verified: all %d chunks are reachable by query" % len(stored))


if __name__ == "__main__":
    main()
