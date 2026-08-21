import CalKit
import Foundation
import Testing

@testable import CalVoice

@Suite("MockVoiceSession")
struct MockVoiceSessionTests {

    @Test("a session opens before it says anything")
    func connects() async {
        let session = MockVoiceSession(script: [.says("Hello")])
        let events = await collect(from: session)
        #expect(events.first == .connecting)
        #expect(events.dropFirst().first == .connected)
    }

    /// A mock tidier than production hides the bugs production has —
    /// `MockCoachClient` says so in its own header, having learned it the
    /// expensive way. Partial transcripts are the input to the safety monitor, so
    /// a mock that only emitted finished sentences would exercise none of it.
    @Test("speech arrives as growing partials, then a final")
    func partials() async {
        let session = MockVoiceSession(script: [.hears("one two three")])
        let events = await collect(from: session)
        let transcripts = events.compactMap { event -> (String, Bool)? in
            guard case .userTranscript(let text, let isFinal) = event else { return nil }
            return (text, isFinal)
        }
        #expect(transcripts.map(\.0) == ["one", "one two", "one two three"])
        #expect(transcripts.map(\.1) == [false, false, true])
    }

    @Test("a single-word utterance is just a final")
    func singleWord() async {
        let session = MockVoiceSession(script: [.hears("yeah")])
        let events = await collect(from: session)
        #expect(events.contains(.userTranscript("yeah", isFinal: true)))
        #expect(!events.contains { if case .userTranscript(_, false) = $0 { true } else { false } })
    }

    @Test("Cal's speech is bracketed by speaking toggles")
    func speakingToggles() async {
        let session = MockVoiceSession(script: [.says("hello there")])
        let events = await collect(from: session)
        let toggles = events.compactMap { event -> Bool? in
            guard case .agentSpeaking(let speaking) = event else { return nil }
            return speaking
        }
        #expect(toggles == [true, false])
    }

    /// The real agent blocks on a tool result. A router that forgets to respond
    /// deadlocks the conversation in production; this makes that a test failure.
    @Test("a tool call waits for its answer before the script continues")
    func toolCallBlocks() async {
        let session = MockVoiceSession(
            script: [
                .calls(VoiceToolCall(id: "c1", name: CalTool.Name.todayStatus)),
                .says("You're on a four day streak"),
            ]
        )
        var sawToolCall = false
        var sawFollowUp = false
        let stream = await session.start()
        for await event in stream {
            switch event {
            case .toolCall(let call):
                sawToolCall = true
                #expect(!sawFollowUp, "Cal spoke before the tool was answered")
                await session.respond(to: call.id, with: .ok("streak 4, checked in today: no"))
            case .agentTranscript(let text, true) where text.contains("four day"):
                sawFollowUp = true
            default:
                break
            }
        }
        #expect(sawToolCall)
        #expect(sawFollowUp)

        let responses = await session.responses
        #expect(responses == [.init(callID: "c1", result: .ok("streak 4, checked in today: no"))])
    }

    @Test("an unanswered tool call times out rather than hanging")
    func toolCallTimesOut() async {
        let session = MockVoiceSession(
            script: [.calls(VoiceToolCall(id: "c1", name: CalTool.Name.todayStatus)), .says("done")],
            toolResponseTimeout: .milliseconds(20)
        )
        let events = await collect(from: session)
        #expect(events.contains(.agentTranscript("done", isFinal: true)))
    }

