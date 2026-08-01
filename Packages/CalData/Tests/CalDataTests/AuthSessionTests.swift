import Foundation
import Testing

@testable import CalData

/// `.serialized` for the same reason as `PlaceSearchingTests`: `URLProtocol`
/// instances are built by the loading system, so the stub returns its response
/// through a static and parallel tests collect each other's.
@Suite("Auth session", .serialized)
struct AuthSessionTests {

    private var userID: UUID { stubUserID }

    private func session(
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)
    ) -> (AuthSession, InMemoryTokenStore) {
        AuthStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStubURLProtocol.self]
        let store = InMemoryTokenStore()
        return (
            AuthSession(
                baseURL: URL(string: "https://stack.invalid")!,
                anonKey: "anon",
                session: URLSession(configuration: configuration),
                store: store
            ),
            store
        )
    }


    @Test("signing in yields credentials and persists them")
    func signInPersists() async throws {
        let (auth, store) = session { _ in (stubTokenPayload(), 200) }

        let credentials = try await auth.signIn(email: "student@berkeley.edu", password: "password123")

        #expect(credentials.userID == userID)
        #expect(credentials.accessToken == "jwt-token")
        #expect(store.load()?.accessToken == "jwt-token", "the session must survive a relaunch")
    }

    @Test("the token is available to the coach client once signed in")
    func tokenIsExposed() async throws {
        let (auth, _) = session { _ in (stubTokenPayload(freshJWT), 200) }
        try await auth.signIn(email: "a@b.co", password: "password123")
        #expect(await auth.accessToken() == freshJWT)
    }

    @Test("signed out means no token at all, never a stand-in")
    func signedOutHasNoToken() async {
        let (auth, _) = session { _ in (Data(), 200) }
        #expect(await auth.accessToken() == nil)
        #expect(await auth.isSignedIn() == false)
    }

    @Test("a restored session is picked up from storage")
    func restoresFromStorage() async {
        AuthStubURLProtocol.handler = { _ in (Data(), 500) }
        let seeded = AuthSession.Credentials(
            // A real-shaped, unexpired JWT: `accessToken()` now inspects `exp`,
            // so an opaque placeholder reads as expired and triggers a refresh.
            userID: userID, accessToken: freshJWT, refreshToken: "r", email: "a@b.co"
        )
        let auth = AuthSession(
            baseURL: URL(string: "https://stack.invalid")!,
            anonKey: "anon",
            store: InMemoryTokenStore(seeded)
        )
        #expect(await auth.accessToken() == freshJWT)
    }

    @Test("bad credentials surface the server's reason, not a stack trace")
    func rejectionIsReadable() async {
        let (auth, store) = session { _ in
            (Data(#"{"msg":"Invalid login credentials"}"#.utf8), 400)
        }

        await #expect(throws: AuthError.self) {
            try await auth.signIn(email: "a@b.co", password: "wrongpassword")
        }
        #expect(store.load() == nil, "a failed sign-in must not leave a session behind")
    }

    /// Sign-up with email confirmation enabled returns 200 and no session.
    /// Reporting that honestly beats appearing signed in and then failing every
    /// request with no explanation.
    @Test("a confirmation-required signup is reported as such")
    func confirmationRequired() async {
        let (auth, _) = session { _ in (Data(#"{"user":{"id":null}}"#.utf8), 200) }

        await #expect(throws: AuthError.confirmationRequired) {
            try await auth.signUp(email: "a@b.co", password: "password123")
        }
    }

    /// Signing out forgets the session. It must not be mistaken for erasure —
    /// a student signing out on a borrowed phone still wants their history.
    @Test("signing out clears the token and nothing else")
    func signOutClearsToken() async throws {
        let (auth, store) = session { _ in (stubTokenPayload(), 200) }
        try await auth.signIn(email: "a@b.co", password: "password123")

        await auth.signOut()

        #expect(await auth.accessToken() == nil)
        #expect(store.load() == nil)
    }

    /// The bug the first live run exposed: a token minted hours earlier was sent
    /// unchanged, the auth server answered 403, and the app kept showing "Signed
    /// in" while memory silently did nothing.
    @Test("an expired token is refreshed before it is handed out")
    func expiredTokenRefreshes() async throws {
        let calls = CapturedURL()
        let (auth, _) = session { request in
            calls.set(calls.value + (request.url?.absoluteString.contains("refresh_token") == true ? "R" : "P"))
            return (stubTokenPayload(calls.value.contains("R") ? freshJWT : expiredJWT), 200)
        }
        try await auth.signIn(email: "a@b.co", password: "password123")

        let token = await auth.accessToken()

        #expect(calls.value == "PR", "sign-in then exactly one refresh, got \(calls.value)")
        #expect(token == freshJWT)
    }

    @Test("a live token is handed out without a round trip")
    func liveTokenIsNotRefreshed() async throws {
        let calls = CapturedURL()
        let (auth, _) = session { request in
            calls.set(calls.value + "x")
            _ = request
            return (stubTokenPayload(freshJWT), 200)
        }
        try await auth.signIn(email: "a@b.co", password: "password123")

        #expect(await auth.accessToken() == freshJWT)
        #expect(calls.value == "x", "only the sign-in should have hit the network")
    }

    /// A refresh token the server refuses means the session is over. Keeping a
    /// signed-in state that cannot do anything is how "it says I am signed in but
    /// nothing works" happens.
    @Test("a refused refresh signs the person out rather than pretending")
    func refusedRefreshSignsOut() async throws {
        let (auth, store) = session { request in
            if request.url?.absoluteString.contains("refresh_token") == true {
                return (Data(#"{"msg":"invalid refresh token"}"#.utf8), 400)
            }
            return (stubTokenPayload(expiredJWT), 200)
        }
        try await auth.signIn(email: "a@b.co", password: "password123")

        #expect(await auth.accessToken() == nil)
        #expect(store.load() == nil, "a dead session must not linger in the Keychain")
    }

    @Test("the grant_type query survives URL construction")
    func tokenEndpointKeepsItsQuery() async throws {
        let captured = CapturedURL()
        let (auth, _) = session { request in
            captured.set(request.url?.absoluteString ?? "")
            return (stubTokenPayload(), 200)
        }
        try await auth.signIn(email: "a@b.co", password: "password123")

        // `appendingPathComponent` percent-encodes `?`, which silently turns the
        // token endpoint into a 404 path.
        #expect(captured.value.contains("grant_type=password"), "got \(captured.value)")
        #expect(!captured.value.contains("%3F"))
    }
}

private let stubUserID = UUID(uuidString: "a623e041-d851-48c3-8aad-76fab1e3fff8")!

/// Real-shaped JWTs: header.payload.signature, where the payload carries `exp`.
/// The signature is never checked here — that is the server's job, and a second
/// implementation of it would be a second thing to get wrong.
private func jwt(expiringAt seconds: Double) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["exp": seconds])
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private let expiredJWT = jwt(expiringAt: Date().timeIntervalSince1970 - 3600)
private let freshJWT = jwt(expiringAt: Date().timeIntervalSince1970 + 3600)

/// Free function on purpose. A stub handler that captures `self` retains the
/// test suite past teardown, and the process then dies with signal 11 *after*
/// reporting every test as passed — which reads like the toolchain bug in
/// ARCHITECTURE §11 and is not.
private func stubTokenPayload(_ token: String = "jwt-token") -> Data {
    Data("""
    {"access_token":"\(token)","refresh_token":"refresh",
     "user":{"id":"\(stubUserID.uuidString)","email":"student@berkeley.edu"}}
    """.utf8)
}

private final class CapturedURL: @unchecked Sendable {
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

private final class AuthStubURLProtocol: URLProtocol, @unchecked Sendable {
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
