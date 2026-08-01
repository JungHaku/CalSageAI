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
import math
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


# The origin every place is described relative to.
#
# Taken from the seed itself rather than written down here, so the reference and
# the places it describes always come from one extraction. The Campanile is the
# right choice on the merits too: it is visible from most of campus and is the
# landmark a Berkeley student actually navigates by.
CAMPANILE_SLUG = "campanile-sather-tower"

COMPASS = [
    "north", "north-east", "east", "south-east",
    "south", "south-west", "west", "north-west",
]

# Beyond this, a bearing from the Campanile stops being directions and starts
# being trivia — the seed includes genuine off-campus UCB property such as the
# Richmond field stations and the Botanical Garden up in the hills.
MAIN_CAMPUS_RADIUS_M = 1000

EARTH_RADIUS_M = 6_371_000


def offset_from(origin, place):
    """Metres east and north of `origin`, by equirectangular approximation.

    Exact enough by a wide margin at this scale: the whole dataset spans about
    3 km, where the error against a proper geodesic is centimetres.
    """
    mean_latitude = math.radians((origin["lat"] + place["lat"]) / 2)
    east = math.radians(place["lng"] - origin["lng"]) * math.cos(mean_latitude) * EARTH_RADIUS_M
    north = math.radians(place["lat"] - origin["lat"]) * EARTH_RADIUS_M
    return east, north


def location_sentence(origin, place):
    """A human-usable position, derived rather than invented.

    This is arithmetic on the coordinates the seed already carries — no judgement
    about what a building is near, and nothing asserted that the data does not
    contain. It exists because "Campus location at UC Berkeley: Wheeler Hall." told
    Cal a building existed and nothing about where, so Cal correctly answered
    "I don't know where that is" to a question the dataset could answer.

    Rounded deliberately coarsely. The source coordinates are single pins taken
    from map embeds, and a building has extent, so "about 150 metres" is honest
    where "153 metres" would imply a precision the pin does not have.
    """
    east, north = offset_from(origin, place)
    distance = math.hypot(east, north)

    if distance < 40:
        return "Right at the center of campus, by the Campanile (Sather Tower)."

    bearing = math.degrees(math.atan2(east, north)) % 360
    direction = COMPASS[int(round(bearing / 45)) % 8]

    if distance < MAIN_CAMPUS_RADIUS_M:
        rounded = int(round(distance / 50.0) * 50)
        return "About %d metres %s of the Campanile (Sather Tower), on the main campus." % (
            rounded, direction
        )

    return "About %.1f km %s of the Campanile (Sather Tower), away from the main campus." % (
        distance / 1000.0, direction
    )


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
    origin = next((p for p in places if p["slug"] == CAMPANILE_SLUG), None)
    if origin is None:
        sys.exit(
            "FAIL: '%s' is not in the seed, so places cannot be located.\n"
            "      A re-scrape may have renamed it — pick a new reference and say so."
            % CAMPANILE_SLUG
        )

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
            #
            # The location is deliberately NOT in `text`, which is what gets
            # embedded. See the note on `document` below — this cost a retrieval
            # regression to learn.
            "text": "Campus location at UC Berkeley: %s\nKind of place: %s."
            % (sentence(name), CATEGORY_NAMES.get(category, category)),
            "document": "Campus location at UC Berkeley: %s\nKind of place: %s.\n%s"
            % (
                sentence(name),
                CATEGORY_NAMES.get(category, category),
                location_sentence(origin, place),
            ),
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
        # `text` is what gets embedded; `document` is what Cal reads. They are
        # the same for everything except places, and splitting them was not a
        # refinement — it was a bug fix.
        #
        # Putting the derived location into the embedded text made retrieval
        # measurably worse: the sentence is near-identical boilerplate across all
        # 231 places ("About N metres <dir> of the Campanile..."), so it diluted
        # the one distinctive signal each chunk had — its name. "Where is Wheeler
        # Hall?" stopped returning Wheeler Hall at 0.376 and started returning the
        # Wheeler Brain Imaging Center at 0.511, with Wheeler Hall outside the top
        # four entirely.
        #
        # The general rule, and it is easy to get backwards: embed what the chunk
        # is *about*, store what the reader needs. Boilerplate added to embedded
        # text makes every chunk look more like every other chunk.
        chunk.setdefault("document", chunk["text"])

    # Every place must carry a usable position. Without this the corpus can
    # regress to "Wheeler Hall exists" — which is what it said before, and which
    # made Cal answer "I don't know where that is" to a question the data could
    # answer. Silent, and invisible until someone reads a transcript.
    unlocated = [
        chunk["id"] for chunk in chunks
        if chunk["kind"] == "place" and "Campanile" not in chunk["document"]
    ]
    if unlocated:
        sys.exit(
            "FAIL: %d place chunks have no location: %s"
            % (len(unlocated), ", ".join(unlocated[:5]))
        )

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
