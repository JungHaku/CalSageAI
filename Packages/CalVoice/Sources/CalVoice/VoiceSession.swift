import Foundation

/// The boundary between the app and the live voice agent.
///
/// Everything behind this protocol talks to ElevenLabs, which under
/// `PLAN-voice-first.md` §1 owns the whole loop: microphone, transcription,
/// turn-taking, interruption, the language model, and the voice. The app's side
/// of the deal is small and is entirely described here — it listens to events,
/// answers tool calls, and can cut the agent off.
///
/// The protocol exists for the same reason `CoachClient` does: so
/// `MockVoiceSession` can be injected and **no preview, test or CI run ever opens
/// a microphone, a socket, or a billing line**. `-CalUseMockCoach 1` selects the
/// mock here too.
public protocol VoiceSession: Sendable {
    /// Opens the session and returns the event stream.
    ///
    /// One stream per session; calling this twice is a programming error rather
    /// than a supported reconnect. Reconnection is the caller's decision because
    /// §5 requires it to be *visible* — a session that silently reopens itself
    /// is a session that silently bills.
    func start() async -> AsyncStream<VoiceEvent>

    /// Hands a tool's outcome back to the agent so Cal can speak about what
    /// actually happened rather than narrating an intention.
    func respond(to callID: String, with result: ToolResult) async

    /// Cuts the agent's audio immediately.
    ///
    /// This is the crisis path (§7). Not "stop after the current sentence" —
    /// `TranscriptSafetyMonitor` calls this when someone has just disclosed
    /// something that means Cal must stop talking now.
    func interrupt() async

    /// Practice listening gate.
    ///
    /// When `true`: mute the microphone so breath sounds do not barge in.
    /// Cal keeps speaking — she is reading the practice. When `false`: restore
    /// the previous microphone state. Crisis interrupt still works either way.
    func setPracticeActive(_ active: Bool) async

    /// Check-in hold. Unlike practice, Cal must not speak.
    ///
    /// When `true`: cut agent audio, mute the microphone, and drop further
    /// agent transcripts until `false`. The student is answering on-screen
    /// questions; a voice over the slider is the opposite of paused.
    func setSilentHold(_ active: Bool) async

    /// Ends the session and releases the microphone.
    func end() async

    /// Whether the UI should show a text composer.
    ///
    /// True on the Simulator text-only WebSocket path (LiveKit WebRTC does not
    /// complete there). False for real mic sessions and for `MockVoiceSession`.
    var acceptsTextInput: Bool { get }

    /// Sends a typed turn to the agent. No-op when `acceptsTextInput` is false.
    func sendUserText(_ text: String) async
}

/// Everything the app can learn from a live session.
///
/// Failures are **events, not thrown errors** — the one place this deliberately
/// diverges from `CoachClient`'s `AsyncThrowingStream`. Online-only was chosen
/// (§1), which makes "degrade loudly" the whole user experience of a bad
/// connection: the reason has to survive to the view so it can be said out loud.
/// A thrown error collapses every distinct failure into one catch block, and the
/// person is told "something went wrong" when we knew exactly what it was.
public enum VoiceEvent: Sendable, Equatable {
    case connecting
    case connected

    /// What the student said. Arrives repeatedly for one utterance as the
    /// transcription firms up; `isFinal` marks the last of them.
    ///
    /// This is the input to `TranscriptSafetyMonitor` and therefore the only
    /// thing standing between a crisis disclosure and Cal cheerfully continuing.
    case userTranscript(String, isFinal: Bool)

    /// What Cal said, on the same partial-then-final cadence.
    case agentTranscript(String, isFinal: Bool)

    /// The agent started or stopped speaking. Drives the visible state, and the
    /// answer to "is it my turn" for anyone who cannot hear.
    case agentSpeaking(Bool)

