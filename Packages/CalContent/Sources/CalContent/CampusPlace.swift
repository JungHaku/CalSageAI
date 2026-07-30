import Foundation

/// A campus location. Mirrors the `campus_places` table (ARCHITECTURE.md §5.2).
/// What kind of place this is.
///
/// ⚠️ **Keyword-derived, not curated.** The source is a list of building names, so
/// only about 41% of the 231 places reveal their kind from the name; the rest fall
/// through to `.building`. The filter is useful for libraries, athletics and
/// parking and close to useless for dining and health — a curation pass is needed
/// before this is presented as a way to find food or a clinic
/// (ARCHITECTURE.md §17).
public enum CampusPlaceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case library, athletics, dining, health, parking, residence, museum, outdoor, services, building

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .library: "Libraries"
        case .athletics: "Athletics"
        case .dining: "Dining"
        case .health: "Health"
        case .parking: "Parking"
        case .residence: "Housing"
        case .museum: "Arts"
        case .outdoor: "Outdoors"
        case .services: "Services"
        case .building: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .library: "books.vertical.fill"
        case .athletics: "figure.run"
        case .dining: "fork.knife"
        case .health: "cross.case.fill"
        case .parking: "parkingsign"
        case .residence: "house.fill"
        case .museum: "theatermasks.fill"
        case .outdoor: "leaf.fill"
        case .services: "building.2.fill"
        case .building: "mappin"
        }
    }
}

public struct CampusPlace: Hashable, Codable, Sendable, Identifiable {
    public let slug: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public var category: CampusPlaceCategory
    /// Alternate names students actually use ("Main Stacks", "the Doe"). Populated
    /// by hand as the dataset is curated — the raw seed has none.
    public var aliases: [String]
    /// Set once a human has confirmed the pin and any phone number on it. Crisis
    /// and health resources must never ship unverified (§9.3).
    public var verifiedAt: Date?

    public var id: String { slug }

    public init(
        slug: String,
        name: String,
        latitude: Double,
        longitude: Double,
        category: CampusPlaceCategory = .building,
        aliases: [String] = [],
        verifiedAt: Date? = nil
    ) {
        self.slug = slug
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.aliases = aliases
        self.verifiedAt = verifiedAt
    }

    /// Case- and diacritic-insensitive match over the name and any aliases.
    public func matches(_ query: String) -> Bool {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !needle.isEmpty else { return true }
        let haystacks = [name] + aliases
        return haystacks.contains {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(needle)
        }
    }
}

/// Loads the bundled seed dataset.
///
/// The seed is the 235 official campus locations extracted from `berkeley.edu/map`
/// (§14). Note `berkeley.edu/map` has no supported API, so this is a point-in-time
/// snapshot to re-run quarterly — not a live dependency.
public enum CampusPlaceSeed {
    /// Shape of the raw extraction, before curation adds categories and aliases.
    private struct RawPlace: Decodable {
        let slug: String
        let name: String
        let lat: Double
        let lng: Double
        let category: CampusPlaceCategory?
    }

    /// Every UCB location carries this suffix in the source page's titles.
    static let nameSuffix = " - University of California, Berkeley"

    /// Loads from the package's own resource bundle.
    ///
    /// Split into two overloads because SwiftPM's generated `Bundle.module` is
    /// internal, so it cannot appear as a default argument on a `public` function.
    public static func load() throws -> [CampusPlace] {
        try load(from: .module)
    }

    static func load(from bundle: Bundle) throws -> [CampusPlace] {
        guard let url = bundle.url(forResource: "campus-places.seed", withExtension: "json") else {
            throw CampusPlaceSeedError.resourceMissing
        }
        let raw = try JSONDecoder().decode([RawPlace].self, from: Data(contentsOf: url))
        return deduplicated(
            raw.map {
                CampusPlace(
                    slug: $0.slug,
                    name: cleanName($0.name),
                    latitude: $0.lat,
                    longitude: $0.lng,
                    category: $0.category ?? .building
                )
            }
        )
    }

    /// Collapses entries that are the same building listed twice.
    ///
    /// `berkeley.edu/map` lists four libraries twice — Doe, Moffitt, Hargrove
    /// Music, and Starr East Asian — as `<slug>` and `<slug>-2` at *identical*
    /// coordinates. Left alone that renders two pins on one building, so the
    /// duplicates are dropped at load rather than pushed onto whoever curates the
    /// dataset later.
    ///
    /// Only exact matches on name *and* coordinates are collapsed: two genuinely
    /// distinct rooms that happen to share a name must survive. Ties resolve to
    /// the shorter slug, which is deterministically the un-suffixed one.
    static func deduplicated(_ places: [CampusPlace]) -> [CampusPlace] {
        struct Key: Hashable {
            let name: String
            let latitude: Double
            let longitude: Double
        }

        var winners: [Key: CampusPlace] = [:]
        for place in places {
            let key = Key(name: place.name, latitude: place.latitude, longitude: place.longitude)
            if let existing = winners[key],
               (existing.slug.count, existing.slug) <= (place.slug.count, place.slug) {
                continue
            }
            winners[key] = place
        }
        // Sorted so the output order is stable across runs regardless of Dictionary
        // iteration order — otherwise snapshot tests of the map list would flake.
        return winners.values.sorted { $0.slug < $1.slug }
    }

    static func cleanName(_ name: String) -> String {
        guard name.hasSuffix(nameSuffix) else { return name }
        return String(name.dropLast(nameSuffix.count))
    }
}

public enum CampusPlaceSeedError: Error, Sendable {
    case resourceMissing
}
