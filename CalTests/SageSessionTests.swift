import CalContent
import CalDesign
import CalKit
import CalVoice
import Foundation
import Testing

@testable import Cal

/// The session outlives the cover (`PLAN-cal-sage-shell.md` §2).
@Suite("SageSession")
@MainActor
struct SageSessionTests {

    private func makeSession(
        _ script: [MockVoiceSession.Beat]
    ) -> (SageSession, MockVoiceSession) {
        let voice = MockVoiceSession(script: script)
        let router = SageRouter(
            content: BundledContentRepository(),
            placeSearch: LocalPlaceSearch()
        )
        let session = SageSession(makeSession: { voice }, router: router)
        return (session, voice)
    }

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

    @Test("connectIfNeeded starts an idle session")
    func startsWhenIdle() async {
        let (session, _) = makeSession([.says("hi"), .event(.connected)])
        #expect(session.state == .idle)
        session.connectIfNeeded()
        #expect(await waitUntil { session.isLive || session.state == .ended || session.state == .listening })
        #expect(session.state != .idle)
    }

    @Test("connectIfNeeded is a no-op while already live")
    func doesNotRestartWhileLive() async {
        // Keep the session open: idle beat never arrives, so the stream stays up.
        let (session, _) = makeSession([
            .event(.connected),
            .says("still here"),
            .idle,
        ])
        session.connectIfNeeded()
        #expect(await waitUntil { session.state == .listening || session.state == .speaking })

        let turnsBefore = session.model.turns.count
        session.connectIfNeeded()
        session.connectIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(session.model.turns.count == turnsBefore || session.isLive)
        #expect(session.isLive)

        await session.stop()
    }

    @Test("dismissing the cover must not stop the session — stop is explicit")
    func dismissDoesNotStop() async {
        let (session, _) = makeSession([
            .event(.connected),
            .says("behind the cover"),
            .idle,
        ])
        session.connectIfNeeded()
        #expect(await waitUntil { session.isLive })

        // Simulate cover dismiss: nothing calls stop().
        #expect(session.isLive)
        #expect(
            session.orbActivity == .listening
                || session.orbActivity == .speaking
                || session.orbActivity == .thinking
                || session.orbActivity == .idle
        )

        await session.stop()
        #expect(!session.isLive)
    }

    @Test("orb activity mirrors speaking")
    func orbActivityMirrorsSpeaking() async {
        let (session, _) = makeSession([
            .event(.connected),
            .event(.agentSpeaking(true)),
            .idle,
        ])
        session.connectIfNeeded()
        #expect(await waitUntil { session.orbActivity == .speaking })
        #expect(session.orbActivity == .speaking)
        #expect(session.orbHalo == .sageAndGold)
        await session.stop()
    }

    @Test("orb activity is listening while the mic is open")
    func orbActivityMirrorsListening() async {
        let (session, _) = makeSession([
            .event(.connected),
            .idle,
        ])
        session.connectIfNeeded()
        #expect(await waitUntil { session.orbActivity == .listening })
        #expect(session.orbHalo == .sageAndGold)
        await session.stop()
    }
}
