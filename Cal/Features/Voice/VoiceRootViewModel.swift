import CalKit
import CalVoice
import Foundation
import Observation

/// The state behind the voice root.
///
/// Separated from the view for the reason `ChatViewModel` is: the parts that
/// matter — what happens when someone discloses a crisis, what happens when the
/// socket dies mid-sentence, what the person is left looking at — are testable
/// without a simulator, a microphone or a socket.
///
/// Everything it talks to is `VoiceSession`, which today is `MockVoiceSession`.
/// The screen therefore works with no ElevenLabs account and no key; swapping in
/// the real session at `PLAN-voice-first.md` §9 step 4 changes nothing here.
@Observable
@MainActor
final class VoiceRootViewModel {
    /// One line of the visible conversation.
    ///
    /// The transcript is not a nicety. A voice-only interface is unusable to
    /// anyone who cannot hear and unverifiable to everyone else, and `.action`
    /// lines are how "Cal drives it" stays legible rather than the screen simply
    /// lurching.
    struct Turn: Identifiable, Equatable {
        enum Speaker: Equatable { case student, cal, action }

        let id = UUID()
        let speaker: Speaker
        let text: String
    }

    private(set) var state: VoiceSessionState = .idle
    private(set) var turns: [Turn] = []
    /// The utterance in progress, shown greyed under the transcript.
    private(set) var partialStudent = ""
    private(set) var partialCal = ""

    /// Non-`.none` when the safety pipeline acted. `.acute` means Cal was cut off
    /// and the person must see the crisis card.
    private(set) var crisis: CrisisSeverity = .none
    private(set) var failure: VoiceFailure?
    /// True when the live session wants a typed composer (Simulator text-only).
    private(set) var acceptsTextInput = false
    /// Draft for the Simulator composer.
    var draft = ""

    private let makeSession: @MainActor @Sendable () -> any VoiceSession
    private let router: SageRouter
    private let remember: (@MainActor @Sendable (String, String) -> Void)?
    private var safety = TranscriptSafetyMonitor()
    private var session: (any VoiceSession)?

