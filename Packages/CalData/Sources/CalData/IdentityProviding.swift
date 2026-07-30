import CalKit
import Foundation

/// Who the data belongs to (ARCHITECTURE.md §2).
///
/// The MVP has no accounts, so `LocalIdentity` mints a UUID on first launch and
/// that is the identity. At Phase B `SupabaseIdentity` returns `auth.uid()`
/// instead, and the **claim migration** pushes every locally-created row under the
/// new id — which works only because ids are generated on-device and never
/// reassigned.
///
/// Nothing above this protocol may assume there is exactly one user. In the MVP
/// there is, implicitly; code that bakes that in stays broken when there are two.
public protocol IdentityProviding: Sendable {
    /// The profile this device's data belongs to. Creates one on first call.
    func currentProfileID() async throws -> UUID

    /// `false` throughout the MVP. Phase B flips it once a real account exists,
    /// and it is the signal that the claim migration should run.
    var isAuthenticated: Bool { get async }
}

/// MVP identity: a single device-local profile.
public actor LocalIdentity: IdentityProviding {
    private let profiles: any ProfileStoring

    public init(profiles: any ProfileStoring) {
        self.profiles = profiles
    }

    public var isAuthenticated: Bool { false }

    public func currentProfileID() async throws -> UUID {
        // Resolved through the profile store rather than UserDefaults, so identity
        // and profile data live together and "delete everything" is one purge.
        if let existing = try await profiles.current() {
            return existing.id
        }
        let created = Profile()
        try await profiles.save(created)
        return created.id
    }
}
