import Foundation

/// What the person is entitled to. The *policy* of the paid tier lives here, in
/// the pure package, so "what does paying actually unlock" is unit-tested rather
/// than scattered through view code and trusted.
///
/// StoreKit resolves which case applies; nothing in this file knows StoreKit
/// exists (ARCHITECTURE.md §2 — the seam is `EntitlementProviding` in `CalStore`).
public enum Entitlement: String, Codable, Sendable, CaseIterable, Hashable {
    /// "Free C.A.L" — the tier from `SPEC-free.md`.
    case free
    /// "C.A.L+ Coherence" — the paid tier from `SPEC-premium.md`.
    case plus

    /// The default. A fresh install, a lapsed subscription, and a StoreKit lookup
    /// that failed all land here — deliberately, see `EntitlementProviding`.
    public static let `default` = Entitlement.free

    public func unlocks(_ feature: PremiumFeature) -> Bool {
        switch self {
        case .plus: true
        case .free: false
        }
    }
}

/// The surfaces the paid tier gates.
///
/// ⚠️ This list is deliberately short, and shorter than `SPEC-premium.md`.
/// It names only what is **built and working today**. Her premium spec also
/// promises the AI Coherence Coach, the AI Journal, the Personalized Daily Action
/// Plan, the Weekly Coherence Review, Community sessions, and a fifteen-title
/// library against the five practices that are actually authored. None of those
/// exist yet, so none of them may be sold or listed as included — see
/// `docs/LAUNCH-REQUIREMENTS.md` §18.4 on guideline 2.3.1. Add a case here when
/// the feature ships, not when it is planned.
public enum PremiumFeature: String, CaseIterable, Codable, Sendable, Hashable {
    /// The browsable guided library.
    case practiceLibrary
}

extension PremiumFeature {
    /// Things that must work for everyone, forever, whatever the entitlement says.
    ///
    /// This is not a feature list — it's a standing constraint, written down so it
    /// survives someone later looking for another thing to gate. Each entry earns
    /// its place:
    ///
    /// - **Emergency help.** One tap from every screen (§9.2). Obvious, and
    ///   obvious things get broken by refactors, so it is asserted in a test.
    /// - **Their own journal, and the export of it.** Gating what someone can
    ///   *create* is a product decision. Hiding what they already created is
    ///   taking their data hostage.
    public static let neverGated: Set<String> = [
        "emergency-help",
        "own-journal",
        "data-export",
    ]
}
