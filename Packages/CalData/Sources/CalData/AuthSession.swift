import CalKit
import Foundation

/// Signing in, and holding the token that proves it.
///
/// Deliberately smaller than `CalRemote.SupabaseIdentity`, which wraps the full
/// Supabase SDK for syncing rows at Phase B. What the app needs *now* is
/// narrower: acquire a bearer token, keep it safely, and hand it to the coach
/// function so the server can tell who is asking. That is two HTTP calls and a
/// Keychain item, and it does not justify linking a Postgres client into the app
/// or the build time that comes with it. When row sync lands, `SupabaseIdentity`
/// is the thing that supersedes this.
///
/// **Email and password only** (ARCHITECTURE §15 step 2). Not anonymous — it
/// buys a uniform code path we do not need at the cost of a second identity
/// state in every policy. Not Sign in with Apple — guideline 4.8 does not
/// require it for an app using exclusively its own sign-in, it cannot be enabled
/// without a paid Developer Program membership, and it would bring 5.1.1(v)'s
/// revocation obligation with no Supabase endpoint to satisfy it.
public actor AuthSession {
    public struct Credentials: Sendable, Equatable {
        public let userID: UUID
        public let accessToken: String
        public let refreshToken: String
        public let email: String
    }

    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let store: any TokenStoring

    private var current: Credentials?

    public init(
        baseURL: URL,
        anonKey: String,
        session: URLSession? = nil,
        store: (any TokenStoring)? = nil
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.store = store ?? KeychainTokenStore()
    }

    /// The signed-in user, restored from the Keychain on first ask.
    public func credentials() -> Credentials? {
        if current == nil { current = store.load() }
        return current
    }

    public func isSignedIn() -> Bool { credentials() != nil }

    /// The bearer token for an authenticated request, refreshing it if needed.
    ///
    /// Callers must send *nothing* rather than something else when this is nil.
    /// Substituting the anon key here would make every signed-out device look
    /// like one shared account to the server (`identity.ts` rejects it for the
    /// same reason, from the other side).
    ///
    /// **Refreshing is not optional, and its absence was a real bug.** Supabase
    /// access tokens expire after an hour. Without this, a student who signed in
    /// yesterday keeps a token the app happily sends and the auth server answers
    /// 403 to — so memory silently stops working while every screen still says
    /// "Signed in". That is exactly what happened during the first end-to-end
    /// run, and it took server-side logging to see it, because a rejected token
    /// and no token at all produce the identical user experience.
    public func accessToken() async -> String? {
        guard let current = credentials() else { return nil }
        guard isExpired(current.accessToken) else { return current.accessToken }
        return try? await refresh(current).accessToken
    }

    /// Exchanges the refresh token for a new session.
    @discardableResult
    public func refresh(_ existing: Credentials) async throws -> Credentials {
        guard !existing.refreshToken.isEmpty else { throw AuthError.sessionExpired }
        do {
            return try await authenticate(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: ["refresh_token": existing.refreshToken],
                fallbackEmail: existing.email
            )
        } catch {
            // A refresh token the server will not honour means the session is
            // over. Clearing it is what makes the UI tell the truth instead of
            // showing a signed-in state that cannot do anything.
            signOut()
            throw AuthError.sessionExpired
        }
    }

    /// Reads `exp` out of the JWT payload without verifying the signature.
    ///
    /// Verification is the server's job and duplicating it here would be a
    /// second implementation to get wrong. All this needs to answer is "is it
    /// worth sending?", and a 60-second margin covers the round trip.
    private func isExpired(_ token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double
        else { return true }

        return Date(timeIntervalSince1970: exp).timeIntervalSince(now) < 60
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws -> Credentials {
        try await authenticate(path: "/auth/v1/signup", email: email, password: password)
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Credentials {
        try await authenticate(
            path: "/auth/v1/token?grant_type=password", email: email, password: password
        )
    }

    /// Forgets the session on this device.
    ///
    /// Local only, deliberately. Revoking server-side and erasing what the
    /// server holds are different promises, and conflating them would make
    /// "sign out" quietly mean "delete my data" — which it must not, because a
    /// student signing out on a borrowed phone still wants their history.
    /// Erasure is `PersonalDataService` and the memory store's own delete.
    public func signOut() {
        current = nil
        store.clear()
    }

    private func authenticate(path: String, email: String, password: String) async throws -> Credentials {
        try await authenticate(path: path, body: ["email": email, "password": password], fallbackEmail: email)
    }

    private func authenticate(
        path: String, body: [String: String], fallbackEmail: String
    ) async throws -> Credentials {
        var request = URLRequest(url: baseURL.appendingPathComponent2(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw AuthError.rejected(status, Self.message(from: data))
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = decoded.access_token,
              let userID = decoded.user?.id.flatMap(UUID.init(uuidString:))
        else {
            // Sign-up with email confirmation on returns 200 and no session.
            // Reporting that honestly beats appearing signed in and then failing
            // every request with no explanation.
            throw AuthError.confirmationRequired
        }

        let credentials = Credentials(
            userID: userID,
            accessToken: token,
            refreshToken: decoded.refresh_token ?? "",
            email: decoded.user?.email ?? fallbackEmail
        )
        current = credentials
        store.save(credentials)
        return credentials
    }

    private static func message(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (object["msg"] ?? object["error_description"] ?? object["message"]) as? String ?? ""
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable {
            let id: String?
            let email: String?
        }
        let access_token: String?
        let refresh_token: String?
        let user: User?
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case rejected(Int, String)
    /// The account exists but needs an emailed confirmation before it has a session.
    case confirmationRequired
    /// The refresh token was refused; the person has to sign in again.
    case sessionExpired

    public var userFacingMessage: String {
        switch self {
        case .confirmationRequired:
            "Check your email to confirm the account, then sign in."
        case .sessionExpired:
            "Your session expired. Sign in again to keep Cal remembering."
        case .rejected(_, let detail) where !detail.isEmpty:
            detail
        case .rejected:
            "That didn't work. Check the email and password and try again."
        }
    }
}

// MARK: - Token storage

/// Where the session token lives. A seam so tests never touch the Keychain.
public protocol TokenStoring: Sendable {
    func load() -> AuthSession.Credentials?
    func save(_ credentials: AuthSession.Credentials)
    func clear()
}

/// Keychain-backed, because an access token is a credential.
///
/// `UserDefaults` would be readable from a backup and from any process that can
/// see the container. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps it
/// off backups entirely, which matters here: guideline 5.1.3(ii) prohibits
/// storing personal health information in iCloud, and a token is the key to it.
public struct KeychainTokenStore: TokenStoring {
    private let account = "org.wholelifeministries.cal.session"

    public init() {}

    public func load() -> AuthSession.Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let userID = UUID(uuidString: stored.userID)
        else { return nil }

        return AuthSession.Credentials(
            userID: userID,
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            email: stored.email
        )
    }

    public func save(_ credentials: AuthSession.Credentials) {
        let stored = Stored(
            userID: credentials.userID.uuidString,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            email: credentials.email
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }

        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cal-auth",
            kSecAttrAccount as String: account,
        ]
    }

    private struct Stored: Codable {
        let userID: String
        let accessToken: String
        let refreshToken: String
        let email: String
    }
}

/// In-memory storage for tests and previews.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthSession.Credentials?

    public init(_ seed: AuthSession.Credentials? = nil) { self.stored = seed }

    public func load() -> AuthSession.Credentials? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ credentials: AuthSession.Credentials) {
        lock.lock(); defer { lock.unlock() }
        stored = credentials
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

extension URL {
    /// `appendingPathComponent` percent-encodes `?`, which breaks the
    /// `grant_type` query the token endpoint needs.
    fileprivate func appendingPathComponent2(_ path: String) -> URL {
        URL(string: absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) ?? self
    }
}
