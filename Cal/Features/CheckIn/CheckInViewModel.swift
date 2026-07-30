import CalData
import CalKit
import Foundation
import Observation

/// Drives `CheckInFlow` and persists after every transition.
///
/// The state machine itself lives in `CalKit` and is tested there without a
/// simulator; this type is the thin layer that owns the draft score, saves, and
/// surfaces errors (ARCHITECTURE.md §4).
@Observable
final class CheckInViewModel {
    private(set) var flow: CheckInFlow
    /// The score the slider is currently showing, before the user commits it.
    var draftScore: Score
    private(set) var saveFailed = false

    private let store: any CoherenceStoring
    private let dates: any DateProvider

    /// Anchored at the midpoint. Worth flagging: for a clinical instrument a
    /// pre-set default anchors the answer, and 5 is exactly the premium
    /// regulation threshold — so a user who taps straight through gets offered an
    /// exercise. That errs toward offering help, which is the safer bias, but
    /// whether the scale should start unset is Dr. Mia's call (§20).
    static let defaultScore = Score(clamping: 5)

    init(kind: CheckInKind, store: any CoherenceStoring, dates: any DateProvider) {
        self.store = store
        self.dates = dates
        self.draftScore = Self.defaultScore
        self.flow = CheckInFlow(
            kind: kind,
            localDate: dates.today,
            timeZoneIdentifier: dates.calendar.timeZone.identifier
        )
    }

    // MARK: Derived state for the view

    var progress: (answered: Int, total: Int) { flow.progress }
    var isComplete: Bool { flow.isComplete }

    /// The exercise to play for the current regulation step.
    var currentExercise: Exercise? {
        guard case .regulation(_, let slug) = flow.step else { return nil }
        return Exercise.bundled(slug: slug) ?? Exercise.placeholder
    }

    // MARK: Transitions

    func submitRating() async {
        flow.submitRating(draftScore, now: dates.now)
        resetDraft()
        await persist()
    }

    func completeExercise() async {
        flow.completeRegulation()
        resetDraft()
    }

    func skipExercise() async {
        flow.skipRegulation(now: dates.now)
        resetDraft()
        await persist()
    }

    func submitReRating() async {
        flow.submitReRating(draftScore, now: dates.now)
        resetDraft()
        await persist()
    }

    private func resetDraft() {
        draftScore = Self.defaultScore
    }

    /// Saves after every step rather than once at the end, so a backgrounded or
    /// crashed app doesn't lose a half-finished check-in. The store upserts by id,
    /// so repeated saves are cheap and don't accumulate rows.
    private func persist() async {
        do {
            try await store.save(flow.checkIn)
            saveFailed = false
        } catch {
            // Never block the flow on a write failure: the ratings are still in
            // memory, the user can finish, and the outbox retries. Losing the
            // session because the disk hiccuped would be the worse outcome.
            saveFailed = true
        }
    }
}
