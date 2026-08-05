import CalData
import CalKit
import Foundation
import Supabase

/// Builds the one `SupabaseClient` the app uses.
///
/// `SupabaseClient` is `public final class ... : Sendable`, so it is safe to hold
/// from any actor and from `MainActor`-isolated code. `client.auth` is a
/// `public actor`, so auth calls hop; `currentSession` and `currentUser` are
/// `nonisolated` and readable without awaiting.
public enum CalSupabase {

    /// The coders are replaced, not configured — see `PostgresCoding` for the
    /// timestamp bug that makes this mandatory rather than tidy.
    /// - Parameter authStorage: where the session is persisted. Defaults to the
    ///   SDK's Keychain-backed store, which is right for the app. Tests pass an
    ///   in-memory one — otherwise a signed-in run leaves the next run already
    ///   authenticated, and assertions about the signed-out state pass or fail
    ///   depending on what ran before them.
    public static func makeClient(
        url: URL,
        anonKey: String,
        authStorage: (any AuthLocalStorage)? = nil
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(
                    encoder: PostgresCoding.makeEncoder(),
                    decoder: PostgresCoding.makeDecoder()
                ),
                auth: authStorage.map { SupabaseClientOptions.AuthOptions(storage: $0) }
                    ?? SupabaseClientOptions.AuthOptions()
            )
        )
    }

    /// The local development stack.
    ///
    /// The key is not a secret: it is a demo constant compiled into the Supabase
    /// CLI binary itself and identical for every project on every machine. It is
    /// in the repository deliberately, so a fresh checkout can run the integration
    /// tests without a setup step. A real project's key belongs in configuration,
    /// never here.
    public static let localURL = URL(string: "http://127.0.0.1:54321")!
    public static let localAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
        + "eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9."
        + "CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"

    public static func makeLocalClient() -> SupabaseClient {
        makeClient(url: localURL, anonKey: localAnonKey)
    }

}

/// Identity backed by a real account (ARCHITECTURE.md §15 step 3).
///
/// Slots behind `IdentityProviding` exactly where `LocalIdentity` was, so nothing
/// above it changes. The important property it must preserve: `currentProfileID()`
/// keeps returning *something* usable. Before sign-in that is the device-local id
/// the app has always used; after sign-in it is `auth.uid()`.
///
/// Email and password only. Sign in with Apple is not required by guideline 4.8
/// for an app using exclusively its own sign-in, cannot be enabled without a paid
/// Apple Developer Program membership, and would bring the token-revocation
/// obligation of 5.1.1(v) with no Supabase API to satisfy it (§15 step 2).
public actor SupabaseIdentity: IdentityProviding {
    private let client: SupabaseClient
    /// The identity used before anyone signs in. Delegating rather than
    /// reimplementing means the pre-sign-in behaviour is literally the same code
    /// that shipped in the MVP.
    private let local: any IdentityProviding

    public init(client: SupabaseClient, local: any IdentityProviding) {
        self.client = client
        self.local = local
    }

    public var isAuthenticated: Bool {
        client.auth.currentSession != nil
    }

    /// The signed-in user's id, or the device-local one when nobody is signed in.
    ///
    /// Deliberately does not throw when there is no session: the whole app is
    /// built to work without an account, and an identity that fails offline would
    /// break a check-in on the train.
    public func currentProfileID() async throws -> UUID {
        if let session = client.auth.currentSession {
            return session.user.id
        }
        return try await local.currentProfileID()
    }

    /// The id the *local* data is filed under, whether or not anyone is signed in.
    /// The claim migration needs both this and `currentProfileID()` to know what
    /// it is moving and where.
    public func localProfileID() async throws -> UUID {
        try await local.currentProfileID()
    }

    // MARK: Sessions

    @discardableResult
    public func signUp(email: String, password: String) async throws -> UUID {
        let response = try await client.auth.signUp(email: email, password: password)
        return response.user.id
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> UUID {
        let session = try await client.auth.signIn(email: email, password: password)
        return session.user.id
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }
}
