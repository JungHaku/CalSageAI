import CalKit
import Foundation

/// Layer A, moved onto the voice path.
///
/// `CrisisDetector` is unchanged — same patterns, same `CrisisFixture.all`
/// regression suite, same pending clinician sign-off. What changes is *when* it
/// runs. On the text path it ran before the message was sent, so nothing could be
/// generated in response to a crisis disclosure. Here it runs on transcripts the
/// agent has already received, which means **Cal may have started replying**.
///
/// That gap is the honest cost of handing the loop to a vendor
/// (`PLAN-voice-first.md` §7). Two things narrow it:
///
/// 1. Acute patterns are matched on **partial** transcripts as well as final ones
///    (see `PartialPolicy`), so the tripwire fires as the sentence is being said
///    rather than after it lands.
/// 2. `.interruptAndEscalate` means *cut the audio*, not *show a card over the
///    top*. The text path suppresses the model entirely on acute
///    (`ChatViewModel.handle`); the voice equivalent has to be a real interrupt,
///    or Cal carries on cheerfully underneath a suicide hotline.
///
/// This is a `struct` with `mutating` intake rather than a service, so the whole
/// escalation path is exercised by feeding it a scripted transcript in a unit
/// test. It is the one path nobody gets to debug live.
public struct TranscriptSafetyMonitor: Sendable {
    /// Whether to match before the transcription has settled.
    public enum PartialPolicy: Sendable, Equatable {
        /// Wait for `isFinal`. Fewer false positives, later trigger.
        case finalOnly
        /// Match acute patterns on partials; hold elevated until final.
        ///
        /// The default, because the cost matrix `CrisisDetector` documents is
        /// asymmetric by design: a false positive shows someone a card with a
        /// phone number on it, and a false negative is the worst thing this app
        /// can do. Elevated waits because it does *not* interrupt — there is
        /// nothing to be early for.
        case acuteOnPartials
    }

    /// What the session should do about what it just heard.
    public enum Action: Sendable, Equatable {
        case none
        /// Offer resources alongside a normal reply. Cal keeps talking.
        case surfaceResources(rule: String)
        /// Cut the agent off and present `EmergencyView`.
        case interruptAndEscalate(rule: String)
    }

    private let detector = CrisisDetector()
    private let partialPolicy: PartialPolicy

    /// The highest severity already acted on in this session.
    ///
    /// One utterance arrives many times as the transcription grows, so without
    /// this the same disclosure re-fires on every partial and again on the final —
    /// which at acute would mean interrupting an already-interrupted session, and
    /// at elevated would mean stacking the same resources repeatedly.
    ///
    /// Latched for the **session**, not the turn. Someone who has disclosed
    /// something acute does not stop having disclosed it thirty seconds later, and
    /// re-escalating mid-crisis is its own harm.
    private(set) public var actedUpon: CrisisSeverity = .none

    public init(partialPolicy: PartialPolicy = .acuteOnPartials) {
        self.partialPolicy = partialPolicy
    }

    /// Feed the monitor an event. Returns what to do, once.
    public mutating func consume(_ event: VoiceEvent) -> Action {
        // Only the student's own words. Cal's are the model's output, and running
        // the detector over them would fire on Cal reading the crisis copy aloud.
        guard case .userTranscript(let text, let isFinal) = event else { return .none }
        return consume(text, isFinal: isFinal)
    }

    public mutating func consume(_ text: String, isFinal: Bool) -> Action {
        let assessment = detector.evaluate(text)

        // Nothing new to act on. Note this also covers the case where a partial
        // matched and the final matches the same rule again.
        guard assessment.severity > actedUpon else { return .none }

        switch assessment.severity {
        case .none:
            return .none

        case .acute:
            if !isFinal && partialPolicy == .finalOnly { return .none }
            actedUpon = .acute
            return .interruptAndEscalate(rule: assessment.matchedRule ?? "unknown")

        case .elevated:
            // Elevated never interrupts, so there is nothing to gain from acting
            // on a half-transcribed sentence — and a partial that reads elevated
            // can still resolve to acute a word later.
            guard isFinal else { return .none }
            actedUpon = .elevated
            return .surfaceResources(rule: assessment.matchedRule ?? "unknown")
        }
    }

    /// Clears the latch. For a genuinely new session only — not for dismissing
    /// the crisis card, which leaves the conversation intact by design.
    public mutating func reset() {
        actedUpon = .none
    }
}
