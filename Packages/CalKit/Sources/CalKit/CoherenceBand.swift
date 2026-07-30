import Foundation

/// Which of the three response bands a score falls in, per the free-tier spec:
/// 8–10, 5–7, 0–4.
public enum CoherenceBand: String, CaseIterable, Codable, Sendable {
    case low        // 0–4
    case moderate   // 5–7
    case high       // 8–10

    public init(_ score: Score) {
        switch score.value {
        case 8...10: self = .high
        case 5...7:  self = .moderate
        default:     self = .low
        }
    }

    /// Cal's reply on the free quick check-in. Verbatim from the spec; like all
    /// authored copy the server version wins when present (see `CoherenceQuestion`).
    public var quickCheckInResponse: String {
        switch self {
        case .high:     "Great. Let's keep that momentum going."
        case .moderate: "You seem a little stressed today. Let's stay aware."
        case .low:      "I've got you. Let's take one minute together."
        }
    }
}

/// Whether a score routes the user into a regulation exercise.
///
/// ⚠️ The two specs use **different thresholds**, and this is not a
/// simplification — it's what the documents say:
///
/// - Free ("Free Cal" §1): the guided-breathing branch is the `0–4` band. A
///   score of **5** gets "let's stay aware" and *no* exercise.
/// - Premium ("Cal+ Coherence"): "If a score is **5 or below**, Cal immediately
///   guides the user through a brief regulation exercise."
///
/// So a 5 regulates on premium but not on free. Both are implemented faithfully
/// rather than averaged. Flagged for Dr. Mia to confirm it's intentional
/// (ARCHITECTURE.md §20) — if it isn't, this is the single line to change.
public enum RegulationPolicy: String, CaseIterable, Sendable {
    /// Free tier, single `.overall` question.
    case quick
    /// Premium tier, ten categories.
    case full

    public var triggersAtOrBelow: Int {
        switch self {
        case .quick: 4
        case .full:  5
        }
    }

    public func needsRegulation(_ score: Score) -> Bool {
        score.value <= triggersAtOrBelow
    }
}
