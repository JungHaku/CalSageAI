import CalKit
import Foundation

/// How much of the conversation travels with each request.
///
/// Pure, so the two rules below are unit-tested rather than trusted to a view
/// model. Both of them are easy to get wrong in a way nothing visibly breaks:
/// the cap only shows up on an invoice, and the crisis rule only shows up in the
/// one conversation nobody wants to be reading transcripts of.
public enum ConversationWindow {

    /// Turns carried forward, where a turn is one message and its reply.
    ///
    /// Six is ARCHITECTURE §10.4 item 4 ("rolling summary + last 6 turns"). The
    /// summary half of that is the coherence digest, which is a fixed ~50 tokens
    /// regardless of how long the conversation is — so this cap is the only thing
    /// standing between a long thread and an unbounded prompt.
    public static let maxTurns = 6

    /// The slice of `messages` to send with the next request, oldest first.
    ///
    /// Two rules, in this order:
    ///
    /// **1. A message assessed `.acute` never travels.** This is the one that
    /// matters. The on-device prefilter exists so that explicit self-harm content
    /// never reaches the model (`LiveCoachClient.send`) — but suppressing it on
    /// the turn it was typed and then carrying it in the *next* turn's history
    /// would hand it to the model one message later and defeat the whole layer.
    /// The message stays on screen, because erasing what someone just said in a
    /// moment of distress would be its own harm; it simply never leaves the phone.
    ///
    /// `.elevated` is deliberately *not* excluded: those already reach the model
    /// by design — the reply proceeds and resources ride alongside it — so
    /// dropping them from history would make Cal forget a conversation it was
    /// part of.
    ///
    /// **2. The window starts on a user message.** Opening the history with a
    /// dangling assistant reply gives the model an answer to a question it cannot
    /// see.
    public static func history(
        from messages: [CoachMessage],
        maxTurns: Int = Self.maxTurns
    ) -> [CoachMessage] {
        guard maxTurns > 0 else { return [] }

        let carried = messages.filter { $0.safety != .acute }
        let userTurns = carried.indices.filter { carried[$0].role == .user }
        guard userTurns.count > maxTurns else { return carried }

        return Array(carried[userTurns[userTurns.count - maxTurns]...])
    }
}
