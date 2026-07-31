import CalKit
import Foundation

/// Which AI surface a request belongs to. Determines the prompt version, the
/// model tier, and the budget bucket in `ai_usage` (ARCHITECTURE.md §8.2, §10.2).
public enum CoachSurface: String, Codable, Sendable {
    case chat
    case navigate
    case journalReflection = "journal_reflection"
    case weeklyReview      = "weekly_review"
    case actionPlan        = "action_plan"
}

public struct CoachMessage: Hashable, Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public let text: String
    public let createdAt: Date
    /// Non-`.none` when the safety pipeline acted on this message (§9.2).
    public var safety: CrisisSeverity

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        safety: CrisisSeverity = .none
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.safety = safety
    }
}

/// One chunk of a streamed reply.
public enum CoachEvent: Sendable {
    /// A token/text delta to append to the visible reply.
    case delta(String)
    /// The safety pipeline suppressed the model and this is authored copy. The UI
    /// must present the crisis card, not a normal chat bubble (§9.2 Layer D).
    case crisis(CrisisSeverity)
    /// Budget exhausted or the kill switch is on; `text` is authored fallback
    /// copy. Deliberately not an error — the user should never see a failure
    /// because of our cost controls (§10.4).
    case fallback(String)
    case finished(CoachUsage)
}

/// What a completed request cost. Persisted to `chat_messages` and `ai_usage` so
/// cost-per-active-user is on a dashboard in week one rather than on an invoice
/// in month three (§10.4).
public struct CoachUsage: Hashable, Codable, Sendable {
    public let model: String
    public let promptVersion: String
    public let inputTokens: Int
    /// Tokens served from the provider's prompt cache. A test asserts this is
    /// non-zero in steady state — that's how a prompt reordering that silently
    /// killed the cache gets caught (§10.4).
    public let cachedTokens: Int
    public let outputTokens: Int
    public let costMicros: Int

    public init(
        model: String,
        promptVersion: String,
        inputTokens: Int,
        cachedTokens: Int,
        outputTokens: Int,
        costMicros: Int
    ) {
        self.model = model
        self.promptVersion = promptVersion
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.costMicros = costMicros
    }
}

public struct CoachRequest: Sendable {
    public let surface: CoachSurface
    public let threadID: UUID
    public let message: String
    /// Prior turns, oldest first, already windowed by `ConversationWindow`.
    ///
    /// The client carries these because the proxy keeps no state — there is no
    /// session on the server, deliberately (§10.4 item 4 caps the context rather
    /// than accumulating one).
    public let history: [CoachMessage]
    /// The compact digest from §8.3 — never raw journal text or full history.
    public let coherence: CoherenceSummary?

    public init(
        surface: CoachSurface,
        threadID: UUID,
        message: String,
        history: [CoachMessage] = [],
        coherence: CoherenceSummary? = nil
    ) {
        self.surface = surface
        self.threadID = threadID
        self.message = message
        self.history = history
        self.coherence = coherence
    }
}

/// The boundary between the app and anything that talks to a language model.
///
/// Everything behind this protocol is a call to our own Supabase Edge Function,
/// never to a provider directly — there is no API key in this binary (§8.1).
/// The protocol exists so that previews and UI tests can inject
/// `MockCoachClient` and never spend money or touch the network (§11.4).
public protocol CoachClient: Sendable {
    func send(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, Error>
}
