import CalAI
import CalKit
import Foundation
import Observation

/// The state behind "Chat with C.A.L".
///
/// Separated from the view so the parts that matter — what happens when the
/// stream yields a crisis, what happens when it fails mid-reply, what the person
/// is left looking at — are unit-testable without a simulator.
///
/// Everything it talks to is `CoachClient`, which in the MVP is `MockCoachClient`.
/// The screen therefore works today with no API key and no backend; swapping in
/// the Edge Function-backed client at Phase B step 7 changes nothing here.
@Observable
@MainActor
final class ChatViewModel {
    /// Completed turns, in order.
    private(set) var messages: [CoachMessage] = []
    /// The reply currently arriving, token by token. Kept separate from
    /// `messages` so a partial reply is never mistaken for a finished one — and
    /// so a failure mid-stream can keep what arrived rather than discarding it.
    private(set) var streamingText = ""
    private(set) var isStreaming = false

    /// Set when the safety pipeline acted. `.acute` means the model was
    /// suppressed and the person must see the crisis card instead of a reply.
    private(set) var crisis: CrisisSeverity = .none

    /// Shown when a request fails outright. Deliberately distinct from
    /// `.fallback`, which is a *successful* response to a budget limit and must
    /// not look like an error to the person reading it.
    private(set) var failed = false

    var draft = ""

    private let coach: any CoachClient
    private let threadID: UUID

    /// `@ObservationIgnored` so `deinit` can cancel it.
    ///
    /// Swift 6 lets a nonisolated `deinit` on a `@MainActor` class read `Sendable`
    /// **stored** properties, and `Task` is one — but `@Observable` rewrites
    /// tracked properties into computed ones, which `deinit` cannot touch. Opting
    /// this single property out keeps it stored. Nothing observes it anyway; the
    /// UI watches `isStreaming`. (`PremiumStore` hit the same wall and solved it
    /// with a lock-box, which was heavier than it needed to be.)
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    init(
        coach: any CoachClient,
        threadID: UUID = UUID()
    ) {
        self.coach = coach
        self.threadID = threadID
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        draft = ""
        failed = false
        crisis = .none

        // Captured *before* the new message is appended: history is the turns
        // that came before this one, and including the message in its own
        // history would send it to the model twice.
        let history = ConversationWindow.history(from: messages)
        messages.append(CoachMessage(role: .user, text: text))

        isStreaming = true
        streamingText = ""

        streamTask = Task { [weak self] in
            guard let self else { return }
            let request = CoachRequest(
                surface: .chat,
                threadID: self.threadID,
                message: text,
                history: history,
                coherence: nil
            )
            do {
                for try await event in self.coach.send(request) {
                    if Task.isCancelled { break }
                    self.handle(event)
                }
            } catch {
                // Keep whatever arrived before the failure. Throwing away a
                // half-written reply loses the only thing the person had.
                self.finishStreaming()
                self.failed = true
            }
            self.isStreaming = false
        }
    }

    private func handle(_ event: CoachEvent) {
        switch event {
        case .delta(let chunk):
            streamingText += chunk

        case .crisis(let severity):
            crisis = max(crisis, severity)
            // Acute suppresses the model entirely (§9.2 Layer D). Anything that
            // had begun arriving is discarded rather than shown alongside the
            // crisis card — a half-formed coaching reply next to a suicide
            // hotline is the worst of both.
            if severity == .acute {
                streamingText = ""
                // Mark the message that triggered this so `ConversationWindow`
                // never carries it into a later request. It stays on screen —
                // it is the person's own words — but it does not travel.
                if let index = messages.lastIndex(where: { $0.role == .user }) {
                    messages[index].safety = .acute
                }
            }

        case .fallback(let text):
            // Not an error. The budget or the kill switch produced authored copy,
            // and it should read as Cal talking, because it is.
            streamingText = text

        case .finished:
            finishStreaming()
        }
    }

    private func finishStreaming() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            messages.append(CoachMessage(role: .assistant, text: text, safety: crisis))
        }
        streamingText = ""
    }

    /// Dismisses the crisis card. The conversation is left intact — see
    /// `ChatView` for why it is not ended.
    func acknowledgeCrisis() {
        crisis = .none
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        finishStreaming()
        isStreaming = false
    }

    deinit { streamTask?.cancel() }
}
