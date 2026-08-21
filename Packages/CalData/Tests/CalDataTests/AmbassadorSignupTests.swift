import Foundation
import Testing

@testable import CalData

@Suite("Ambassador signup", .serialized)
struct AmbassadorSignupTests {

    private let userID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func client(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)
    ) -> RestAmbassadorSignup {
        AmbassadorStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AmbassadorStubURLProtocol.self]
        let jwt = ambassadorJWT(expiringAt: Date().timeIntervalSince1970 + 3600)
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
        return RestAmbassadorSignup(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            auth: auth,
            session: URLSession(configuration: configuration)
        )
    }

    @Test("submit posts a normalised email for the signed-in user")
    func submitPostsNormalisedEmail() async throws {
        let captured = AmbassadorCaptured()
        let signup = client { request in
            captured.set("\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
            return (Data(), 201)
        }
        try await signup.submit(email: "  Mia.Curcuruto@Example.COM ")
        #expect(captured.value.contains("POST"))
        #expect(captured.value.contains("/rest/v1/ambassador_signups"))
        #expect(RestAmbassadorSignup.normalize("  Mia.Curcuruto@Example.COM ") == "mia.curcuruto@example.com")
    }

    @Test("a junk address is rejected before the network")
    func invalidEmailNeverHitsTheNetwork() async {
        let signup = client { _ in
            Issue.record("network should not run")
            return (Data(), 500)
        }
        await #expect(throws: AmbassadorSignupError.invalidEmail) {
            try await signup.submit(email: "not-an-email")
        }
    }

    @Test("currentEmail reads the stored row")
    func currentEmailReadsRow() async {
        let signup = client { _ in
            (Data(#"[{"email":"ambassador@example.com"}]"#.utf8), 200)
        }
        #expect(await signup.currentEmail() == "ambassador@example.com")
    }
}

private func ambassadorJWT(expiringAt seconds: Double) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["exp": seconds])
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private final class AmbassadorCaptured: @unchecked Sendable {
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

private final class AmbassadorStubURLProtocol: URLProtocol, @unchecked Sendable {
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
