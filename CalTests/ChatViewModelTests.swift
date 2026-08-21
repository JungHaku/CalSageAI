import CalAI
import CalKit
import Foundation
import Testing

@testable import Cal

/// Wraps `MockCoachClient` and keeps every request, so the tests can assert what
/// actually left the view model rather than only what came back.
private final class RecordingCoachClient: CoachClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CoachRequest] = []
    private let inner: MockCoachClient

    init(_ behaviour: MockCoachClient.Behaviour) {
        self.inner = MockCoachClient(behaviour: behaviour)
    }

    var requests: [CoachRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, Error> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return inner.send(request)
    }
}

@Suite("Chat")
@MainActor
struct ChatViewModelTests {

    private func model(
        _ behaviour: MockCoachClient.Behaviour = .reply("Let's take one slow breath.")
    ) -> ChatViewModel {
        ChatViewModel(
            coach: MockCoachClient(behaviour: behaviour)
        )
    }

    private func recording(
        _ behaviour: MockCoachClient.Behaviour = .reply("ok")
    ) -> (ChatViewModel, RecordingCoachClient) {
        let coach = RecordingCoachClient(behaviour)
        let model = ChatViewModel(coach: coach)
        return (model, coach)
    }

    /// Waits for streaming to settle rather than sleeping a fixed interval.
    private func settle(_ model: ChatViewModel, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !model.isStreaming && !model.messages.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A suppressed turn produces no assistant message, so `settle` — which waits
    /// for one — is the wrong condition to wait on.
    private func settleCrisis(_ model: ChatViewModel, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a reply arrives and both turns are kept in order")
    func replyArrives() async throws {
        let model = model()
        model.draft = "I have a chemistry exam"
        model.send()
        try await settle(model)

        #expect(model.messages.count == 2)
        #expect(model.messages[0].role == .user)
        #expect(model.messages[0].text == "I have a chemistry exam")
        #expect(model.messages[1].role == .assistant)
        #expect(!model.messages[1].text.isEmpty)
        #expect(model.streamingText.isEmpty, "the in-progress buffer must be cleared once finished")
        #expect(!model.isStreaming)
    }

    @Test("the draft clears on send so the field is empty for the next message")
    func draftClears() async throws {
        let model = model()
        model.draft = "hello"
        model.send()
        #expect(model.draft.isEmpty)
        try await settle(model)
    }

    @Test("an empty or whitespace draft cannot be sent")
    func emptyDraftIgnored() {
        let model = model()
        for text in ["", "   ", "\n\t"] {
            model.draft = text
            #expect(!model.canSend)
            model.send()
            #expect(model.messages.isEmpty, "sent \(text.debugDescription)")
        }
    }

    // MARK: Memory — conversation

    /// Without this the coach answers every message cold, and "Cal remembers me"
    /// is false however good the prompt is.
    @Test("the previous turns travel with the next message")
    func historyIsSent() async throws {
        let (model, coach) = recording()

        model.draft = "I have a chemistry exam"
        model.send()
        try await settle(model)

        model.draft = "it's tomorrow"
        model.send()
        try await settle(model)

        let second = try #require(coach.requests.last)
        #expect(second.message == "it's tomorrow")
        #expect(second.history.count == 2, "the first exchange should have been carried")
        #expect(second.history.first?.role == .user)
        #expect(second.history.first?.text == "I have a chemistry exam")
        #expect(second.history.last?.role == .assistant)
    }

    @Test("the first message carries no history")
    func firstMessageHasNoHistory() async throws {
        let (model, coach) = recording()
        model.draft = "hello"
        model.send()
        try await settle(model)

        #expect(coach.requests.first?.history.isEmpty == true)
    }

    /// The message being sent must not appear in its own history, or the model
    /// sees it twice and reads the repetition as emphasis.
    @Test("a message is not included in its own history")
    func messageIsNotInItsOwnHistory() async throws {
        let (model, coach) = recording()
        model.draft = "only once"
        model.send()
        try await settle(model)

        let request = try #require(coach.requests.first)
        #expect(!request.history.contains { $0.text == "only once" })
    }

    /// The end-to-end version of `ConversationWindowTests.acuteIsNeverCarried`:
    /// the prefilter suppresses the model on the turn itself, and this asserts it
    /// is not quietly handed over on the *next* turn instead.
    @Test("an acute message is never carried into a later request")
    func acuteNeverTravels() async throws {
        let (model, coach) = recording()

        model.draft = "I want to kill myself"
        model.send()
        try await settleCrisis(model)
        #expect(model.crisis == .acute)

        model.draft = "sorry, I meant the exam is brutal"
        model.send()
        try await settle(model)

        let follow = try #require(coach.requests.last)
        #expect(
            !follow.history.contains { $0.text.contains("kill myself") },
            "suppressed content must not reach the model one turn later"
        )
        #expect(
            model.messages.contains { $0.text.contains("kill myself") },
            "it stays on the person's screen — it just doesn't travel"
        )
    }

