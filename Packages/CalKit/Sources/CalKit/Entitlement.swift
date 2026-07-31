import Foundation

/// What the person is entitled to. The *policy* of the paid tier lives here, in
/// the pure package, so "what does paying actually unlock" is unit-tested rather
/// than scattered through view code and trusted.
///
/// StoreKit resolves which case applies; nothing in this file knows StoreKit
/// exists (ARCHITECTURE.md §2 — the seam is `EntitlementProviding` in `CalStore`).
public enum Entitlement: String, Codable, Sendable, CaseIterable, Hashable {
    /// "Free Cal" — the tier from `SPEC-free.md`.
    case free
    /// "Cal+ Coherence" — the paid tier from `SPEC-premium.md`.
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

    /// Which check-in the person gets. This is the one place the tier turns into
    /// a flow, and both flows are Dr. Mia's — the free single question from
    /// `SPEC-free.md` §1 and the ten-category framework from `SPEC-premium.md`.
    public var checkInKind: CheckInKind {
        switch self {
        case .free: .quick
        case .plus: .full
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
    /// The ten-category framework, versus the free tier's single question.
    case fullCheckIn
    /// The Progress screen: coherence over time, per-category before/after,
    /// daily/weekly/monthly bucketing.
    case coherenceAnalytics
    /// The browsable guided library. Regulation *inside* a check-in is not this —
    /// see `neverGated`.
    case practiceLibrary
}

extension PremiumFeature {
    /// Things that must work for everyone, forever, whatever the entitlement says.
    ///
    /// This is not a feature list — it's a standing constraint, written down so it
    /// survives someone later looking for another thing to gate. Each entry earns
    /// its place:
    ///
    /// - **Regulation during a check-in.** The free check-in routes a low score
    ///   into guided breathing (`SPEC-free.md` §1). A student in distress reaches
    ///   the exercise whether or not they pay. Putting a price on the calming-down
    ///   step of a wellness app is the version of this product I won't build.
    /// - **Emergency help.** One tap from every screen (§9.2). Obvious, and
    ///   obvious things get broken by refactors, so it is asserted in a test.
    /// - **Their own history, and the export of it.** Gating what someone can
    ///   *create* is a product decision. Hiding what they already created is
    ///   taking their data hostage, and it would undercut the deletion and
    ///   portability posture in §18 besides. A lapsed subscriber still sees every
    ///   check-in they made and can still export the lot.
    public static let neverGated: Set<String> = [
        "regulation-exercise-in-check-in",
        "emergency-help",
        "own-history",
        "data-export",
    ]
}
