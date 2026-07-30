import CalKit
import Foundation
import Testing

@testable import CalAI

@Suite("MockCoachClient")
struct MockCoachClientTests {
    private func drain(_ stream: AsyncThrowingStream<CoachEvent, Error>) async throws -> [CoachEvent] {
        var events: [CoachEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func request(_ message: String, coherence: CoherenceSummary? = nil) -> CoachRequest {
        CoachRequest(surface: .chat, threadID: UUID(), message: message, coherence: coherence)
    }

    @Test("a normal message streams deltas and finishes with usage")
    func streamsDeltas() async throws {
        let events = try await drain(
            MockCoachClient(behaviour: .reply("one slow breath")).send(request("I'm stressed"))
        )

        let text = events.compactMap { if case .delta(let d) = $0 { d } else { nil } }.joined()
        #expect(text.trimmingCharacters(in: .whitespaces) == "one slow breath")

        guard case .finished(let usage)? = events.last else {
            Issue.record("stream did not finish with usage")
            return
        }
        #expect(usage.model == "gpt-5.6-luna")
    }

    // The whole point of Layer A: the model is never reached, so this path costs
    // nothing and works with no network (§9.2).
    @Test("an acute message is suppressed before the model and costs nothing")
    func acuteSuppressesTheModel() async throws {
        let events = try await drain(
            MockCoachClient(behaviour: .reply("this should never be sent")).send(request("I want to kill myself"))
        )

        #expect(events.contains { if case .crisis(.acute) = $0 { true } else { false } })
        #expect(!events.contains { if case .delta = $0 { true } else { false } })

        guard case .finished(let usage)? = events.last else {
            Issue.record("stream did not finish with usage")
            return
        }
        #expect(usage.costMicros == 0)
        #expect(usage.model == "none")
    }

    @Test("an elevated message still gets a normal reply, plus a resource signal")
    func elevatedRepliesAndFlags() async throws {
        let events = try await drain(
            MockCoachClient(behaviour: .reply("that sounds heavy")).send(request("this exam makes me want to die"))
        )
        #expect(events.contains { if case .delta = $0 { true } else { false } })
        #expect(events.contains { if case .crisis(.elevated) = $0 { true } else { false } })
    }

    // Budget exhaustion must never surface as an error — §10.4.
    @Test("budget exhaustion yields authored fallback copy, not a thrown error")
    func budgetFallbackIsNotAnError() async throws {
        let events = try await drain(MockCoachClient(behaviour: .budgetExhausted).send(request("hello")))
        guard case .fallback(let text)? = events.first else {
            Issue.record("expected a fallback event")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test("the coherence digest is what reaches the model, not raw history")
    func sendsOnlyTheDigest() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = LocalDate(iso: "2026-07-29")!
        let summary = CoherenceSummary.build(
            history: CheckIn.syntheticHistory(days: 14, endingOn: today, calendar: calendar),
            today: today,
            calendar: calendar
        )

        let events = try await drain(
            MockCoachClient(behaviour: .echoCoherenceDigest).send(request("how am I doing?", coherence: summary))
        )
        let sent = events.compactMap { if case .delta(let d) = $0 { d } else { nil } }.joined()
        #expect(sent == summary.promptText)
        #expect(sent.contains("avg coherence"))
    }

    @Test("transport failures propagate as thrown errors")
    func failuresThrow() async {
        await #expect(throws: MockCoachError.self) {
            for try await _ in MockCoachClient(behaviour: .failure).send(request("hello")) {}
        }
    }
}
