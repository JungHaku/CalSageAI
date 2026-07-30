import Foundation

/// How urgently a message needs a human, not a coach.
public enum CrisisSeverity: Int, Comparable, Codable, Sendable {
    case none = 0
    /// Distress that warrants gently surfacing resources alongside a normal reply.
    case elevated = 1
    /// Suppress the model entirely and present the crisis card (§9.2 Layer D).
    case acute = 2

    public static func < (lhs: CrisisSeverity, rhs: CrisisSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CrisisAssessment: Hashable, Sendable {
    public let severity: CrisisSeverity
    /// Which rule fired, recorded to `safety_events.matched_rule` (§5.2) so the
    /// weekly review with Dr. Mia can see *why* something triggered.
    public let matchedRule: String?

    public static let none = CrisisAssessment(severity: .none, matchedRule: nil)
}

/// Layer A of the safety pipeline (ARCHITECTURE.md §9.2): an on-device,
/// offline, zero-cost, zero-latency prefilter that runs *before* the message is
/// sent anywhere.
///
/// ## Deliberate design constraints
///
/// **This is not the whole pipeline.** It is one of four layers. It exists to
/// catch explicit, unambiguous phrasing instantly and without a network — which
/// is precisely the situation where a server classifier is useless. Nuance,
/// implication, and context are Layer B's job (server-side classifier), and this
/// list is intentionally *not* extended to chase them.
///
/// **Tuned for recall, not precision.** The cost matrix is asymmetric: a false
/// positive shows someone a card with a phone number on it, and a false negative
/// is the worst outcome this app can produce. Where a phrase is genuinely
/// ambiguous in student speech ("this exam makes me want to die"), it lands in
/// `.elevated` rather than `.acute`, so Cal still replies normally but offers
/// help alongside.
///
/// **Phrases students use non-literally are excluded outright.** "kill me",
/// "I can't do this anymore", and bare "hopeless" fire constantly in ordinary
/// exam-stress conversation; including them would train users to dismiss the
/// crisis card, which is worse than not showing it.
///
/// ⚠️ **This list requires review and sign-off by Dr. Mia and a licensed
/// clinician before launch**, and the fixtures in `CrisisFixture.all` are the
/// artifact to review — they're the regression suite (§11.2).
public struct CrisisDetector: Sendable {
    public init() {}

    /// Phrases that read as ordinary references to help-seeking or to the app's
    /// own resources, stripped before matching so they can't trigger on
    /// themselves. Without this, "where's the suicide prevention line?" — and
    /// Cal's own crisis copy quoted back — would fire as acute.
    private static let benignPhrases = [
        "suicide prevention", "suicide crisis line", "suicide hotline",
        "suicide and crisis lifeline", "crisis line", "crisis text line",
        "suicide prevention lifeline",
    ]

    private static let acutePatterns = [
        "kill myself", "killing myself", "killed myself",
        "end my life", "ending my life", "end my own life",
        "take my own life", "taking my own life",
        "suicide", "suicidal", "suicidality",
        "better off dead", "want to be dead",
        "dont want to be here anymore", "dont want to be alive",
        "dont want to wake up",
        "hang myself", "hanging myself",
        "not worth living", "life isnt worth living",
    ]

    private static let elevatedPatterns = [
        "want to die", "wanna die", "wish i was dead", "wish i were dead",
        "hurt myself", "hurting myself", "harm myself", "harming myself",
        "self harm", "selfharm",
        "cut myself", "cutting myself",
        "no reason to live", "nothing to live for",
        "overdose",
    ]

    public func evaluate(_ text: String) -> CrisisAssessment {
        let haystack = Self.normalize(text)
        guard !haystack.isEmpty else { return .none }

        // Acute wins over elevated, so check it first.
        for pattern in Self.acutePatterns where haystack.contains(" \(pattern) ") {
            return CrisisAssessment(severity: .acute, matchedRule: pattern)
        }
        for pattern in Self.elevatedPatterns where haystack.contains(" \(pattern) ") {
            return CrisisAssessment(severity: .elevated, matchedRule: pattern)
        }
        return .none
    }

    /// Lowercase, strip diacritics and apostrophes, reduce everything else
    /// non-alphanumeric to a single space, and pad with spaces so patterns can be
    /// matched on word boundaries without a regex engine.
    ///
    /// Apostrophes are removed rather than normalized so "don't", "don’t" and
    /// "dont" all collapse to the same token — patterns are stored in that form.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count + 2)
        out.append(" ")
        var lastWasSpace = true
        for character in folded {
            if character == "'" || character == "\u{2019}" { continue }
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if !lastWasSpace { out.append(" ") }

        for phrase in benignPhrases {
            out = out.replacingOccurrences(of: " \(phrase) ", with: " ")
        }
        return out
    }
}
