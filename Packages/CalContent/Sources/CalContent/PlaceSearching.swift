import Foundation

/// Finding a campus place from what a student typed.
///
/// A seam for the same reason every other dependency here is one (ARCHITECTURE
/// §2): the offline implementation is the one that must always work, and the
/// networked one is an enhancement layered behind the same call.
public protocol PlaceSearching: Sendable {
    /// Matches for `query`, best first. Never throws — a search that fails
    /// returns no matches, because the caller is a text field and there is
    /// nothing useful for a student to do about a 500.
    func search(_ query: String, in places: [CampusPlace]) async -> [CampusPlace]
}

/// Substring matching over names and aliases. Instant, offline, free.
///
/// This is the primary path and stays that way. Typing "Wheeler" should not wait
/// on a network round trip, and Navigate has to work in a basement — the campus
/// dataset is bundled precisely so it does (§1).
public struct LocalPlaceSearch: PlaceSearching {
    public init() {}

    public func search(_ query: String, in places: [CampusPlace]) async -> [CampusPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return places }
        return places.filter { $0.matches(trimmed) }
    }
}

/// Semantic search via our own endpoint, with the local search underneath it.
///
/// What it buys, and it is narrow: substring matching answers "Wheeler" and
/// cannot answer "where's the gym", because no building is literally named that.
/// Phrasing is what embeddings are for.
///
/// So the order is deliberate — local first, and the network is only consulted
/// when local found nothing. Three consequences, all wanted:
///
/// - Typing a building name costs nothing and waits for nothing.
/// - The offline guarantee is untouched. Airplane mode degrades this to exactly
///   the search the app had before.
/// - We spend an embedding only on the queries substring matching cannot serve.
///
/// The endpoint returns slugs, not places. Resolving them against the bundled
/// seed means the coordinates rendered on the map are always the ones the app
/// ships with, and a stale server can never move a building.
public struct SemanticPlaceSearch: PlaceSearching {
    private let endpoint: URL
    private let anonKey: String?
    private let session: URLSession
    private let local = LocalPlaceSearch()

    public init(endpoint: URL, anonKey: String? = nil, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.anonKey = anonKey
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            // Short on purpose. This is a search box: a result that arrives after
            // eight seconds arrives after the student has given up and scrolled
            // the list, and the local results are already on screen.
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            return URLSession(configuration: configuration)
        }()
    }

    /// The local development function.
    public static func local(port: Int = 54321) -> SemanticPlaceSearch {
        SemanticPlaceSearch(endpoint: URL(string: "http://127.0.0.1:\(port)/functions/v1/places")!)
    }

    public func search(_ query: String, in places: [CampusPlace]) async -> [CampusPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return places }

        let direct = await local.search(trimmed, in: places)
        guard direct.isEmpty else { return direct }

        guard let slugs = try? await remoteSlugs(for: trimmed) else { return [] }

        // Resolved against the bundled seed, and ordered by the server's ranking
        // rather than by name — the whole point is that the first result is the
        // best one. A slug we do not recognise is dropped rather than guessed at.
        let byslug = Dictionary(places.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        return slugs.compactMap { byslug[$0] }
    }

    private func remoteSlugs(for query: String) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let anonKey {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
        }
        request.httpBody = try JSONEncoder().encode(Query(query: query))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaceSearchError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(Matches.self, from: data).places.map(\.slug)
    }

    private struct Query: Encodable {
        let query: String
    }

    private struct Matches: Decodable {
        struct Match: Decodable {
            let slug: String
            let distance: Double
        }
        let places: [Match]
    }
}

public enum PlaceSearchError: Error, Equatable, Sendable {
    case badResponse(Int)
}