    // MARK: Memory — no numeric digest

    @Test("no coherence digest is sent — there is no rating in this app")
    func noDigest() async throws {
        let (model, coach) = recording()
        model.draft = "how am I doing"
        model.send()
        try await settle(model)

        #expect(coach.requests.first?.coherence == nil)
    }

    // MARK: Safety

    /// The behaviour that matters most in this file. The on-device prefilter runs
    /// before anything is sent; on `.acute` the model is suppressed and the person
    /// must not be shown a coaching reply.
    @Test("an acute crisis suppresses the reply and raises the card")
    func acuteCrisisSuppressesTheModel() async throws {
        let model = model()
        model.draft = "I want to kill myself"
        model.send()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.crisis == .acute)
        #expect(
            model.messages.filter { $0.role == .assistant }.isEmpty,
            "no coaching reply may be shown alongside a crisis card"
        )
        #expect(model.streamingText.isEmpty)
    }

    /// The person's own message is kept. Erasing what someone just said in a
    /// moment of distress would be its own harm.
    @Test("a crisis keeps the person's own message on screen")
    func crisisKeepsTheUserMessage() async throws {
        let model = model()
        model.draft = "I want to kill myself"
        model.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.messages.first?.role == .user)
    }

    @Test("acknowledging the crisis card leaves the conversation intact")
    func acknowledgingKeepsHistory() async throws {
        let model = model()
        model.draft = "I want to kill myself"
        model.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }

        model.acknowledgeCrisis()
        #expect(model.crisis == .none)
        #expect(!model.messages.isEmpty, "dismissing the card must not wipe the thread")
    }

    /// A later ordinary message must not silently clear a crisis that is still on
    /// screen — but starting a new turn resets it, because the new message gets
    /// its own assessment.
    @Test("a new message re-evaluates safety rather than inheriting the last verdict")
    func safetyIsPerMessage() async throws {
        let model = model()
        model.draft = "I want to kill myself"
        model.send()
        var deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.crisis == .acute)

        model.draft = "what should I eat"
        model.send()
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.crisis == .none, "an ordinary message should not stay flagged")
    }

    // MARK: Degradation

    /// A budget limit is a *successful* response carrying authored copy. It must
    /// read as Cal talking, not as a failure — the person should never be shown an
    /// error because of our cost controls.
    @Test("a budget fallback reads as a reply, not as an error")
    func fallbackIsNotAnError() async throws {
        let model = model(.budgetExhausted)
        model.draft = "hello"
        model.send()
        try await settle(model)

        #expect(!model.failed, "a fallback is not a failure")
        let reply = try #require(model.messages.last)
        #expect(reply.role == .assistant)
        #expect(!reply.text.isEmpty)
    }

    @Test("a thrown failure is surfaced and does not leave the spinner running")
    func failureSurfaces() async throws {
        let model = model(.failure)
        model.draft = "hello"
        model.send()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && model.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.failed)
        #expect(!model.isStreaming, "the composer must not stay disabled after a failure")
        #expect(model.messages.first?.role == .user, "the person's message is still theirs")
    }

    @Test("sending is blocked while a reply is still streaming")
    func noConcurrentSends() async throws {
        let model = model()
        model.draft = "first"
        model.send()
        // Mid-flight: a second send must be refused rather than interleaving two
        // replies into one buffer.
        model.draft = "second"
        model.send()
        try await settle(model)

        let userMessages = model.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1, "a second send got through while streaming")
    }
}
