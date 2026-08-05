import Foundation

/// Which Supabase project the app talks to.
///
/// Lives in `CalData` rather than `CalRemote` for a mundane reason worth writing
/// down: `CalRemote` is not linked to the app target — only `CalData` and
/// `CalStore` are — so anything the app itself must read at launch has to be
/// here. `CalRemote` remains the home of the `SupabaseClient` used by the
/// integration tests.
///
/// ## Why this is configuration and not a constant
///
/// Read from `Info.plist` so the project can be changed, or a build pointed at a
/// staging project, without editing code. When the keys are absent this returns
/// `nil` and callers fall back to the local stack — which is what keeps a fresh
/// checkout working with no setup step.
///
/// ## Why the key in here is not a secret
///
/// The publishable (anon) key identifies the project and grants nothing on its
/// own: every row it can reach is governed by row-level security, so the policies
/// in `supabase/migrations` are the actual protection. Shipping it is expected and
/// documented by Supabase.
///
/// The key that genuinely must not ship is the OpenAI one, and it is not in this
/// binary at all — it lives in the Edge Function's environment. An `.ipa` is a zip
/// and its strings come out in minutes, which is the entire reason the coach proxy
/// exists (ARCHITECTURE.md §8.1). Keep that distinction: *this* file holding a key
/// is fine; a provider key here would not be.
public enum BackendConfiguration {

    public struct Backend: Sendable, Equatable {
        public let url: URL
        public let anonKey: String

        public init(url: URL, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }

        /// Where the coach proxy answers for this project.
        public var coachEndpoint: URL {
            url.appendingPathComponent("functions/v1/coach")
        }
    }

    /// The local development stack, served by `supabase start`.
    ///
    /// The key is not merely non-secret, it is a *demo constant compiled into the
    /// Supabase CLI* — byte-identical on every machine and every project. It is
    /// committed deliberately so the local stack needs no configuration.
    public static let local = Backend(
        url: URL(string: "http://127.0.0.1:54321")!,
        anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            + "eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9."
            + "CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    )

    /// The configured project, or `nil` when the bundle names none.
    public static func hosted(in bundle: Bundle = .main) -> Backend? {
        guard
            let raw = bundle.object(forInfoDictionaryKey: "CalSupabaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw),
            let key = bundle.object(forInfoDictionaryKey: "CalSupabaseAnonKey") as? String,
            !key.isEmpty
        else { return nil }
        return Backend(url: url, anonKey: key)
    }

    /// What the app should actually use.
    ///
    /// - Parameter isUITesting: forces the local stack. A UI test that registered
    ///   accounts against the real project would fill it with rubbish on every run
    ///   and spend money doing it.
    public static func resolve(isUITesting: Bool, bundle: Bundle = .main) -> Backend {
        isUITesting ? local : (hosted(in: bundle) ?? local)
    }
}
