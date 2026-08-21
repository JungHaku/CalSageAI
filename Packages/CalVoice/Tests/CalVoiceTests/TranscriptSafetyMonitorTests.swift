import CalKit
import Foundation
import Testing

@testable import CalVoice

/// The path nobody gets to debug live.
///
/// `CrisisDetector` has its own reviewed fixture suite and is not re-tested here.
/// What is tested here is everything the move to voice added: that partials are
/// acted on, that one disclosure fires once, that Cal's own words never trigger
/// it, and that acute means interrupt.
@Suite("TranscriptSafetyMonitor — Layer A on the voice path")
struct TranscriptSafetyMonitorTests {

    @Test("ordinary conversation does nothing")
    func quiet() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume("I've got three midterms this week", isFinal: true) == .none)
        #expect(monitor.actedUpon == .none)
    }

    @Test("an acute disclosure interrupts")
    func acute() {
        var monitor = TranscriptSafetyMonitor()
        let action = monitor.consume("I keep thinking I want to kill myself", isFinal: true)
        #expect(action == .interruptAndEscalate(rule: "kill myself"))
        #expect(monitor.actedUpon == .acute)
    }

    @Test("an elevated disclosure surfaces resources without interrupting")
    func elevated() {
        var monitor = TranscriptSafetyMonitor()
        let action = monitor.consume("some days I just want to die", isFinal: true)
        #expect(action == .surfaceResources(rule: "want to die"))
    }

    /// The whole reason partials are watched: the acute pattern completes before
    /// the sentence does, so the tripwire fires while the student is still
    /// talking rather than after the agent has already been handed the turn.
    @Test("acute fires on a partial, before the sentence finishes")
    func acuteOnPartial() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume("honestly I keep thinking about how I", isFinal: false) == .none)
        #expect(
            monitor.consume("honestly I keep thinking about how I want to kill myself and", isFinal: false)
                == .interruptAndEscalate(rule: "kill myself")
        )
    }

    @Test("elevated waits for the final transcript")
    func elevatedWaits() {
        var monitor = TranscriptSafetyMonitor()
        // Nothing is gained by being early when the action does not interrupt —
        // and a partial reading elevated can still resolve to acute a word later.
        #expect(monitor.consume("some days I just want to die", isFinal: false) == .none)
        #expect(monitor.consume("some days I just want to die", isFinal: true) != .none)
    }

    @Test("a partial that reads elevated can still escalate to acute")
    func elevatedThenAcute() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume("I want to die", isFinal: true) == .surfaceResources(rule: "want to die"))
        #expect(
            monitor.consume("I want to die I've been thinking about suicide", isFinal: true)
                == .interruptAndEscalate(rule: "suicide")
        )
        #expect(monitor.actedUpon == .acute)
    }

    /// One utterance arrives a dozen times as the transcription grows. Without
    /// the latch, that is a dozen interrupts of an already-interrupted session.
    @Test("one disclosure fires exactly once, however many transcripts carry it")
    func firesOnce() {
        var monitor = TranscriptSafetyMonitor()
        let growing = [
            ("I want to kill", false),
            ("I want to kill myself", false),
            ("I want to kill myself and", false),
            ("I want to kill myself and I can't stop", true),
        ]
        let actions = growing.map { monitor.consume($0.0, isFinal: $0.1) }
        #expect(actions.filter { $0 != .none }.count == 1)
        #expect(actions[1] == .interruptAndEscalate(rule: "kill myself"))
    }

    @Test("having escalated, it does not escalate again later in the session")
    func latchHolds() {
        var monitor = TranscriptSafetyMonitor()
        _ = monitor.consume("I want to kill myself", isFinal: true)
        // Re-escalating mid-crisis is its own harm, and the card is already up.
        #expect(monitor.consume("I said I want to kill myself", isFinal: true) == .none)
    }

    @Test("elevated does not re-fire once acted on")
    func elevatedLatches() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume("I want to die", isFinal: true) != .none)
        #expect(monitor.consume("I still want to die", isFinal: true) == .none)
    }

    /// Cal reads the crisis copy out loud. Running the detector over her side of
    /// the transcript would have her trigger herself, in a loop.
    @Test("Cal's own words are never evaluated")
    func agentTranscriptIgnored() {
        var monitor = TranscriptSafetyMonitor()
        let event = VoiceEvent.agentTranscript(
            "If you're thinking about suicide, the 988 line is there any time.", isFinal: true
        )
        #expect(monitor.consume(event) == .none)
        #expect(monitor.actedUpon == .none)
    }

    @Test("non-transcript events are ignored")
    func otherEventsIgnored() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume(.connected) == .none)
        #expect(monitor.consume(.agentSpeaking(true)) == .none)
        #expect(monitor.consume(.failed(.offline)) == .none)
    }

    @Test("asking about the crisis line is not a crisis")
    func benignPhrasing() {
        var monitor = TranscriptSafetyMonitor()
        #expect(monitor.consume("what was that suicide prevention number", isFinal: true) == .none)
    }

    @Test("finalOnly suppresses the partial path")
    func finalOnlyPolicy() {
        var monitor = TranscriptSafetyMonitor(partialPolicy: .finalOnly)
        #expect(monitor.consume("I want to kill myself and", isFinal: false) == .none)
        #expect(monitor.consume("I want to kill myself and I can't stop", isFinal: true) != .none)
    }

    @Test("reset clears the latch for a genuinely new session")
    func reset() {
        var monitor = TranscriptSafetyMonitor()
        _ = monitor.consume("I want to kill myself", isFinal: true)
        monitor.reset()
        #expect(monitor.actedUpon == .none)
        #expect(monitor.consume("I want to kill myself", isFinal: true) != .none)
    }
}
