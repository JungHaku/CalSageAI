import CalKit
import Foundation
import Testing

@testable import CalAI

@Suite("Conversation window")
struct ConversationWindowTests {

    /// `turns` pairs, oldest first: user then assistant, numbered so order is
    /// assertable.
    private func thread(turns: Int) -> [CoachMessage] {
        (0..<turns).flatMap { index in
            [
                CoachMessage(role: .user, text: "u\(index)"),
                CoachMessage(role: .assistant, text: "a\(index)"),
            ]
        }
    }

    @Test("a short thread is carried whole")
    func shortThreadIsWhole() {
        let messages = thread(turns: 3)
        #expect(ConversationWindow.history(from: messages).map(\.text) == messages.map(\.text))
    }

    @Test("an empty thread produces no history")
    func emptyThread() {
        #expect(ConversationWindow.history(from: []).isEmpty)
    }

    @Test("a long thread keeps the most recent turns, oldest first")
    func longThreadIsCapped() {
        let carried = ConversationWindow.history(from: thread(turns: 10), maxTurns: 6)

        #expect(carried.count == 12, "6 turns is 6 user messages and 6 replies")
        #expect(carried.first?.text == "u4", "the window keeps the *last* 6 turns")
        #expect(carried.last?.text == "a9")
        #expect(carried.first?.role == .user, "history must not open on a dangling reply")
    }

    /// The rule this whole type exists for. Suppressing self-harm content on the
    /// turn it is typed and then shipping it in the next turn's history would
    /// hand it to the model one message later — defeating the on-device layer
    /// entirely rather than delaying it.
    @Test("an acute message never travels")
    func acuteIsNeverCarried() {
        let messages = [
            CoachMessage(role: .user, text: "the exam is brutal"),
            CoachMessage(role: .assistant, text: "that sounds heavy"),
            CoachMessage(role: .user, text: "I want to kill myself", safety: .acute),
            CoachMessage(role: .user, text: "sorry, I meant the exam"),
        ]

        let carried = ConversationWindow.history(from: messages)

        #expect(!carried.contains { $0.safety == .acute })
        #expect(!carried.contains { $0.text.contains("kill myself") })
        #expect(carried.count == 3, "everything else in the thread survives")
    }

    /// Elevated content already reaches the model by design — the reply proceeds
    /// and resources ride alongside it. Dropping it here would make Cal forget a
    /// conversation it was part of.
    @Test("an elevated message is still carried")
    func elevatedIsCarried() {
        let messages = [
            CoachMessage(role: .user, text: "some days I want to die", safety: .elevated),
            CoachMessage(role: .assistant, text: "I'm glad you told me"),
        ]

        #expect(ConversationWindow.history(from: messages).count == 2)
    }

    @Test("filtering an acute message does not leave a dangling reply at the front")
    func windowStartsOnAUserMessage() {
        var messages: [CoachMessage] = []
        for index in 0..<8 {
            messages.append(
                CoachMessage(
                    role: .user, text: "u\(index)", safety: index == 2 ? .acute : CrisisSeverity.none
                )
            )
            messages.append(CoachMessage(role: .assistant, text: "a\(index)"))
        }

        let carried = ConversationWindow.history(from: messages, maxTurns: 6)
        #expect(carried.first?.role == .user)
        #expect(!carried.contains { $0.text == "u2" })
    }

    @Test("a zero-turn window sends nothing")
    func zeroTurns() {
        #expect(ConversationWindow.history(from: thread(turns: 4), maxTurns: 0).isEmpty)
    }
}
