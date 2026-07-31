import CalAI
import CalKit
import Foundation
import Testing

@testable import Cal

@Suite("Chat")
@MainActor
struct ChatViewModelTests {

    private func model(_ behaviour: MockCoachClient.Behaviour = .reply("Let's take one slow breath.")) -> ChatViewModel {
        ChatViewModel(coach: MockCoachClient(behaviour: behaviour))
    }

    /// Waits for streaming to settle rather than sleeping a fixed interval.
    private func settle(_ model: ChatViewModel, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !model.isStreaming && !model.messages.isEmpty { return }
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
