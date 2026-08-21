import Foundation

/// A `VoiceSession` that plays a written script.
///
/// This is what lets the entire voice-first redesign be built, demoed and
/// regression-tested before the ElevenLabs account exists
/// (`PLAN-voice-first.md` §9, steps 1–2). It opens no microphone, no socket and
/// no billing line, and `-CalUseMockCoach 1` selects it.
///
/// Two properties are load-bearing:
///
/// - **Tool calls block until they are answered**, exactly as the real agent
///   does. A router that forgets to respond deadlocks the conversation in
///   production; here it shows up as a timed-out beat in a unit test.
/// - **Transcripts arrive word by word**, partials before finals. `MockCoachClient`
///   learned this lesson the expensive way — a mock tidier than production hides
///   the bugs production has. Here the untidiness is the whole point: partial
///   transcripts are what `TranscriptSafetyMonitor` runs on, so a mock that only
///   emitted finished sentences would exercise none of the path that matters.
public actor MockVoiceSession: VoiceSession {
    /// One step of a scripted session.
    public enum Beat: Sendable, Equatable {
        /// The student says something. Emitted as growing partials, then a final.
        case hears(String)
        /// Cal says something. Emitted with speaking toggles around it.
        case says(String)
        /// Cal calls a tool, and waits for the answer.
        case calls(VoiceToolCall)
        /// Anything else, verbatim.
        case event(VoiceEvent)
        /// Silence, one beat long.
        case pause
        /// Stay connected and do nothing further. For previews, where a stream
        /// that ends looks like a bug.
        case idle
    }

    public struct RecordedResponse: Sendable, Equatable {
        public let callID: String
        public let result: ToolResult
    }

    private let script: [Beat]
    private let beatDelay: Duration
    private let toolResponseTimeout: Duration

    private var continuation: AsyncStream<VoiceEvent>.Continuation?
    private var playback: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<ToolResult, Never>] = [:]

    /// Every tool answer the app gave, in order. The assertion surface for
    /// "did the router actually do the thing".
    public private(set) var responses: [RecordedResponse] = []
    public private(set) var didInterrupt = false
    public private(set) var didEnd = false
    /// True while a guided practice owns the session (`setPracticeActive`).
    public private(set) var practiceActive = false
    /// True while a check-in owns the session (`setSilentHold`).
    public private(set) var silentHold = false

    /// When set, `.says` beats are skipped and agent transcript / speaking
    /// events are dropped. Crisis interrupt latches this; practice quiet does
    /// too, then clears it on resume. Pending tool waits are never failed by
    /// an interrupt — cutting audio is not hanging up.
    private var suppressAgentSpeech = false

    /// - Parameters:
    ///   - beatDelay: Wall-clock pause between beats. Zero in tests so the suite
    ///     stays instant; a realistic value in previews so the pacing can be
    ///     judged.
    ///   - toolResponseTimeout: How long a tool call waits before giving up. A
    ///     bounded wait rather than an unbounded one, so a router that never
    ///     answers fails a test instead of hanging it.
    public init(
        script: [Beat],
        beatDelay: Duration = .zero,
        toolResponseTimeout: Duration = .seconds(2)
    ) {
        self.script = script
        self.beatDelay = beatDelay
        self.toolResponseTimeout = toolResponseTimeout
    }

    // MARK: VoiceSession

    public nonisolated var acceptsTextInput: Bool { false }

    public func start() async -> AsyncStream<VoiceEvent> {
        let (stream, continuation) = AsyncStream<VoiceEvent>.makeStream()
        self.continuation = continuation
        playback = Task { await self.run() }
        return stream
    }

    public func respond(to callID: String, with result: ToolResult) async {
        responses.append(RecordedResponse(callID: callID, result: result))
        pending.removeValue(forKey: callID)?.resume(returning: result)
    }

    public nonisolated func sendUserText(_ text: String) async {}

    /// Cuts agent audio. Does not hang up, does not fail in-flight tool waits,
    /// and does not finish the stream — same bargain as the live SDK interrupt.
    ///
    /// Subsequent `.says` beats are suppressed until `end()` or practice
    /// resumes (`setPracticeActive(false)`). Anything awaiting the end of the
    /// event stream will wait forever after an interrupt on an `.idle` script,
    /// which is correct for a session and a trap for a test; poll for the
    /// state you expect and call `end()`.
    public func interrupt() async {
        didInterrupt = true
        suppressAgentSpeech = true
        emit(.agentSpeaking(false))
    }

    public func setPracticeActive(_ active: Bool) async {
        if active {
            guard !practiceActive else { return }
            practiceActive = true
        } else {
            practiceActive = false
            if !silentHold {
                suppressAgentSpeech = false
            }
        }
    }

    public func setSilentHold(_ active: Bool) async {
        if active {
            guard !silentHold else { return }
            silentHold = true
            didInterrupt = true
            suppressAgentSpeech = true
            emit(.agentSpeaking(false))
        } else {
            guard silentHold else { return }
            silentHold = false
            suppressAgentSpeech = false
        }
    }

    public func end() async {
        didEnd = true
        practiceActive = false
        silentHold = false
        suppressAgentSpeech = false
        stopPlayback(reason: "session ended")
        emit(.ended)
        continuation?.finish()
        continuation = nil
    }

    // MARK: Playback

    private func run() async {
        emit(.connecting)
        await tick()
        emit(.connected)

        for beat in script {
            if Task.isCancelled { return }
            await play(beat)
        }

        // The script ran out. Finish the stream rather than hanging, so
        // `for await` in a test terminates; a preview that wants to stay open
        // ends its script with `.idle`.
        continuation?.finish()
        continuation = nil
    }

    private func play(_ beat: Beat) async {
        switch beat {
        case .pause:
            await tick()

        case .idle:
            // Cancelled by `interrupt()` or `end()`; nothing else wakes it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }

        case .event(let event):
            emit(event)
            await tick()

        case .hears(let text):
            for partial in Self.growing(text) {
                if Task.isCancelled { return }
                emit(.userTranscript(partial, isFinal: false))
                await tick()
            }
            emit(.userTranscript(text, isFinal: true))
            await tick()

        case .says(let text):
            // Crisis interrupt and practice quiet both latch suppression so a
            // follow-up coaching line never lands beside a hotline — or over a
            // guided breath.
            guard !suppressAgentSpeech else {
                await tick()
                return
            }
            emit(.agentSpeaking(true))
            for partial in Self.growing(text) {
                if Task.isCancelled || suppressAgentSpeech {
                    emit(.agentSpeaking(false))
                    return
                }
                emit(.agentTranscript(partial, isFinal: false))
                await tick()
            }
            if suppressAgentSpeech {
                emit(.agentSpeaking(false))
                return
            }
            emit(.agentTranscript(text, isFinal: true))
            emit(.agentSpeaking(false))
            await tick()

        case .calls(let call):
            emit(.toolCall(call))
            _ = await awaitResponse(for: call.id)
            await tick()
        }
    }

    /// "one two three" → ["one", "one two", "one two three"], minus the last,
    /// which is emitted separately as the final.
    private static func growing(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return [] }
        return (1..<words.count).map { words[0..<$0].joined(separator: " ") }
    }

    private func awaitResponse(for id: String) async -> ToolResult {
        await withCheckedContinuation { continuation in
            pending[id] = continuation
            Task { [weak self, timeout = toolResponseTimeout] in
                try? await Task.sleep(for: timeout)
                await self?.timeOutResponse(for: id)
            }
        }
    }

    private func timeOutResponse(for id: String) {
        pending.removeValue(forKey: id)?
            .resume(returning: .failure("The app did not answer this tool call."))
    }

    private func stopPlayback(reason: String) {
        playback?.cancel()
        playback = nil
        // Release anything waiting, or the cancelled beat loop leaks a
        // continuation and the test hangs on the thing meant to catch hangs.
        for (_, continuation) in pending {
            continuation.resume(returning: .failure(reason))
        }
        pending.removeAll()
    }

    private func emit(_ event: VoiceEvent) {
        continuation?.yield(event)
    }

    private func tick() async {
        guard beatDelay > .zero else { return }
        try? await Task.sleep(for: beatDelay)
    }
}

