import CalContent
import CalData
import CalKit
import Foundation
import Observation

/// Drives `CheckInFlow` and persists after every transition.
///
/// The state machine lives in `CalKit` and is tested there without a simulator
/// (ARCHITECTURE.md §11); this is the thin layer that owns the draft score,
/// resolves authored content, saves, and surfaces errors.
@Observable
final class CheckInViewModel {
    private(set) var flow: CheckInFlow
    /// The score the slider is showing. **`nil` until the student answers** — the
    /// scale starts unset on purpose (§7).
    var draftScore: Score?
    private(set) var saveFailed = false
    private(set) var currentExercise: Exercise?

    private let store: any CoherenceStoring
    private let content: any ContentRepository
    private let dates: any DateProvider

    init(
        kind: CheckInKind,
        store: any CoherenceStoring,
        content: any ContentRepository,
        dates: any DateProvider
    ) {
        self.store = store
        self.content = content
        self.dates = dates
        self.flow = CheckInFlow(
            kind: kind,
            localDate: dates.today,
            timeZoneIdentifier: dates.calendar.timeZone.identifier
        )
    }

    // MARK: Derived state

    var progress: (answered: Int, total: Int) { flow.progress }
    var isComplete: Bool { flow.isComplete }
    /// Continue stays disabled until the scale has been touched.
    var canSubmit: Bool { draftScore != nil }

    /// Loads authored copy and per-category exercise assignments from the content
    /// repository, replacing `CalKit`'s compiled-in seed. Called once on appear.
    func loadContent() async {
        do {
            let questions = try await content.questions()
            var exercises: [CoherenceCategory: String] = [:]
            for category in flow.checkIn.kind.categories {
                if let exercise = try await content.exercise(for: category) {
                    exercises[category] = exercise.slug
                }
            }
            flow = CheckInFlow(
                kind: flow.checkIn.kind,
                localDate: dates.today,
                timeZoneIdentifier: dates.calendar.timeZone.identifier,
                copy: questions,
                exercises: exercises,
                id: flow.checkIn.id
            )
        } catch {
            // The bundled seed in CalKit already covers every category, so a
            // content failure degrades to compiled-in copy rather than a blank
            // screen. Nothing to surface to the student.
        }
    }

    // MARK: Transitions

    func submitRating() async {
        guard let draftScore else { return }
        flow.submitRating(draftScore, now: dates.now)
        resetDraft()
        await resolveExercise()
        await persist()
    }

    func completeExercise() async {
        flow.completeRegulation()
        resetDraft()
        currentExercise = nil
    }

    func skipExercise() async {
        flow.skipRegulation(now: dates.now)
        resetDraft()
        currentExercise = nil
        await persist()
    }

    func submitReRating() async {
        guard let draftScore else { return }
        flow.submitReRating(draftScore, now: dates.now)
        resetDraft()
        await persist()
    }

    private func resetDraft() {
        draftScore = nil
    }

    private func resolveExercise() async {
        guard case .regulation(_, let slug) = flow.step else {
            currentExercise = nil
            return
        }
        // Falls back to the bundled placeholder so a low score always has
        // somewhere to go, even for a category Dr. Mia hasn't authored yet.
        currentExercise = (try? await content.exercise(slug: slug)) ?? Exercise.placeholder
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
            // memory, the student can finish, and the data is retried on the next
            // step. Losing the session because the disk hiccuped is the worse
            // outcome.
            saveFailed = true
        }
    }
}
