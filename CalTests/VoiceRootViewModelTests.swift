import CalContent
import CalKit
import CalVoice
import Foundation
import Testing

@testable import Cal

/// What the person is left looking at.
///
/// No simulator, no microphone, no socket — the same bargain `ChatViewModelTests`
/// makes. The scripts here deliberately omit `.idle` so the event loop ends and
/// `waitForScript()` returns.
@Suite("VoiceRootViewModel")
@MainActor
struct VoiceRootViewModelTests {

    private func makeModel(
        _ script: [MockVoiceSession.Beat],
        remember: (@MainActor @Sendable (String, String) -> Void)? = nil
    ) -> (VoiceRootViewModel, SageRouter, MockVoiceSession) {
        let session = MockVoiceSession(script: script)
        let router = SageRouter(
            content: BundledContentRepository(),
            placeSearch: LocalPlaceSearch()
        )
        let model = VoiceRootViewModel(
            makeSession: { session },
            router: router,
            remember: remember
        )
        return (model, router, session)
    }

    /// Bounded polling, for the cases where the session deliberately stays open.
    /// Returns the condition's final value rather than hanging, so a regression
    /// is a failed expectation instead of a stuck suite.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Transcript

    @Test("both sides of the conversation reach the transcript")
    func transcript() async {
        let (model, _, _) = makeModel([.says("How's today starting out?"), .hears("pretty rough")])
        model.start()
        await model.waitForScript()

        #expect(model.turns.map(\.speaker) == [.cal, .student])
        #expect(model.turns.map(\.text) == ["How's today starting out?", "pretty rough"])
        // Nothing half-said is left hanging around once a turn completes.
        #expect(model.partialCal.isEmpty)
        #expect(model.partialStudent.isEmpty)
    }

    @Test("a finished session ends in a terminal state")
    func endsCleanly() async {
        let (model, _, _) = makeModel([.says("bye")])
        model.start()
        await model.waitForScript()
        #expect(!model.isLive)
    }

    // MARK: Cal drives

