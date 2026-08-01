#!/usr/bin/env python3
"""Build the retrieval corpus from the bundled content.

    ./tools/build-content-corpus.py

Writes `content/corpus.jsonl` — one JSON object per chunk, deterministically
ordered. Reads only files already in the repo; no network, no key, no cost.

Why the corpus is a committed file rather than something the embed step derives
on the fly: these chunks are what Cal is given as ground truth about Dr. Mia's
practices, so a change to them is a change to the product's clinical content and
belongs in a diff where it can be read. It is the same argument `check-prompt.sh`
makes about the system prompt — a review is worth nothing if the reviewed text
is not the text that runs. `check-corpus.sh` fails when the two separate.

The embedding step is deliberately a different script: this one is free and
offline, that one costs money and needs a key.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTENT = ROOT / "Packages/CalContent/Sources/CalContent/Resources/content.json"
PLACES = ROOT / "Packages/CalContent/Sources/CalContent/Resources/campus-places.seed.json"
OUT = ROOT / "content/corpus.jsonl"

# Mirrors `CampusPlaceSeed.nameSuffix`.
NAME_SUFFIX = " - University of California, Berkeley"

# Mirrors `CampusPlaceCategory.displayName`, so a chunk says "Libraries" rather
# than the wire value. Kept in sync by `CorpusTests.categoryNamesMatchTheApp`.
CATEGORY_NAMES = {
    "library": "Libraries",
    "athletics": "Athletics",
    "dining": "Dining",
    "health": "Health",
    "parking": "Parking",
    "residence": "Housing",
    "museum": "Arts",
    "outdoor": "Outdoors",
    "services": "Services",
    "building": "Other",
}

# Mirrors `CoherenceCategory.displayName`.
AREA_NAMES = {
    "overall": "Overall",
    "safety": "Safety",
    "breath": "Breath",
    "presence": "Presence",
    "emotional_flow": "Emotional flow",
    "body_awareness": "Body awareness",
    "choice": "Choice",
    "connection": "Connection",
    "energy": "Energy",
    "inner_knowing": "Inner knowing",
    "authentic_expression": "Authentic expression",
}


def clean_name(name):
    """Mirrors `CampusPlaceSeed.cleanName`."""
    return name[: -len(NAME_SUFFIX)] if name.endswith(NAME_SUFFIX) else name


def sentence(text):
    """Terminate `text` without doubling punctuation it already ends with."""
    return text if text[-1:] in ".!?" else text + "."


def deduplicated(places):
    """Mirrors `CampusPlaceSeed.deduplicated` exactly, including the tie-break.

    The source page lists four libraries twice at identical coordinates. If this
    diverges from the Swift, the corpus and the map disagree about how many
    places exist — so `CampusPlaceSeedTests` and `check-corpus.sh` both pin the
    resulting count.
    """
    winners = {}
    for place in places:
        key = (place["name"], place["lat"], place["lng"])
        existing = winners.get(key)
        if existing is not None:
            # Ties resolve to the shorter slug, which is deterministically the
            # un-suffixed one.
            if (len(existing["slug"]), existing["slug"]) <= (len(place["slug"]), place["slug"]):
                continue
        winners[key] = place
    return sorted(winners.values(), key=lambda p: p["slug"])


def render_script(steps):
    """Dr. Mia's words, with the breath structure preserved.

    Rendered rather than dumped as JSON because this text is what the model
    reads: it has to guide the practice from her wording, not paraphrase a data
    structure. Empty-text breath steps are pacing, and become a bare instruction
    rather than vanishing — the rhythm is part of the practice.
    """
    lines = []
    for step in steps:
        kind = step.get("kind")
        text = (step.get("text") or "").strip()
        if kind == "repeat":
            lines.append("Repeat the cycle %d times." % step.get("times", 1))
        elif kind == "inhale":
            lines.append(("Breathe in: %s" % text) if text else "Breathe in.")
        elif kind == "exhale":
            lines.append(("Breathe out: %s" % text) if text else "Breathe out.")
        elif kind == "hold":
            lines.append(("Hold: %s" % text) if text else "Hold.")
        elif text:
            lines.append(text)
    return "\n".join(lines)


def practice_chunks(bundle):
    for exercise in bundle["exercises"]:
        area = exercise.get("category")
        header = ["Guided practice: %s" % exercise["title"]]
        if exercise.get("purpose"):
            header.append("Purpose: %s" % exercise["purpose"])
        if area:
            header.append("Coherence area: %s." % AREA_NAMES.get(area, area))
        header.append("This is the authored script. Guide it in these words.")

        yield {
            "id": "practice:%s" % exercise["slug"],
            "kind": "practice",
            "slug": exercise["slug"],
            "text": "\n".join(header) + "\n\n" + render_script(exercise["script"]["steps"]),
            "metadata": {
                "kind": "practice",
                "slug": exercise["slug"],
                "title": exercise["title"],
                "area": area or "",
                "tier": exercise.get("tier") or "free",
            },
        }


def question_chunks(bundle):
    for question in bundle["questions"]:
        area = question["category"]
        yield {
            "id": "question:%s" % area,
            "kind": "question",
            "slug": area,
            "text": "\n".join(
                [
                    "Coherence area: %s." % AREA_NAMES.get(area, area),
                    "The daily check-in asks: %s" % question["prompt"],
                    "After a regulation exercise it asks: %s" % question["rePrompt"],
                    "When the score is low, Cal guides: %s" % question["regulationSummary"],
                ]
            ),
            "metadata": {"kind": "question", "slug": area, "area": area},
        }


def place_chunks(places):
    for place in places:
        name = clean_name(place["name"])
        category = place.get("category") or "building"
        yield {
            "id": "place:%s" % place["slug"],
            "kind": "place",
            "slug": place["slug"],
            # Deliberately thin. The only facts in the source are a name and a
            # keyword-derived category, and inventing descriptions ("a quiet
            # spot to study") would be exactly the fabrication decision-log #10
            # forbids. Retrieval quality here is bounded by the dataset, not by
            # the embedding model — see ARCHITECTURE §17 item 14.
            # `sentence` guards names that already end in punctuation — a good
            # few are street addresses ending "Ave." or "St.".
            "text": "Campus location at UC Berkeley: %s\nKind of place: %s."
            % (sentence(name), CATEGORY_NAMES.get(category, category)),
            "metadata": {
                "kind": "place",
                "slug": place["slug"],
                "name": name,
                "category": category,
                "lat": place["lat"],
                "lng": place["lng"],
            },
        }


def build():
    bundle = json.loads(CONTENT.read_text())
    raw_places = json.loads(PLACES.read_text())
    places = deduplicated(raw_places)

    chunks = list(practice_chunks(bundle)) + list(question_chunks(bundle)) + list(place_chunks(places))
    # Stable order so a re-run produces a byte-identical file and the drift check
    # means something.
    chunks.sort(key=lambda c: c["id"])

    for chunk in chunks:
        chunk["contentVersion"] = bundle["version"]

    return chunks, len(raw_places), len(places)


def main():
    chunks, raw_count, place_count = build()
    body = "".join(
        json.dumps(chunk, ensure_ascii=False, sort_keys=True) + "\n" for chunk in chunks
    )

    if "--check" in sys.argv:
        if not OUT.exists():
            sys.exit("FAIL: %s does not exist — run ./tools/build-content-corpus.py" % OUT)
        if OUT.read_text() != body:
            sys.exit(
                "FAIL: content/corpus.jsonl has drifted from the bundled content.\n"
                "      The content JSON is canonical — run ./tools/build-content-corpus.py"
            )
        print("OK: corpus matches the bundled content (%d chunks)" % len(chunks))
        return

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(body)

    kinds = {}
    for chunk in chunks:
        kinds[chunk["kind"]] = kinds.get(chunk["kind"], 0) + 1
    print("wrote %s" % OUT.relative_to(ROOT))
    print("  %d chunks: %s" % (len(chunks), ", ".join("%s %d" % kv for kv in sorted(kinds.items()))))
    print("  places: %d raw, %d after collapsing exact duplicates" % (raw_count, place_count))


if __name__ == "__main__":
    main()
