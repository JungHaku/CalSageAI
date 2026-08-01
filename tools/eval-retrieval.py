#!/usr/bin/env python3
"""Measure whether retrieval actually returns the right chunk.

    ./tools/eval-retrieval.py            # run the whole set
    ./tools/eval-retrieval.py --verbose  # show every result, not just misses

An embedding pipeline fails quietly: a wrong model, a truncated chunk, or a
mismatched vector still returns confident-looking neighbours. The only way to
know it works is to ask it questions with known answers.

The cases below are what a Berkeley student would plausibly type. Each names the
chunks that would be a correct hit; a case passes when at least one of them is in
the top `k`. Expectations are set to what the *data* can support — see the
`place` cases, which are deliberately name-shaped, because the categories behind
them are keyword-derived and about 59% fall through to "Other"
(ARCHITECTURE §17 item 14).

Costs one embedding per query — a few thousandths of a cent for the set.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from embed_corpus_lib import chroma_query, collections_url, ensure_collection, embed, resolve_key  # noqa: E402

K = 4

# (surface, query, [chunk ids that count as correct])
CASES = [
    # --- chat: the coherence framework and Dr. Mia's practices ---
    ("chat", "I can't stop thinking, my mind is everywhere",
     ["question:presence", "practice:presence-of-light"]),
    ("chat", "my chest feels tight and I can't take a full breath",
     ["question:breath"]),
    ("chat", "I feel so disconnected from everyone here",
     ["question:connection", "practice:microcosm-macrocosm-breath"]),
    ("chat", "I have zero energy today, I'm running on empty",
     ["question:energy", "practice:solar-plexus-light"]),
    ("chat", "I keep reacting automatically instead of choosing",
     ["question:choice", "practice:sovereignty-reflection"]),
    ("chat", "I don't feel safe in my own body",
     ["question:safety"]),
    ("chat", "I can't tell what I actually want anymore",
     ["question:inner_knowing"]),
    ("chat", "I hide what I really think around my friends",
     ["question:authentic_expression"]),
    ("chat", "my emotions feel stuck and overwhelming",
     ["question:emotional_flow", "practice:golden-spark-visualization"]),
    ("chat", "can you walk me through the golden spark practice",
     ["practice:golden-spark-visualization"]),
    ("chat", "guide me through solar plexus light",
     ["practice:solar-plexus-light"]),
    ("chat", "I just finished studying and need to reset",
     ["practice:study-reset"]),

    # --- navigate: campus places ---
    ("navigate", "where is Wheeler Hall", ["place:wheeler-hall"]),
    ("navigate", "how do I get to Doe library", ["place:doe-memorial-library"]),
    ("navigate", "where's Moffitt", ["place:moffitt-library"]),
    ("navigate", "where is the Tang Center", ["place:tang-center"]),
    ("navigate", "where's the gym", ["place:recreational-sports-facility", "place:hearst-memorial-gymnasium"]),
    ("navigate", "where can I park my car",
     ["place:bancroft-parking-structure", "place:ellsworth-parking-structure",
      "place:lower-hearst-parking-structure", "place:parking-and-transportation"]),

    # --- questions the corpus cannot answer ---
    #
    # An empty expectation means "retrieve nothing". Nearest-neighbour search
    # always returns neighbours, so without a distance cutoff these come back
    # confidently wrong — which costs tokens and points Cal at material that has
    # nothing to do with what was asked. These cases are what MAX_DISTANCE is
    # calibrated against, and the reason it moved from 0.85 to 0.82.
    ("chat", "what should I have for lunch", []),
    ("chat", "can you explain the quadratic formula", []),
    ("navigate", "what is the wifi password", []),
]

# Mirrors MAX_DISTANCE in supabase/functions/coach/retrieval.ts.
MAX_DISTANCE = 0.82

# Which chunk kinds each surface may retrieve. Mirrors `KINDS_FOR_SURFACE` in
# supabase/functions/coach/retrieval.ts — a test pins them together.
KINDS = {"chat": ["practice", "question"], "navigate": ["place"]}


def main():
    verbose = "--verbose" in sys.argv
    api_key = resolve_key()
    collection_id = ensure_collection()

    vectors = embed([query for _, query, _ in CASES], api_key)

    passed, failures = 0, []
    for (surface, query, expected), vector in zip(CASES, vectors):
        # The cutoff is applied here exactly as the function applies it, so the
        # eval measures the pipeline that runs rather than raw neighbours.
        hits = [
            hit for hit in chroma_query(collection_id, vector, KINDS[surface], K)
            if hit["distance"] <= MAX_DISTANCE
        ]
        ids = [hit["id"] for hit in hits]
        ok = (not hits) if not expected else any(candidate in ids for candidate in expected)
        passed += ok

        if verbose or not ok:
            mark = "ok  " if ok else "MISS"
            print("%s [%s] %s" % (mark, surface, query))
            for rank, hit in enumerate(hits, 1):
                star = "*" if hit["id"] in expected else " "
                print("       %s%d. %-46s %.3f" % (star, rank, hit["id"], hit["distance"]))
            if not hits:
                print("       (nothing within %.2f)" % MAX_DISTANCE)
            if not ok:
                print(
                    "       expected: %s"
                    % (", ".join(expected) if expected else "nothing to be retrieved")
                )
                failures.append(query)

    print()
    print("hit@%d: %d/%d" % (K, passed, len(CASES)))
    if failures:
        print("misses: %d" % len(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
