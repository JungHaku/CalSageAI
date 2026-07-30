import Foundation

/// The coherence dimensions Cal rates. Mirrors the `coherence_category` Postgres
/// enum exactly (ARCHITECTURE.md §5.2) — keep the raw values in sync with the
/// migration, they are the wire format.
///
/// `.overall` is the free tier's single daily question; the other ten are
/// Dr. Mia's premium framework, in her stated order.
public enum CoherenceCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case overall
    case safety
    case breath
    case presence
    case emotionalFlow      = "emotional_flow"
    case bodyAwareness      = "body_awareness"
    case choice
    case connection
    case energy
    case innerKnowing       = "inner_knowing"
    case authenticExpression = "authentic_expression"

    public var id: String { rawValue }

    /// The ten premium questions, in the order Dr. Mia specified.
    public static let fullCheckIn: [CoherenceCategory] = [
        .safety, .breath, .presence, .emotionalFlow, .bodyAwareness,
        .choice, .connection, .energy, .innerKnowing, .authenticExpression,
    ]
}

/// The authored copy for one category.
///
/// This is Dr. Mia's clinical language and it is *content*, not code
/// (ARCHITECTURE.md §8.1). The canonical copy lives in Postgres so she can edit
/// it without an App Store release; what's below is the bundled seed that ships
/// in the binary so a fresh install works before its first sync and in airplane
/// mode (§7). When the server has a newer version, the server wins.
public struct CoherenceQuestion: Hashable, Sendable, Codable {
    public let category: CoherenceCategory
    /// Asked at the start of the check-in.
    public let prompt: String
    /// Asked again after a regulation exercise, to capture `score_after`.
    public let rePrompt: String
    /// What Cal guides when the score triggers regulation. Placeholder-level
    /// detail until Dr. Mia supplies word-for-word scripts (§20 item 6) —
    /// the real script lives in `exercises.script` as structured steps.
    public let regulationSummary: String

    public init(category: CoherenceCategory, prompt: String, rePrompt: String, regulationSummary: String) {
        self.category = category
        self.prompt = prompt
        self.rePrompt = rePrompt
        self.regulationSummary = regulationSummary
    }
}

extension CoherenceQuestion {
    public static let seed: [CoherenceCategory: CoherenceQuestion] = {
        let all: [CoherenceQuestion] = [
            .init(category: .overall,
                  prompt: "How do you feel right here in the moment?",
                  rePrompt: "How do you feel now?",
                  regulationSummary: "Guided breathing."),
            .init(category: .safety,
                  prompt: "How safe does your body feel as a place to live right now?",
                  rePrompt: "How safe does your body feel now?",
                  regulationSummary: "A grounding exercise and slow breathing."),
            .init(category: .breath,
                  prompt: "How freely is your breath moving into your heart and belly right now?",
                  rePrompt: "How does your breath feel now?",
                  regulationSummary: "Embodied Vital Breathwork\u{2122}."),
            .init(category: .presence,
                  prompt: "How present do you feel right here in this moment?",
                  rePrompt: "How present do you feel now?",
                  regulationSummary: "A mindfulness exercise using the senses."),
            .init(category: .emotionalFlow,
                  prompt: "How freely are your emotions moving without feeling stuck or overwhelming?",
                  rePrompt: "How does your emotional flow feel now?",
                  regulationSummary: "Emotional regulation through breath, awareness, and allowing."),
            .init(category: .bodyAwareness,
                  prompt: "How connected do you feel to your body right now?",
                  rePrompt: "How connected do you feel now?",
                  regulationSummary: "Gently wiggle your fingers and toes, notice your feet on the floor, and reconnect with physical sensation."),
            .init(category: .choice,
                  prompt: "How much do you feel you are responding by choice instead of reacting automatically?",
                  rePrompt: "How much choice do you feel now?",
                  regulationSummary: "A pause-and-reflect exercise."),
            .init(category: .connection,
                  prompt: "How connected do you feel to yourself and to the people around you today?",
                  rePrompt: "How connected do you feel now?",
                  regulationSummary: "A simple connection practice."),
            .init(category: .energy,
                  prompt: "How much healthy energy is available to you right now?",
                  rePrompt: "How energized do you feel now?",
                  regulationSummary: "Posture, breathing, and gentle movement."),
            .init(category: .innerKnowing,
                  prompt: "How clearly can you hear and trust your inner knowing right now?",
                  rePrompt: "How connected do you feel to your inner knowing now?",
                  regulationSummary: "A short quiet reflection."),
            .init(category: .authenticExpression,
                  prompt: "How free do you feel to express your true self today?",
                  rePrompt: "How free do you feel to express yourself now?",
                  regulationSummary: "A brief reflection on what feels held back, and an invitation to one small authentic action."),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.category, $0) })
    }()

    /// Bundled seed copy for `category`. Non-optional by construction — there's
    /// a test asserting every case is present.
    public static func seeded(_ category: CoherenceCategory) -> CoherenceQuestion {
        seed[category] ?? .init(category: category, prompt: "", rePrompt: "", regulationSummary: "")
    }
}