    /// `@ObservationIgnored` so `deinit` can cancel it — `@Observable` rewrites
    /// tracked properties into computed ones, which a nonisolated `deinit` cannot
    /// touch. `ChatViewModel` documents the same wrinkle.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        makeSession: @escaping @MainActor @Sendable () -> any VoiceSession,
        router: SageRouter,
        remember: (@MainActor @Sendable (String, String) -> Void)? = nil
    ) {
        self.makeSession = makeSession
        self.router = router
        self.remember = remember
    }

    var isLive: Bool {
        switch state {
        case .idle, .failed, .ended: false
        default: true
        }
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        let session = makeSession()
        self.session = session
        acceptsTextInput = session.acceptsTextInput
        state = .connecting

        task = Task { [weak self] in
            let stream = await session.start()
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
            // The stream ending *is* the session ending, and it can end without
            // an `.ended` event — a socket that closes, or a script that runs
            // out. Leaving the state on `.listening` would show a live-looking
            // Cal attached to nothing, with no way back.
            guard let self, self.isLive else { return }
            self.state = .ended
        }
    }

    /// Sends a typed turn on the Simulator text-only path.
    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsTextInput, !text.isEmpty, isLive else { return }
        draft = ""
        await session?.sendUserText(text)
    }

    /// Starts over after a failure. A new session, deliberately — `VoiceSession`
    /// is one stream per session, and a reconnect the person did not ask for is a
    /// reconnect that silently bills.
    func restart() async {
        await stop()
        turns.removeAll()
        partialStudent = ""
        partialCal = ""
        draft = ""
        failure = nil
        crisis = .none
        // Not `safety.reset()`. The latch is per session in the sense of
        // per-conversation, and someone who disclosed something acute thirty
        // seconds ago has not stopped having disclosed it because the socket
        // dropped. It resets when the view goes away.
        state = .idle
        start()
    }

    func stop() async {
        await session?.end()
        task?.cancel()
        task = nil
        session = nil
        if isLive { state = .ended }
    }

    /// Dismisses the crisis card. The conversation is left intact, for the reason
    /// `ChatView` gives: ending it is one more thing taken away from someone who
    /// just said something hard.
    func acknowledgeCrisis() {
        crisis = .none
    }

    deinit { task?.cancel() }

    /// Awaits the event loop. Tests only — a script that ends in `.idle` never
    /// returns, which is the correct behaviour for a live session and a hang for
    /// anything that calls this.
    func waitForScript() async {
        await task?.value
    }

    // MARK: Events

    private func handle(_ event: VoiceEvent) async {
        // Safety first, and *before* the transcript is touched. Every millisecond
        // between the pattern matching and the audio stopping is a millisecond of
        // Cal talking over a crisis disclosure.
        let action = safety.consume(event)
        if case .interruptAndEscalate = action {
            await session?.interrupt()
        }

        await apply(event)

        switch action {
        case .interruptAndEscalate:
            // Discard whatever Cal had begun. A half-formed coaching reply next
            // to a suicide hotline is the worst of both — §9.2 Layer D, and the
            // same call `ChatViewModel` makes on `.crisis(.acute)`.
            partialCal = ""
            state = .listening
            crisis = .acute
        case .surfaceResources:
            crisis = max(crisis, .elevated)
        case .none:
            if case .userTranscript(let text, true) = event {
                remember?(text, "none")
            }
        }
    }

    private func apply(_ event: VoiceEvent) async {
        switch event {
        case .connecting:
            state = .connecting

        case .connected:
            failure = nil
            state = .listening

        case .userTranscript(let text, let isFinal):
            if isFinal {
                partialStudent = ""
                append(.student, text)
                state = .thinking
            } else {
                partialStudent = text
                state = .hearing
            }

        case .agentTranscript(let text, let isFinal):
            // Once acute has fired, Cal's audio is cut. Anything still arriving
            // was generated *before* the interrupt landed — it is in flight, or
            // sitting in the stream's buffer — and rendering it is precisely the
            // cheerful continuation the interrupt exists to stop (§9.2 Layer D).
            // Cutting the audio without discarding the queue would leave the
            // words on screen beside a suicide hotline.
            guard crisis != .acute else { return }
            if isFinal {
                partialCal = ""
                append(.cal, text)
            } else {
                partialCal = text
            }

        case .agentSpeaking(let speaking):
            // Never overwrite a terminal state — a `false` arriving after an
            // interrupt would put the UI back to "listening" on a dead session.
            guard isLive, crisis != .acute else { return }
            state = speaking ? .speaking : .listening

        case .toolCall(let call):
            await run(call)

        case .failed(let reason):
            failure = reason
            state = .failed(reason)

        case .ended:
            state = .ended
        }
    }

    private func run(_ call: VoiceToolCall) async {
        let tool: CalTool
        do {
            tool = try CalTool(call)
        } catch {
            // The agent sent something the app will not accept. Cal is told
            // precisely what was wrong so she can correct it in the next breath,
            // and the person sees that something was refused rather than watching
            // a screen that did not move.
            append(.action, error.agentMessage)
            await session?.respond(to: call.id, with: ToolResult(error))
            return
        }

        append(.action, Self.describe(tool))

        let isPractice = if case .playPractice = tool { true } else { false }
        if isPractice {
            await session?.setPracticeActive(true)
        }
        let result = await router.perform(tool)
        if isPractice {
            Task { [weak self] in
                guard let self else { return }
                while self.router.practices.isRunning {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                await self.session?.setPracticeActive(false)
            }
        }

        if result.isError {
            append(.action, result.text)
        }
        await session?.respond(to: call.id, with: result)

        if case .endSession = tool {
            await stop()
            state = .ended
        }
    }

    private func append(_ speaker: Turn.Speaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(Turn(speaker: speaker, text: trimmed))
    }

    /// What the person sees when Cal reaches for a tool. Present tense and plain —
    /// this is a caption on a screen that is about to change, not a log line.
    static func describe(_ tool: CalTool) -> String {
        switch tool {
        case .todayStatus:            "Getting oriented"
        case .startCheckIn:           "Starting check-in"
        case .recordScore:            "Saving your rating"
        case .skipRegulation:         "Skipping regulation"
        case .continueCheckIn:        "Continuing check-in"
        case .playPractice(let slug): "Starting \(slug.replacingOccurrences(of: "-", with: " "))"
        case .stopPractice:           "Stopping the practice"
        case .showPlace(let query):   "Looking up \(query)"
        case .openScreen(let screen):
            screen == .map ? "Opening the campus map" : "Opening \(screen.rawValue)"
        case .endSession:             "Ending the conversation"
        }
    }
}

extension VoiceSessionState {
    /// What Cal is doing, said plainly. Read by VoiceOver on every change, so it
    /// is a sentence about the conversation rather than a status token.
    var label: String {
        switch self {
        case .idle:       "Tap to talk to C.A.L."
        case .connecting: "Connecting…"
        case .listening:  "Listening"
        case .hearing:    "Listening"
        case .thinking:   "Thinking"
        case .speaking:   "C.A.L. is speaking"
        case .ended:      "Conversation ended"
        case .failed(let reason): VoiceFailureCopy.headline(for: reason)
        }
    }
}

extension VoiceRootViewModel {
    /// Menu / chip entry into the spoken check-in. Keeps state on the router so
    /// the home banner can show the question while Cal asks it out loud.
    func beginCheckIn() {
        Task {
            append(.action, Self.describe(.startCheckIn))
            let result = await router.perform(.startCheckIn)
            if result.isError {
                append(.action, result.text)
            }
            if isLive {
                await session?.sendUserText(
                    "I'd like to check in — ask me the current question."
                )
            }
        }
    }

    func recordCheckInScore(_ value: Int) {
        Task {
            append(.action, Self.describe(.recordScore(value: value)))
            let result = await router.perform(.recordScore(value: value))
            if result.isError {
                append(.action, result.text)
            } else if isLive {
                await session?.sendUserText("I rated that a \(value).")
            }
        }
    }

    /// Suggestion chip → typed turn when the session can take text; otherwise a
    /// quiet no-op until they tap Talk (voice path still hears them).
    func sendSuggestion(_ text: String) async {
        guard isLive else {
            connectAndSuggest(text)
            return
        }
        draft = text
        await sendDraft()
    }

    private func connectAndSuggest(_ text: String) {
        // Session may be ended after backgrounding — restart, then send.
        Task {
            if !isLive { await restart() }
            draft = text
            await sendDraft()
        }
    }
}