    @Test("a tool call moves the screen and is answered")
    func toolCallNavigates() async {
        let (model, router, session) = makeModel([
            .calls(VoiceToolCall(id: "c1", name: CalTool.Name.openScreen, json: #"{"screen":"study"}"#))
        ])
        model.start()
        await model.waitForScript()

        #expect(router.path == [.study])
        let responses = await session.responses
        #expect(responses.count == 1)
        #expect(responses.first?.result.isError == false)
    }

    /// The person should be able to see that Cal moved the screen, not just that
    /// it moved.
    @Test("what Cal did shows up in the transcript")
    func toolCallIsVisible() async {
        let (model, _, _) = makeModel([
            .calls(VoiceToolCall(id: "c1", name: CalTool.Name.todayStatus))
        ])
        model.start()
        await model.waitForScript()

        #expect(model.turns.contains { $0.speaker == .action && $0.text == "Getting oriented" })
    }

    /// A rejected call must reach Cal with a reason, or she will keep talking as
    /// though it worked.
    @Test("a rejected tool call is reported to Cal and to the person")
    func toolCallRejected() async {
        let (model, router, session) = makeModel([
            .calls(
                VoiceToolCall(
                    id: "c1", name: CalTool.Name.playPractice,
                    json: #"{"slug":""}"#
                )
            )
        ])
        model.start()
        await model.waitForScript()

        let responses = await session.responses
        #expect(responses.first?.result.isError == true)
        #expect(responses.first?.result.text.contains("slug") == true)
        #expect(model.turns.contains { $0.speaker == .action && $0.text.contains("slug") })
        #expect(router.path.isEmpty)
    }

    @Test("a tool the app cannot honour still gets an answer")
    func unwiredToolAnswered() async {
        let (model, _, session) = makeModel([
            .calls(VoiceToolCall(id: "c1", name: CalTool.Name.stopPractice))
        ])
        model.start()
        await model.waitForScript()

        let responses = await session.responses
        #expect(responses.count == 1, "an unanswered tool call deadlocks a real session")
        #expect(responses.first?.result.isError == true)
        #expect(responses.first?.result.text.contains("No practice") == true)
    }

    @Test("play_practice quiets the session until the run resolves")
    func practiceQuietsSession() async {
        let session = MockVoiceSession(script: [
            .calls(VoiceToolCall(
                id: "c1", name: CalTool.Name.playPractice,
                json: #"{"slug":"study-reset"}"#
            )),
            .says("How was that?"),
        ])
        let practices = PracticeRunCoordinator()
        let router = SageRouter(
            content: BundledContentRepository(),
            placeSearch: LocalPlaceSearch(),
            practices: practices
        )
        let model = VoiceRootViewModel(makeSession: { session }, router: router)
        model.start()

        #expect(await waitUntil { practices.isRunning })
        #expect(await session.practiceActive)
        #expect(await session.didInterrupt == false)

        practices.resolve(.completed)
        await model.waitForScript()

        #expect(await waitUntil { !practices.isRunning })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await session.practiceActive == false)
        let responses = await session.responses
        #expect(responses.first?.result.isError == false)
        #expect(responses.first?.result.text.contains("Speak this script") == true)
    }

    // MARK: Safety

    /// The whole point of §7. Cal is cut off, the crisis card is raised, and the
    /// follow-up line in the script is never spoken.
    ///
    /// Note this cannot `waitForScript()`: an interrupt stops Cal talking, it
    /// does not hang up, so the stream stays open exactly as a live session
    /// would. Waiting for the end here would wait forever — which is the
    /// behaviour we want and the test we must not write.
    @Test("an acute disclosure interrupts Cal and raises the card")
    func crisisInterrupts() async {
        let (model, _, session) = makeModel([
            .says("What's been the hardest part of this week?"),
            .hears("I keep thinking about how I want to kill myself"),
            .says("That sounds really hard, tell me more about that."),
        ])
        model.start()

        #expect(await waitUntil { model.crisis == .acute })
        #expect(await session.didInterrupt)

        // With no beat delay the mock's producer runs ahead of the consumer, so
        // the follow-up line is already sitting in the stream's buffer by the
        // time the interrupt lands. That is the worst case and the one worth
        // pinning: cutting the audio has to also mean discarding what was
        // queued, or the words appear on screen beside a suicide hotline.
        try? await Task.sleep(for: .milliseconds(50))
        let spokenByCal = model.turns.filter { $0.speaker == .cal }.map(\.text)
        #expect(spokenByCal == ["What's been the hardest part of this week?"])
        #expect(!spokenByCal.contains { $0.contains("tell me more") })

        await model.stop()
    }

    /// The person's own words stay on screen. They said them; removing them is
    /// one more thing taken away.
    @Test("the disclosure itself is kept in the transcript")
    func crisisKeepsTheirWords() async {
        let (model, _, _) = makeModel([.hears("I want to kill myself")])
        model.start()

        #expect(await waitUntil { model.crisis == .acute })
        #expect(model.turns.contains { $0.speaker == .student && $0.text.contains("kill myself") })
        await model.stop()
    }

    @Test("dismissing the card leaves the conversation intact")
    func acknowledgingCrisisKeepsTheThread() async {
        let (model, _, _) = makeModel([.hears("I want to kill myself")])
        model.start()
        #expect(await waitUntil { model.crisis == .acute })

        let before = model.turns.count
        model.acknowledgeCrisis()
        #expect(model.crisis == .none)
        #expect(model.turns.count == before)
        await model.stop()
    }

    @Test("an elevated disclosure does not interrupt")
    func elevatedDoesNotInterrupt() async {
        let (model, _, session) = makeModel([
            .hears("some days I just want to die"),
            .says("That sounds heavy."),
        ])
        model.start()
        await model.waitForScript()

        #expect(model.crisis == .elevated)
        #expect(await session.didInterrupt == false)
        #expect(model.turns.contains { $0.speaker == .cal })
    }

    @Test("a settled student turn is remembered")
    func remembersOrdinaryTurns() async {
        let captured = Remembered()
        let (model, _, _) = makeModel(
            [.hears("my chemistry midterm is Thursday morning")],
            remember: { text, severity in captured.append(text, severity) }
        )
        model.start()
        await model.waitForScript()
        #expect(captured.calls.map(\.text) == ["my chemistry midterm is Thursday morning"])
        #expect(captured.calls.map(\.severity) == ["none"])
    }

    @Test("an acute disclosure is not stored")
    func crisisIsNotRemembered() async {
        let captured = Remembered()
        let (model, _, _) = makeModel(
            [.hears("I keep thinking about how I want to kill myself")],
            remember: { text, severity in captured.append(text, severity) }
        )
        model.start()
        #expect(await waitUntil { model.crisis == .acute })
        #expect(captured.calls.isEmpty)
        await model.stop()
    }

    @Test("an elevated disclosure is not stored")
    func elevatedIsNotRemembered() async {
        let captured = Remembered()
        let (model, _, _) = makeModel(
            [.hears("some days I just want to die")],
            remember: { text, severity in captured.append(text, severity) }
        )
        model.start()
        await model.waitForScript()
        #expect(model.crisis == .elevated)
        #expect(captured.calls.isEmpty)
    }

    // MARK: Failures

    @Test("a failure is a state with a reason, not a thrown error")
    func failureState() async {
        let (model, _, _) = makeModel(MockVoiceSession.micDenied)
        model.start()
        await model.waitForScript()

        #expect(model.failure == .microphonePermissionDenied)
        #expect(model.state == .failed(.microphonePermissionDenied))
        #expect(!model.isLive)
    }

    @Test("every failure has something to say", arguments: [
        VoiceFailure.microphonePermissionDenied,
        .microphoneUnavailable,
        .offline,
        .connectionLost(willRetry: true),
        .connectionLost(willRetry: false),
        .agentUnavailable,
        .authenticationFailed,
        .sessionLimitReached,
    ])
    func failureCopyExists(_ failure: VoiceFailure) {
        #expect(!VoiceFailureCopy.headline(for: failure).isEmpty)
        #expect(!VoiceFailureCopy.body(for: failure).isEmpty)
    }

    @Test("a reconnect clears the failure")
    func recovers() async {
        let (model, _, _) = makeModel([
            .event(.failed(.connectionLost(willRetry: true))),
            .event(.connected),
            .says("Sorry — lost you there."),
        ])
        model.start()
        await model.waitForScript()

        #expect(model.failure == nil)
        #expect(model.turns.contains { $0.text.contains("lost you") })
    }

    @Test("presentCheckInForm opens the form sheet flag")
    func presentCheckInForm() async {
        let (model, router, _) = makeModel([.idle])
        model.start()
        #expect(await waitUntil { model.isLive })
        router.presentCheckInForm()
        #expect(router.showingCheckInForm == true)
        await model.stop()
    }
}

private final class Remembered: @unchecked Sendable {
    struct Call {
        let text: String
        let severity: String
    }
    private let lock = NSLock()
    private var stored: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func append(_ text: String, _ severity: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Call(text: text, severity: severity))
    }
}
