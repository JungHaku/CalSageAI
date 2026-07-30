import Foundation
import Testing

@testable import CalContent

@Suite("Campus place seed")
struct CampusPlaceSeedTests {
    @Test("the bundled seed decodes to 231 distinct locations (235 raw, 4 duplicates collapsed)")
    func decodes() throws {
        let places = try CampusPlaceSeed.load()
        #expect(places.count == 231)
    }

    @Test("the UCB suffix is stripped from display names")
    func namesAreCleaned() throws {
        #expect(CampusPlaceSeed.cleanName("Doe Library - University of California, Berkeley") == "Doe Library")
        #expect(CampusPlaceSeed.cleanName("Doe Library") == "Doe Library")

        let places = try CampusPlaceSeed.load()
        #expect(!places.contains { $0.name.contains("University of California, Berkeley") })
    }

    @Test("slugs are unique — they're the stable identity used for favourites")
    func slugsAreUnique() throws {
        let places = try CampusPlaceSeed.load()
        #expect(Set(places.map(\.slug)).count == places.count)
    }

    @Test("no place has an empty name or a null-island coordinate")
    func noDegenerateRows() throws {
        for place in try CampusPlaceSeed.load() {
            #expect(!place.name.isEmpty, "empty name for \(place.slug)")
            #expect(place.latitude != 0 || place.longitude != 0, "null-island coordinate for \(place.slug)")
        }
    }

    // Guards against a re-scrape silently pulling in coordinates from somewhere
    // else entirely. The bounds are generous: they cover main campus plus the
    // genuine outlying UCB properties (Richmond field station, Botanical Garden,
    // west Berkeley), while still catching a sign flip or a swapped lat/lng.
    @Test("every coordinate is plausibly in the Berkeley/Richmond area")
    func coordinatesArePlausible() throws {
        for place in try CampusPlaceSeed.load() {
            #expect(
                (37.84...37.93).contains(place.latitude),
                "latitude \(place.latitude) out of range for \(place.slug)"
            )
            #expect(
                (-122.35...(-122.22)).contains(place.longitude),
                "longitude \(place.longitude) out of range for \(place.slug)"
            )
        }
    }

    @Test("the landmarks named in Dr. Mia's spec are present")
    func knownLandmarksPresent() throws {
        let slugs = Set(try CampusPlaceSeed.load().map(\.slug))
        // Anchors drawn from the example questions in SPEC-free.md §2 — "Where is
        // Wheeler Hall?", "Where is Tang Center?", "Where is the RSF gym?". If a
        // re-scrape drops these, Navigate can't answer the spec's own examples.
        for expected in [
            "wheeler-hall",
            "tang-center",
            "recreational-sports-facility",
            "doe-memorial-library",
            "moffitt-library",
        ] {
            #expect(slugs.contains(expected), "seed is missing \(expected)")
        }
    }

    // The source page lists four libraries twice, at identical coordinates, as
    // `<slug>` and `<slug>-2`. The loader collapses them so the map doesn't draw
    // two pins on one building.
    @Test("the four known source duplicates are collapsed, keeping the un-suffixed slug")
    func knownDuplicatesCollapsed() throws {
        let places = try CampusPlaceSeed.load()
        let slugs = Set(places.map(\.slug))

        for base in ["doe-memorial-library", "moffitt-library", "hargrove-music-library", "starr-east-asian-library"] {
            #expect(slugs.contains(base), "lost the canonical \(base)")
            #expect(!slugs.contains("\(base)-2"), "duplicate \(base)-2 survived deduplication")
        }
    }

    @Test("after loading, no two places share a name — a new source duplicate fails here")
    func noRemainingDuplicateNames() throws {
        let byName = Dictionary(grouping: try CampusPlaceSeed.load(), by: \.name)
            .filter { $0.value.count > 1 }
        #expect(
            byName.isEmpty,
            "unexpected duplicate names — the source page changed: \(byName.keys.sorted())"
        )
    }

    @Test("deduplication keeps genuinely distinct places that merely share a name")
    func doesNotOvercollapse() {
        // Two different rooms with the same name at different coordinates are not
        // duplicates and must both survive.
        let distinct = [
            CampusPlace(slug: "study-room-a", name: "Study Room", latitude: 37.8721, longitude: -122.2595),
            CampusPlace(slug: "study-room-b", name: "Study Room", latitude: 37.8730, longitude: -122.2600),
        ]
        #expect(CampusPlaceSeed.deduplicated(distinct).count == 2)
    }

    @Test("deduplication output order is stable, so map snapshots don't flake")
    func stableOrdering() throws {
        #expect(try CampusPlaceSeed.load().map(\.slug) == (try CampusPlaceSeed.load().map(\.slug)))
        #expect(try CampusPlaceSeed.load().map(\.slug) == (try CampusPlaceSeed.load().map(\.slug).sorted()))
    }
}