    /// §7. Acute means cut the audio — not show a card over the top of Cal
    /// cheerfully continuing. The follow-up line in the `crisis` script exists
    /// precisely so this test can prove it was never spoken.
    @Test("interrupting stops the script where it stands")
    func interruptCutsTheAgentOff() async {
        let session = MockVoiceSession(script: MockVoiceSession.crisis)
        var monitor = TranscriptSafetyMonitor()
        var escalation: TranscriptSafetyMonitor.Action = .none
        var spoken: [String] = []

        let stream = await session.start()
        for await event in stream {
            if case .agentTranscript(let text, true) = event { spoken.append(text) }
            let action = monitor.consume(event)
            if case .interruptAndEscalate = action {
                escalation = action
                await session.interrupt()
                break
            }
        }

        #expect(escalation == .interruptAndEscalate(rule: "kill myself"))
        #expect(await session.didInterrupt)
        #expect(spoken == ["What's been the hardest part of this week?"])
        #expect(
            !spoken.contains { $0.contains("tell me more") },
            "Cal kept talking after an acute disclosure"
        )
    }

    @Test("ending emits `ended` and closes the stream")
    func ending() async {
        let session = MockVoiceSession(script: [.idle])
        let stream = await session.start()
        var events: [VoiceEvent] = []
        let consumer = Task {
            var seen: [VoiceEvent] = []
            for await event in stream { seen.append(event) }
            return seen
        }
        // Let the script reach `.idle` before hanging up.
        try? await Task.sleep(for: .milliseconds(20))
        await session.end()
        events = await consumer.value

        #expect(events.last == .ended)
        #expect(await session.didEnd)
    }

    @Test("failures arrive as events, not thrown errors")
    func failuresAreEvents() async {
        let session = MockVoiceSession(script: MockVoiceSession.micDenied)
        let events = await collect(from: session)
        #expect(events.contains(.failed(.microphonePermissionDenied)))
    }

    @Test("a recoverable drop reconnects visibly, once")
    func dropAndRecover() async {
        let session = MockVoiceSession(script: MockVoiceSession.dropAndRecover)
        let stream = await session.start()
        var events: [VoiceEvent] = []
        for await event in stream {
            events.append(event)
            if case .agentTranscript(let text, true) = event, text.contains("lost you") { break }
        }
        #expect(events.contains(.failed(.connectionLost(willRetry: true))))
        #expect(events.filter { $0 == .connected }.count == 2)
    }

    // MARK: The demo scripts

    /// Every tool call in the check-in script has to survive the trust boundary.
    /// If the script drifts from the decoder, the demo silently does nothing —
    /// which is the exact failure this whole package is shaped to prevent.
    @Test("every tool call in the shipped scripts decodes")
    func scriptsDecode() async throws {
        let scripts: [(String, [MockVoiceSession.Beat])] = [
            ("greeting", MockVoiceSession.greeting),
            ("crisis", MockVoiceSession.crisis),
            ("dropAndRecover", MockVoiceSession.dropAndRecover),
        ]
        for (name, script) in scripts {
            for case .calls(let call) in script {
                #expect(
                    (try? CalTool(call)) != nil,
                    "'\(name)' calls \(call.name) with arguments the app would reject"
                )
            }
        }
    }

    /// The one script whose tool call is *meant* to fail, and the error Cal is
    /// handed has to be one she can recover from out loud.
    @Test("the toolError script produces an actionable rejection")
    func toolErrorScript() throws {
        let calls = MockVoiceSession.toolError.compactMap { beat -> VoiceToolCall? in
            guard case .calls(let call) = beat else { return nil }
            return call
        }
        let call = try #require(calls.first)
        #expect(throws: CalToolError.self) { try CalTool(call) }
    }

    @Test("the greeting script asks for grounding before speaking")
    func greetingScriptShape() throws {
        let tools = MockVoiceSession.greeting.compactMap { beat -> CalTool? in
            guard case .calls(let call) = beat else { return nil }
            return try? CalTool(call)
        }
        #expect(tools.first == .todayStatus)
        #expect(tools.contains(.startCheckIn))
        #expect(tools.count == 2)
    }

    @Test("practice mute keeps the mic gated but still lets Cal speak")
    func practiceMuteAllowsSpeech() async {
        let session = MockVoiceSession(
            script: [.says("before"), .pause, .says("during"), .idle],
            beatDelay: .milliseconds(5)
        )
        let stream = await session.start()
        let finals = LockedBox<[String]>([])
        let collect = Task {
            for await event in stream {
                if case .agentTranscript(let text, true) = event {
                    finals.mutate { $0.append(text) }
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(15))
        await session.setPracticeActive(true)
        #expect(await session.practiceActive)
        #expect(await session.didInterrupt == false)
        try? await Task.sleep(for: .milliseconds(40))
        await session.setPracticeActive(false)
        await session.end()
        _ = await collect.value
        let spoken = finals.value
        #expect(spoken.contains("before"))
        #expect(spoken.contains("during"))
    }

    @Test("a silent hold cuts Cal and drops later speech")
    func silentHoldSuppressesSpeech() async {
        let session = MockVoiceSession(
            script: [.says("before"), .pause, .says("during"), .idle],
            beatDelay: .milliseconds(5)
        )
        let stream = await session.start()
        let finals = LockedBox<[String]>([])
        let collect = Task {
            for await event in stream {
                if case .agentTranscript(let text, true) = event {
                    finals.mutate { $0.append(text) }
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(15))
        await session.setSilentHold(true)
        #expect(await session.silentHold)
        #expect(await session.didInterrupt)
        try? await Task.sleep(for: .milliseconds(40))
        await session.setSilentHold(false)
        await session.end()
        _ = await collect.value
        let spoken = finals.value
        #expect(spoken.contains("before"))
        #expect(!spoken.contains("during"))
    }

    // MARK: -

    /// Drains a session, answering every tool call so the script can proceed.
    private func collect(from session: MockVoiceSession) async -> [VoiceEvent] {
        let stream = await session.start()
        var events: [VoiceEvent] = []
        for await event in stream {
            events.append(event)
            if case .toolCall(let call) = event {
                await session.respond(to: call.id, with: .ok("ok"))
            }
        }
        return events
    }
}

/// Tiny mutex box so a collect task can share finals with the test body.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
