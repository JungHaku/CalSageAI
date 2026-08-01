import Foundation
import Testing

@testable import CalContent

/// `.serialized` because `StubURLProtocol` hands its response back through a
/// static — `URLProtocol` instances are created by the loading system, so there
/// is nowhere per-test to put it. Run in parallel, these tests collect each
/// other's stubbed responses, and the failure reads like a logic bug: a query
/// for "the gym" comes back with the two buildings a *different* test stubbed.
@Suite("Place search", .serialized)
struct PlaceSearchingTests {

    private let places = [
        CampusPlace(slug: "wheeler-hall", name: "Wheeler Hall", latitude: 37.87129, longitude: -122.25914),
        CampusPlace(
            slug: "recreational-sports-facility", name: "Recreational Sports Facility",
            latitude: 37.86865, longitude: -122.26290, category: .athletics
        ),
        CampusPlace(
            slug: "doe-memorial-library", name: "Doe Memorial Library",
            latitude: 37.87244, longitude: -122.25956, category: .library
        ),
    ]

    // MARK: Local

    @Test("a name match is found offline")
    func localFindsName() async {
        let hits = await LocalPlaceSearch().search("Wheeler", in: places)
        #expect(hits.map(\.slug) == ["wheeler-hall"])
    }

    @Test("an empty query returns everything rather than nothing")
    func localEmptyQuery() async {
        #expect(await LocalPlaceSearch().search("   ", in: places).count == places.count)
    }

    /// The gap semantic search exists to fill: no building is called "the gym",
    /// so substring matching cannot answer it however well it is spelled.
    @Test("substring matching cannot answer a phrasing query")
    func localMissesPhrasing() async {
        #expect(await LocalPlaceSearch().search("where's the gym", in: places).isEmpty)
    }

    // MARK: Semantic

    /// Local wins when it has an answer, and — the part that matters — the
    /// network is not touched at all. A student typing a building name must not
    /// wait on a round trip.
    @Test("a local hit short-circuits before any request is made")
    func localHitSkipsTheNetwork() async {
        let (search, calls) = semantic { _ in
            Issue.record("the network was called when local search already had a match")
            return (Data(), 500)
        }
        let hits = await search.search("Wheeler", in: places)

        #expect(hits.map(\.slug) == ["wheeler-hall"])
        #expect(calls.count == 0)
    }

    @Test("a phrasing query falls through to the endpoint and resolves slugs")
    func semanticResolvesSlugs() async {
        let (search, calls) = semantic { _ in
            let body = #"{"places":[{"slug":"recreational-sports-facility","distance":0.61}]}"#
            return (Data(body.utf8), 200)
        }
        let hits = await search.search("where's the gym", in: places)

        #expect(hits.map(\.slug) == ["recreational-sports-facility"])
        #expect(calls.count == 1)
    }

    /// The server ranks; the client must not re-sort. The first result being the
    /// best one is the entire value of semantic search.
    @Test("server ranking is preserved, not re-sorted alphabetically")
    func rankingPreserved() async {
        let (search, _) = semantic { _ in
            let body = """
            {"places":[{"slug":"wheeler-hall","distance":0.41},
                       {"slug":"doe-memorial-library","distance":0.52}]}
            """
            return (Data(body.utf8), 200)
        }
        let hits = await search.search("somewhere to sit and read", in: places)
        #expect(hits.map(\.slug) == ["wheeler-hall", "doe-memorial-library"])
    }

    /// A slug the app does not ship is dropped. The bundled seed is the authority
    /// on what exists and where it is; a server that has drifted must not be able
    /// to put a phantom pin on the map.
    @Test("an unknown slug is dropped rather than guessed at")
    func unknownSlugDropped() async {
        let (search, _) = semantic { _ in
            let body = #"{"places":[{"slug":"atlantis","distance":0.2},{"slug":"doe-memorial-library","distance":0.4}]}"#
            return (Data(body.utf8), 200)
        }
        let hits = await search.search("mythical", in: places)
        #expect(hits.map(\.slug) == ["doe-memorial-library"])
    }

    // MARK: Degradation
    //
    // Every one of these must return empty rather than throw. The caller is a
    // search field; there is nothing a student can do about a 500, and the
    // offline list is already on screen.

    @Test("a server error degrades to no matches")
    func serverErrorDegrades() async {
        let (search, _) = semantic { _ in (Data(), 500) }
        #expect(await search.search("where's the gym", in: places).isEmpty)
    }

    @Test("malformed JSON degrades to no matches")
    func malformedDegrades() async {
        let (search, _) = semantic { _ in (Data("not json".utf8), 200) }
        #expect(await search.search("where's the gym", in: places).isEmpty)
    }

    @Test("a transport failure — airplane mode — degrades to no matches")
    func offlineDegrades() async {
        let (search, _) = semantic { _ in throw URLError(.notConnectedToInternet) }
        #expect(await search.search("where's the gym", in: places).isEmpty)
    }

    // MARK: Harness

    private func semantic(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)
    ) -> (SemanticPlaceSearch, CallLog) {
        let log = CallLog()
        StubURLProtocol.handler = { request in
            log.record(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let search = SemanticPlaceSearch(
            endpoint: URL(string: "https://example.invalid/functions/v1/places")!,
            session: URLSession(configuration: configuration)
        )
        return (search, log)
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int {
        lock.lock2 { requests.count }
    }

    func record(_ request: URLRequest) {
        lock.lock2 { requests.append(request) }
    }
}

extension NSLock {
    fileprivate func lock2<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Intercepts requests so the tests never touch a network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, Int))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (data, status) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
