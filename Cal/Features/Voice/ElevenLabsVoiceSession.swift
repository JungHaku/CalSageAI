import AVFoundation
import CalData
import CalVoice
import Combine
import ElevenLabs
import Foundation

/// Live `VoiceSession` backed by the ElevenLabs Agents Swift SDK.
///
/// Lives in the app target on purpose: `Packages/CalVoice` must stay free of
/// AVFoundation, WebSockets and vendor SDKs so `swift test` never opens a mic or
/// a billing line (`PLAN-voice-implementation.md` §4).
///
/// Translation only — `VoiceRootViewModel` and `SageRouter` do not know this
/// type exists.
///
/// ## Simulator
///
/// LiveKit WebRTC `room.connect` times out on the iOS Simulator (ICE never
/// completes). On sim we take the SDK's text-only WebSocket path with a signed
/// URL from `voice-token`, and the voice root shows a composer instead of a mic.
@MainActor
final class ElevenLabsVoiceSession: VoiceSession, @unchecked Sendable {
    /// Hard client-side cap. Not a real budget control — anyone who can reach
    /// `voice-token` can still open sessions — but it stops an open pocket socket
    /// from running forever (`PLAN-voice-first.md` §8).
    static let sessionLimit: Duration = .seconds(15 * 60)

    private let tokenClient: VoiceTokenClient
    /// Prefetch standing facts. Fail-open to `none` so a slow store never
    /// delays the first spoken word past a short wait after the token lands.
    private let loadMemoryDigest: @Sendable () async -> String
    /// First line C.A.L. speaks — check-in invite or result-based greeting.
    private let loadSessionOpener: @Sendable () async -> String
    private var memoryDigest = MemoryDigest.noneSentinel
    private var sessionOpener = "Check in today."
    private var conversation: Conversation?
    private var continuation: AsyncStream<VoiceEvent>.Continuation?
    private var observers = Set<AnyCancellable>()
    private var limitTask: Task<Void, Never>?
    private var seenToolCallIDs = Set<String>()
    private var ended = false
    private let textOnly: Bool
    private var practiceActive = false
    private var silentHold = false
    /// Microphone mute state captured when quiet begins, restored on exit.
    private var mutedBeforeQuiet = false
    private var weMuted = false

    init(
        tokenClient: VoiceTokenClient,
        loadMemoryDigest: @escaping @Sendable () async -> String = {
            MemoryDigest.noneSentinel
        },
        loadSessionOpener: @escaping @Sendable () async -> String = {
            "Check in today."
        }
    ) {
        self.tokenClient = tokenClient
        self.loadMemoryDigest = loadMemoryDigest
        self.loadSessionOpener = loadSessionOpener
        #if targetEnvironment(simulator)
        self.textOnly = true
        #else
        self.textOnly = false
        #endif
    }

    nonisolated var acceptsTextInput: Bool { textOnly }

