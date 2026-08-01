#!/usr/bin/env python3
"""Embed `content/corpus.jsonl` and upsert it into Chroma.

    ./tools/embed-corpus.py --dry-run     # what would change, costs nothing
    ./tools/embed-corpus.py --verify      # is the vector index intact? costs nothing
    ./tools/embed-corpus.py --rebuild     # drop the collection and re-seed it
    ./tools/embed-corpus.py               # embed, upsert, and verify

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
    collections_url, delete, embed, ensure_collection, get, post, resolve_key,
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


def indexed_ids(collection_id, sample_embedding, total):
    """The ids the *vector index* can actually return.

    Deliberately not the same question as `count`. Chroma keeps records in SQLite
    and vectors in an HNSW graph, and the two can disagree: a container killed
    before the graph is flushed keeps every row and loses part of the index. The
    collection then reports the right count, `get` returns every document, and
    only a query reveals that something is unreachable.

    Asking for more neighbours than exist returns the whole index, which is what
    makes this a single cheap call. It relies on the collection being small — at
    a few thousand chunks this should become a sampled check instead.
    """
    result = post(
        "%s/%s/query" % (collections_url(), collection_id),
        {"query_embeddings": [sample_embedding], "n_results": max(total, 1), "include": []},
    )
    return set(result["ids"][0])


def stored_records(collection_id):
    """Every id in the collection, with its embedding."""
    result = post(
        "%s/%s/get" % (collections_url(), collection_id),
        {"include": ["embeddings"], "limit": 100_000},
    )
    return result.get("ids") or [], result.get("embeddings") or []


def is_reachable(collection_id, chunk_id, embedding):
    """Does querying with a record's own vector return that record?

    The unambiguous test, and the reason the bulk scan alone is not trusted. A
    record present in the index is its own nearest neighbour at distance 0; one
    that fails this is genuinely unreachable no matter what `count` says.
    """
    result = post(
        "%s/%s/query" % (collections_url(), collection_id),
        {"query_embeddings": [embedding], "n_results": 1, "include": []},
    )
    hits = result["ids"][0]
    return bool(hits) and hits[0] == chunk_id


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

    verify_only = "--verify" in sys.argv
    rebuild = "--rebuild" in sys.argv

    if not CORPUS.exists():
        sys.exit("FAIL: %s missing — run ./tools/build-content-corpus.py" % CORPUS)
    chunks = [json.loads(line) for line in CORPUS.read_text().splitlines() if line.strip()]

    if rebuild:
        # Dropping the collection is the point: a rebuilt HNSW graph is the only
        # thing observed to restore an unreachable record.
        delete("%s/%s" % (collections_url(), COLLECTION))
        print("dropped collection %s" % COLLECTION)

    collection_id = ensure_collection()
    if verify_only:
        print("collection %s (%s)" % (COLLECTION, collection_id))
        verify(collection_id, chunks, allow_repair=False)
        return

    stored = {} if (force or rebuild) else existing_hashes(collection_id)

    pending = [c for c in chunks if stored.get(c["id"]) != chunk_hash(c)]
    unchanged = len(chunks) - len(pending)

    print("collection %s (%s)" % (COLLECTION, collection_id))
    print("  %d chunks in corpus, %d unchanged, %d to embed" % (len(chunks), unchanged, len(pending)))

    if not pending:
        print("nothing to do")
        # Still verify. This is the branch the index-integrity bug hides behind:
        # the hashes all match, so a re-run would otherwise report success and
        # look at nothing.
        verify(collection_id, chunks)
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
    verify(collection_id, chunks)


def verify(collection_id, chunks, allow_repair=True):
    """Fail, or repair, when the vector index is missing records the store has.

    This exists because the failure it catches is silent. A container stopped
    with SIGKILL — `docker rm -f`, or Docker Desktop quitting — can leave the
    HNSW graph short of its last unflushed batch while every row survives in
    SQLite. Retrieval then just quietly gets worse: `place:wheeler-hall` sat in
    the store with a full 1536-dimension embedding and could not be returned by
    any query, including one using its own vector.

    The hash check cannot see this. The hash lives in metadata, metadata is in
    SQLite, and SQLite is the half that survived — so a re-run reports "nothing
    to do" and changes nothing.
    """
    stored, embeddings = stored_records(collection_id)
    if not stored or not embeddings:
        return

    # Two passes, because one is fast and the other is correct.
    #
    # HNSW is an *approximate* index: asking it for all N neighbours does not
    # reliably return all N, because `ef_search` bounds how much of the graph a
    # query explores. So the bulk scan produces candidates, not verdicts — used
    # alone it reports healthy records at the edge of the graph as missing.
    # Each candidate is then re-checked with its own vector, which is
    # unambiguous: a record in the index is its own nearest neighbour at
    # distance 0.
    candidates = sorted(set(stored) - indexed_ids(collection_id, embeddings[0], len(stored)))
    by_id = dict(zip(stored, embeddings))
    missing = [
        chunk_id for chunk_id in candidates
        if not is_reachable(collection_id, chunk_id, by_id[chunk_id])
    ]

    if not missing:
        if candidates:
            print(
                "index verified: all %d chunks reachable "
                "(%d flagged by the bulk scan, all fine on recheck)"
                % (len(stored), len(candidates))
            )
        else:
            print("index verified: all %d chunks are reachable by query" % len(stored))
        return

    print("WARNING: %d chunk(s) are stored but missing from the vector index:" % len(missing))
    for chunk_id in missing[:10]:
        print("    %s" % chunk_id)
    print("")
    print("One or two unreachable chunks is the observed steady state for this")
    print("Chroma build at this corpus size — see the note in .env.example. It")
    print("only matters when it lands on something students search for; rebuild")
    print("if a chunk you care about is listed.")

    # Deliberately no in-place repair. Both obvious fixes were tried against a
    # genuinely unreachable record and neither worked: upserting the same id
    # updates SQLite without re-entering the graph, and delete-then-add left it
    # just as unreachable. The index has to be rebuilt.
    print("")
    print("The vector index has to be rebuilt — an upsert will not fix this:")
    print("    ./tools/embed-corpus.py --rebuild")
    if allow_repair:
        print("(re-embeds the whole corpus; a few thousandths of a cent)")


if __name__ == "__main__":
    main()
