import CalKit
import Foundation

/// Deterministic `CoachClient` for previews, UI tests, and the `-CalUseMockCoach 1`
/// launch argument (ARCHITECTURE.md §11.4).
///
/// Runs the same on-device crisis prefilter the real path does, so the crisis
/// flow is exercised end to end in tests without a network call or a cent spent.
public struct MockCoachClient: CoachClient {
    public enum Behaviour: Sendable {
        case reply(String)
        case echoCoherenceDigest
        case budgetExhausted
        case failure
    }

    private let behaviour: Behaviour
    private let detector = CrisisDetector()

    /// The default reply carries **emphasis** deliberately.
    ///
    /// The live model writes markdown, and the mock previously replied in plain
    /// prose — so every test, preview and demo exercised a rendering path the
    /// real one never took, and `Text(someString)` silently showing raw asterisks
    /// got all the way to a live run before anyone saw it. A mock that is tidier
    /// than production hides exactly the bugs production has.
    ///
    /// The wording follows the system prompt's own "offer, don't instruct" rule.
    public init(
        behaviour: Behaviour = .reply("That sounds heavy. Would it help to take **one slow breath** together?")
    ) {
        self.behaviour = behaviour
    }

    public func send(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, Error> {
        AsyncThrowingStream { continuation in
            // Safety runs before anything else, exactly as in the Edge Function.
            let assessment = detector.evaluate(request.message)
            if assessment.severity == .acute {
                continuation.yield(.crisis(.acute))
                continuation.yield(.finished(Self.freeUsage))
                continuation.finish()
                return
            }

            switch behaviour {
            case .failure:
                continuation.finish(throwing: MockCoachError.simulated)

            case .budgetExhausted:
                continuation.yield(.fallback("I'm taking a short break. Your breathing exercises are all still here."))
                continuation.yield(.finished(Self.freeUsage))
                continuation.finish()

            case .echoCoherenceDigest:
                continuation.yield(.delta(request.coherence?.promptText ?? "(no coherence data)"))
                if assessment.severity == .elevated { continuation.yield(.crisis(.elevated)) }
                continuation.yield(.finished(Self.stubUsage))
                continuation.finish()

            case .reply(let text):
                // Chunked so streaming UI is actually exercised, not bypassed.
                for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                    continuation.yield(.delta(String(word) + " "))
                }
                if assessment.severity == .elevated { continuation.yield(.crisis(.elevated)) }
                continuation.yield(.finished(Self.stubUsage))
                continuation.finish()
            }
        }
    }

    /// Authored/suppressed paths cost nothing — that is the point of §8.2.
    static let freeUsage = CoachUsage(
        model: "none", promptVersion: "authored",
        inputTokens: 0, cachedTokens: 0, outputTokens: 0, costMicros: 0
    )

    static let stubUsage = CoachUsage(
        model: "gpt-5.6-luna", promptVersion: "mock",
        inputTokens: 3_500, cachedTokens: 3_150, outputTokens: 350, costMicros: 2_770
    )
}

public enum MockCoachError: Error, Sendable {
    case simulated
}