    func start() async -> AsyncStream<VoiceEvent> {
        let (stream, continuation) = AsyncStream<VoiceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuation = nil
            }
        }

        emit(.connecting)
        Task { await self.connect() }
        return stream
    }

    func respond(to callID: String, with result: ToolResult) async {
        guard let conversation else { return }
        do {
            try await conversation.sendToolResult(
                for: callID,
                result: result.text,
                isError: result.isError
            )
        } catch {
            emit(.failed(.agentUnavailable))
        }
    }

    func sendUserText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard textOnly, !trimmed.isEmpty, let conversation else { return }
        // Show the turn immediately — waiting on an echo feels broken on a typed
        // composer.
        emit(.userTranscript(trimmed, isFinal: true))
        do {
            try await conversation.sendMessage(trimmed)
        } catch {
            emit(.failed(mapStartError(error)))
            await end()
        }
    }

    func interrupt() async {
        guard let conversation else { return }
        try? await conversation.interruptAgent()
    }

    func setPracticeActive(_ active: Bool) async {
        guard practiceActive != active else { return }
        practiceActive = active
        await syncMicrophoneQuiet()
    }

    func setSilentHold(_ active: Bool) async {
        if active {
            guard !silentHold else { return }
            silentHold = true
            await interrupt()
            await syncMicrophoneQuiet()
        } else {
            guard silentHold else { return }
            silentHold = false
            await syncMicrophoneQuiet()
        }
    }

    func end() async {
        guard !ended else { return }
        ended = true
        practiceActive = false
        silentHold = false
        weMuted = false
        limitTask?.cancel()
        limitTask = nil
        observers.removeAll()
        seenToolCallIDs.removeAll()
        let conversation = self.conversation
        self.conversation = nil
        await conversation?.endConversation()
        emit(.ended)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Connect

    private func connect() async {
        let digestTask = Task { await self.loadMemoryDigest() }
        let openerTask = Task { await self.loadSessionOpener() }
        let credentials: VoiceTokenClient.Credentials
        do {
            credentials = try await tokenClient.fetchCredentials()
        } catch let failure as VoiceTokenClient.Failure {
            digestTask.cancel()
            openerTask.cancel()
            emit(.failed(mapTokenFailure(failure)))
            await end()
            return
        } catch {
            digestTask.cancel()
            openerTask.cancel()
            emit(.failed(.offline))
            await end()
            return
        }

        memoryDigest = await firstReady(
            digestTask,
            timeout: .milliseconds(400),
            fallback: MemoryDigest.noneSentinel
        )
        sessionOpener = await firstReady(
            openerTask,
            timeout: .milliseconds(400),
            fallback: "Check in today."
        )

        if textOnly {
            await connectTextOnly(signedURL: credentials.signedURL)
        } else {
            await connectVoice(token: credentials.token)
        }
    }

    private func connectTextOnly(signedURL: String) async {
        do {
            let conversation = try await ElevenLabs.startConversation(
                signedWebSocketURL: signedURL,
                config: eventConfig(textOnly: true),
                onDisconnect: { [weak self] _ in
                    Task { @MainActor in await self?.handleDisconnect() }
                }
            )
            self.conversation = conversation
            observePendingTools(conversation)
            emit(.connected)
            startSessionLimit()
        } catch {
            print("ElevenLabsVoiceSession text-only start failed: \(error)")
            emit(.failed(mapStartError(error)))
            await end()
        }
    }

    private func connectVoice(token: String) async {
        switch await microphonePermission() {
        case .denied:
            emit(.failed(.microphonePermissionDenied))
            await end()
            return
        case .unavailable:
            emit(.failed(.microphoneUnavailable))
            await end()
            return
        case .granted:
            break
        }

        // PLAN-voice-implementation §5: claim the session before WebRTC opens.
        do {
            let session = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
            if #available(iOS 18.0, *) {
                options.insert(.allowBluetoothHFP)
            }
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
            try session.setActive(true)
        } catch {
            emit(.failed(.microphoneUnavailable))
            await end()
            return
        }

        do {
            // Pass `onDisconnect` as a method arg — the SDK convenience
            // overwrites `config.onDisconnect` with the parameter (nil by
            // default), so putting it only in the config silently drops it.
            //
            // Use automatic ICE on device. `relayOnly` was meant to skip the
            // local-network prompt, but if TURN is blocked the room connects
            // then immediately dies — which is the TestFlight "connection
            // dropped" failure. Automatic can use host/srflx/relay; the local
            // network usage string is in Info.plist so iOS can actually prompt.
            let conversation = try await ElevenLabs.startConversation(
                conversationToken: token,
                config: eventConfig(textOnly: false),
                onDisconnect: { [weak self] _ in
                    Task { @MainActor in await self?.handleDisconnect() }
                }
            )
            self.conversation = conversation
            observePendingTools(conversation)
            emit(.connected)
            startSessionLimit()
        } catch {
            print("ElevenLabsVoiceSession voice start failed: \(error)")
            emit(.failed(mapStartError(error)))
            await end()
        }
    }

    private func eventConfig(
        textOnly: Bool,
        network: LiveKitNetworkConfiguration = .default
    ) -> ConversationConfig {
        ConversationConfig(
            conversationOverrides: .init(textOnly: textOnly),
            dynamicVariables: [
                "memory_digest": memoryDigest,
                "session_opener": sessionOpener,
            ],
            networkConfiguration: network,
            onError: { [weak self] error in
                Task { @MainActor in await self?.handleSDKError(error) }
            },
            onAgentResponse: { [weak self] text, _ in
                Task { @MainActor in
                    guard self?.silentHold != true else { return }
                    self?.emit(.agentTranscript(text, isFinal: true))
                }
            },
            onUserTranscript: { [weak self] text, _ in
                Task { @MainActor in
                    // Text-only already emitted the student turn in sendUserText.
                    guard self?.textOnly != true else { return }
                    self?.emit(.userTranscript(text, isFinal: true))
                }
            },
            onUnhandledClientToolCall: { [weak self] call in
                Task { @MainActor in await self?.handleToolCall(call) }
            },
            onAgentStateChange: { [weak self] state in
                Task { @MainActor in
                    if self?.silentHold == true, state == .speaking {
                        await self?.interrupt()
                        return
                    }
                    self?.emit(.agentSpeaking(state == .speaking))
                }
            }
        )
    }

    private func observePendingTools(_ conversation: Conversation) {
        conversation.$pendingToolCalls
            .sink { [weak self] calls in
                Task { @MainActor in
                    for call in calls {
                        await self?.handleToolCall(call)
                    }
                }
            }
            .store(in: &observers)
    }

    private func handleToolCall(_ call: ClientToolCallEvent) async {
        guard seenToolCallIDs.insert(call.toolCallId).inserted else { return }
        let arguments = call.parametersData.isEmpty
            ? Data("{}".utf8)
            : call.parametersData
        emit(.toolCall(VoiceToolCall(
            id: call.toolCallId,
            name: call.toolName,
            arguments: arguments
        )))
    }

    private func handleSDKError(_ error: ConversationError) async {
        emit(.failed(mapStartError(error)))
        await end()
    }

    private func handleDisconnect() async {
        guard !ended else { return }
        emit(.failed(.connectionLost(willRetry: false)))
        await end()
    }

    /// Token fetch is the wait we already pay. If the digest is not ready
    /// shortly after, start with `none` rather than holding the mic.
    private func firstReady(
        _ task: Task<String, Never>,
        timeout: Duration,
        fallback: String
    ) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return fallback
            }
            let value = await group.next() ?? fallback
            group.cancelAll()
            return value
        }
    }

    private func startSessionLimit() {
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionLimit)
            guard let self, !Task.isCancelled else { return }
            self.emit(.failed(.sessionLimitReached))
            await self.end()
        }
    }

    /// Mute while a practice or check-in owns the mic. Practice still lets Cal
    /// speak; check-in hold additionally interrupts her.
    private func syncMicrophoneQuiet() async {
        let quiet = practiceActive || silentHold
        guard let conversation, !textOnly else { return }
        if quiet {
            if !weMuted {
                mutedBeforeQuiet = conversation.isMuted
                weMuted = true
                try? await conversation.setMuted(true)
            }
        } else if weMuted {
            try? await conversation.setMuted(mutedBeforeQuiet)
            weMuted = false
        }
    }

    private func emit(_ event: VoiceEvent) {
        if silentHold {
            switch event {
            case .agentTranscript, .agentSpeaking(true):
                return
            default:
                break
            }
        }
        continuation?.yield(event)
    }

    // MARK: - Mapping

    private enum MicPermission {
        case granted, denied, unavailable
    }

    private func microphonePermission() async -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .granted : .denied
        @unknown default:
            return .unavailable
        }
    }

    private func mapTokenFailure(_ failure: VoiceTokenClient.Failure) -> VoiceFailure {
        switch failure {
        case .offline:              .offline
        case .unconfigured:         .authenticationFailed
        case .authenticationFailed: .authenticationFailed
        case .unavailable:          .agentUnavailable
        }
    }

    private func mapStartError(_ error: Error) -> VoiceFailure {
        if let conversationError = error as? ConversationError {
            switch conversationError {
            case .authenticationFailed:
                return .authenticationFailed
            case .localNetworkPermissionRequired:
                return .microphoneUnavailable
            case .connectionFailed, .agentTimeout:
                return .connectionLost(willRetry: false)
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return .offline
        }
        if ns.domain == "io.livekit.swift-sdk" {
            return .connectionLost(willRetry: false)
        }
        let mirror = Mirror(reflecting: error)
        for child in mirror.children {
            if let conversationError = child.value as? ConversationError {
                return mapStartError(conversationError)
            }
        }
        return .agentUnavailable
    }
}