    /// Cal wants to do something to the app. Deliberately carries the *undecoded*
    /// call — see `CalTool.init(_:)` for why the trust boundary is one place.
    case toolCall(VoiceToolCall)

    case failed(VoiceFailure)
    case ended
}

/// Why a session is not working.
///
/// Each case is a distinct thing to say to a person, which is the point of
/// enumerating them rather than carrying a string.
public enum VoiceFailure: Sendable, Equatable {
    /// The person said no to the microphone, or has never been asked.
    case microphonePermissionDenied
    /// Permission granted, hardware unavailable — a call in progress, another app
    /// holding the input.
    case microphoneUnavailable
    case offline
    /// Dropped mid-session. `willRetry` distinguishes the one visible reconnect
    /// §5 allows from the stop that follows it.
    case connectionLost(willRetry: Bool)
    /// Reached the agent, and it refused or errored.
    case agentUnavailable
    /// The signed URL was rejected. Distinct from `agentUnavailable` because it
    /// means our configuration is wrong, not their service.
    case authenticationFailed
    /// The client-side session cap fired (§8). Not an error — a cost control, and
    /// it must not read to the person as a fault.
    case sessionLimitReached

    /// Whether reconnecting could plausibly help. `false` means stop and say so.
    public var isWorthRetrying: Bool {
        switch self {
        case .connectionLost, .offline, .microphoneUnavailable, .agentUnavailable:
            true
        case .microphonePermissionDenied, .authenticationFailed, .sessionLimitReached:
            false
        }
    }

    /// Whether the person can fix this from iOS Settings.
    public var isResolvedInSettings: Bool {
        self == .microphonePermissionDenied
    }
}

/// What a person is told when a session fails.
///
/// Kept next to the failure it describes, for the reason `MemoryConsentCopy` is
/// kept next to `MemoryConsent`: copy that lives in a view drifts from the
/// condition it is describing, and nobody notices until it is describing the
/// wrong one.
///
/// Written in Cal's voice and without blame — §5's "degrade loudly" means the
/// person understands what happened, not that they are shouted at.
public enum VoiceFailureCopy {
    public static func headline(for failure: VoiceFailure) -> String {
        switch failure {
        case .microphonePermissionDenied: "C.A.L. can't hear you yet"
        case .microphoneUnavailable:      "Something else is using the microphone"
        case .offline:                    "C.A.L. needs a connection"
        case .connectionLost(true):       "Reconnecting…"
        case .connectionLost(false):      "The connection dropped"
        case .agentUnavailable:           "C.A.L. can't talk right now"
        case .authenticationFailed:       "C.A.L. can't talk right now"
        case .sessionLimitReached:        "Let's pause there"
        }
    }

    public static func body(for failure: VoiceFailure) -> String {
        switch failure {
        case .microphonePermissionDenied:
            "Talking to C.A.L. needs microphone access. You can turn it on in Settings — or type instead, which works just as well."
        case .microphoneUnavailable:
            "Another app has the microphone, or you're on a call. Try again once it's free, or type instead."
        case .offline:
            "Talking out loud needs a connection. You can type to C.A.L. instead when you're back online."
        case .connectionLost(true):
            "Hold on — picking that back up."
        case .connectionLost(false):
            "That didn't come back. You can start again, or type instead."
        case .agentUnavailable, .authenticationFailed:
            "C.A.L.'s voice isn't available at the moment. Typing still works, and so does everything else."
        case .sessionLimitReached:
            "That's a good place to stop for now. Start again whenever you want to."
        }
    }
}

/// What the person sees Cal doing. Derived from the event stream; kept here so
/// the view and the mock agree on the vocabulary.
public enum VoiceSessionState: Sendable, Equatable {
    case idle
    case connecting
    /// Connected, microphone open, nobody talking.
    case listening
    /// The student is mid-utterance.
    case hearing
    /// Turn taken, reply not started.
    case thinking
    case speaking
    case failed(VoiceFailure)
    case ended
}