// MARK: - Scripts

extension MockVoiceSession {
    /// Cal says hello and waits. The default for previews.
    ///
    /// She calls `get_today_status` and then says nothing numeric. A fixed script
    /// cannot know what the store holds, so a line like "you've practised four
    /// days running" is wrong against every seed except one — and demonstrating
    /// Cal stating a number that contradicts the tool she just called is a
    /// demonstration of the exact bug that tool exists to prevent.
    public static let greeting: [Beat] = [
        .calls(VoiceToolCall(id: "c1", name: CalTool.Name.todayStatus)),
        .says("Check in today."),
        .calls(VoiceToolCall(id: "c2", name: CalTool.Name.startCheckIn)),
        .idle,
    ]

    /// A disclosure mid-sentence. Exercises `TranscriptSafetyMonitor`, the
    /// interrupt, and `EmergencyView`.
    ///
    /// The partials matter: the acute pattern completes before the sentence does,
    /// which is the only reason the tripwire can beat the agent to the reply.
    public static let crisis: [Beat] = [
        .says("What's been the hardest part of this week?"),
        .hears("honestly I keep thinking about how I want to kill myself and I can't make it stop"),
        // Never reached when the monitor is wired correctly — its presence is how
        // a test proves the interrupt happened.
        .says("That sounds really hard, tell me more about that."),
        .idle,
    ]

    /// Cal calls `play_practice` with an empty slug. Proves the trust boundary
    /// rejects rather than opening a blank player, and that Cal is told enough
    /// to try again.
    public static let toolError: [Beat] = [
        .says("Want to breathe together for a minute?"),
        .hears("yeah"),
        .calls(
            VoiceToolCall(
                id: "c1", name: CalTool.Name.playPractice,
                json: #"{"slug":""}"#
            )
        ),
        .says("I need a practice name for that — box breath, maybe?"),
        .idle,
    ]

    public static let micDenied: [Beat] = [.event(.failed(.microphonePermissionDenied))]
    public static let offline: [Beat] = [.event(.failed(.offline))]

    /// One visible reconnect, then recovery — the only automatic retry §5 allows.
    public static let dropAndRecover: [Beat] = [
        .says("How's your week been?"),
        .event(.failed(.connectionLost(willRetry: true))),
        .pause,
        .event(.connected),
        .says("Sorry — lost you there. You were saying?"),
        .idle,
    ]

    /// The drop that does not come back.
    public static let dropAndFail: [Beat] = [
        .says("How's your week been?"),
        .event(.failed(.connectionLost(willRetry: true))),
        .pause,
        .event(.failed(.connectionLost(willRetry: false))),
    ]
}
