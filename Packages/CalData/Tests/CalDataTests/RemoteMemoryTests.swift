import Foundation
import Testing

@testable import CalData
import CalKit

@Suite("Rest memory client", .serialized)
struct RestMemoryClientTests {

    private let userID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func client(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)
    ) -> RestMemoryClient {
        MemoryStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryStubURLProtocol.self]
        let jwt = jwt(expiringAt: Date().timeIntervalSince1970 + 3600)
        let auth = AuthSession(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            session: URLSession(configuration: configuration),
            store: InMemoryTokenStore(
                AuthSession.Credentials(
                    userID: userID, accessToken: jwt, refreshToken: "r", email: "a@b.co"
                )
            )
        )
        return RestMemoryClient(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            auth: auth,
            session: URLSession(configuration: configuration)
        )
    }

    @Test("granting consent upserts the current-version row")
    func grantUpsertsConsent() async throws {
        let path = Captured()
        let memory = client { request in
            path.set(request.url?.absoluteString ?? "")
            #expect(request.httpMethod == "POST")
            return (Data(), 201)
        }
        try await memory.persistConsent(granted: true)
        #expect(path.value.contains("/rest/v1/consents"))
        #expect(path.value.contains("on_conflict=user_id,doc_type,doc_version"))
    }

    @Test("revoking consent deletes the row and forgets memories")
    func revokeDeletesAndForgets() async throws {
        let paths = CapturedList()
        let memory = client { request in
            paths.append(request.url?.path ?? "")
            return (Data(), 204)
        }
        try await memory.persistConsent(granted: false)
        #expect(paths.value.contains { $0.contains("/rest/v1/consents") })
        #expect(paths.value.contains { $0.contains("/rest/v1/rpc/forget_memories") })
    }

    @Test("forgetAll hits the definer RPC")
    func forgetHitsRPC() async throws {
        let path = Captured()
        let memory = client { request in
            path.set(request.url?.path ?? "")
            #expect(request.httpMethod == "POST")
            return (Data(), 204)
        }
        try await memory.forgetAll()
        #expect(path.value == "/rest/v1/rpc/forget_memories")
    }

    @Test("unsigned persistConsent is a no-op")
    func unsignedIsNoOp() async throws {
        MemoryStubURLProtocol.handler = { _ in
            Issue.record("must not call the network when signed out")
            return (Data(), 500)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryStubURLProtocol.self]
        let auth = AuthSession(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            session: URLSession(configuration: configuration),
            store: InMemoryTokenStore()
        )
        let memory = RestMemoryClient(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            auth: auth,
            session: URLSession(configuration: configuration)
        )
        try await memory.persistConsent(granted: true)
        try await memory.forgetAll()
    }

    @Test("digest returns recent texts newest first")
    func digestReadsOwnRows() async {
        let memory = client { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/rest/v1/memories")
            return (Data(#"[{"text":"chem midterm Thursday"},{"text":"loud roommate"}]"#.utf8), 200)
        }
        let facts = await memory.digest()
        #expect(facts == ["chem midterm Thursday", "loud roommate"])
    }

    @Test("digest fails open on a store error")
    func digestFailsOpen() async {
        let memory = client { _ in (Data(), 500) }
        #expect(await memory.digest() == [])
    }

    @Test("remember posts the turn to the memory function")
    func rememberHitsFunction() async {
        let captured = Captured()
        let memory = client { request in
            captured.set("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (Data(#"{"stored":true}"#.utf8), 200)
        }
        await memory.remember(text: "my chemistry midterm is Thursday", severity: "none")
        #expect(captured.value == "POST /functions/v1/memory")
    }
}

private func jwt(expiringAt seconds: Double) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["exp": seconds])
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set(_ newValue: String) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}

private final class CapturedList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var value: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func append(_ newValue: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(newValue)
    }
}

private final class MemoryStubURLProtocol: URLProtocol, @unchecked Sendable {
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
