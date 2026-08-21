import Foundation
import Testing

@testable import CalKit

@Suite("CheckInFlow")
struct CheckInFlowTests {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let today = LocalDate(iso: "2026-07-29")!

    private func flow(_ kind: CheckInKind) -> CheckInFlow {
        CheckInFlow(kind: kind, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
    }

    private func score(_ value: Int) -> Score { Score(clamping: value) }

    // MARK: Shape

    @Test("a full check-in opens on safety, the first of Dr. Mia's five")
    func opensOnFirstCategory() {
        #expect(flow(.full).step.category == .safety)
        #expect(flow(.full).progress == (answered: 0, total: 5))
    }

    @Test("a quick check-in opens on the single overall question")
    func quickOpensOnOverall() {
        let f = flow(.quick)
        #expect(f.step.category == .overall)
        #expect(f.progress == (answered: 0, total: 1))
        if case .rating(let q) = f.step {
            #expect(q.prompt == "How do you feel right here in the moment?")
        } else {
            Issue.record("expected a rating step")
        }
    }

    // MARK: The high-score path

    @Test("a high score skips regulation and moves to the next category")
    func highScoreSkipsRegulation() {
        var f = flow(.full)
        f.submitRating(score(9), now: now)
        #expect(f.step.category == .breath)
        #expect(f.progress == (answered: 1, total: 5))
        #expect(f.checkIn.scores[0].after == nil)
        #expect(f.checkIn.scores[0].exerciseSlug == nil)
    }

    @Test("five high scores complete the check-in with nothing regulated")
    func allHighCompletesDirectly() {
        var f = flow(.full)
        for _ in 0..<5 { f.submitRating(score(9), now: now) }

        #expect(f.isComplete)
        #expect(f.checkIn.completedAt == now)
        #expect(f.checkIn.regulatedCount == 0)
        #expect(f.checkIn.averageBefore == 9.0)
        #expect(f.checkIn.scores.map(\.category) == CoherenceCategory.fullCheckIn)
    }

    // MARK: The low-score path — the spec's core loop

    @Test("a low score routes immediately into regulation, before the next category")
    func lowScoreRoutesIntoRegulation() {
        var f = flow(.full)
        f.submitRating(score(3), now: now)

        guard case .regulation(let question, let slug) = f.step else {
            Issue.record("expected regulation, got \(f.step)")
            return
        }
        #expect(question.category == .safety)
        #expect(slug == "seed-placeholder")
        #expect(f.checkIn.scores[0].exerciseSlug == slug)
        // Still on safety — regulation is immediate, not batched to the end.
        #expect(f.step.category == .safety)
    }

    @Test("completing the exercise asks the category's re-prompt, then advances")
    func regulationThenReRating() {
        var f = flow(.full)
        f.submitRating(score(3), now: now)
        f.completeRegulation()

        guard case .reRating(let question) = f.step else {
            Issue.record("expected reRating, got \(f.step)")
            return
        }
        #expect(question.rePrompt == "How safe does your body feel now?")

        f.submitReRating(score(7), now: now)
        #expect(f.step.category == .breath)
        #expect(f.checkIn.scores[0].after?.value == 7)
        #expect(f.checkIn.scores[0].delta == 4)
    }

    @Test("the tier threshold is honoured: a 5 regulates on full but not on quick")
    func thresholdDiffersByTier() {
        var full = flow(.full)
        full.submitRating(score(5), now: now)
        #expect({ if case .regulation = full.step { true } else { false } }())

        var quick = flow(.quick)
        quick.submitRating(score(5), now: now)
        #expect(quick.isComplete, "a 5 should not regulate on the free quick check-in")
    }

    // MARK: Choice

    // The framework is about restoring choice, so the app must not remove it.
    @Test("skipping the exercise advances without recording an after-score")
    func skipRegulation() {
        var f = flow(.full)
        f.submitRating(score(2), now: now)
        f.skipRegulation(now: now)

        #expect(f.step.category == .breath)
        #expect(f.checkIn.scores[0].after == nil)
        #expect(f.checkIn.scores[0].delta == nil, "a skip must read as unmeasured, not as zero improvement")
        #expect(f.checkIn.regulatedCount == 0)
    }

    @Test("skipping the last category's exercise still completes the check-in")
    func skipOnLastCategoryCompletes() {
        var f = flow(.quick)
        f.submitRating(score(1), now: now)
        f.skipRegulation(now: now)
        #expect(f.isComplete)
        #expect(f.checkIn.completedAt == now)
    }

    // MARK: Robustness

    @Test("transitions sent in the wrong state are ignored rather than corrupting the flow")
    func outOfOrderTransitionsAreNoOps() {
        var f = flow(.full)

        // Not in a regulation step yet.
        f.completeRegulation()
        #expect(f.step.category == .safety)
        f.skipRegulation(now: now)
        #expect(f.step.category == .safety)
        f.submitReRating(score(8), now: now)
        #expect(f.checkIn.scores.isEmpty)

        // A rating submitted while an exercise is pending must not double-record.
        f.submitRating(score(2), now: now)
        f.submitRating(score(9), now: now)
        #expect(f.checkIn.scores.count == 1)
    }

    @Test("nothing happens after completion")
    func completeIsTerminal() {
        var f = flow(.quick)
        f.submitRating(score(10), now: now)
        #expect(f.isComplete)

        let completed = f
        f.submitRating(score(1), now: now)
        f.completeRegulation()
        f.submitReRating(score(1), now: now)
        #expect(f == completed)
    }

    // MARK: Mixed realistic run

    @Test("a mixed run records the right before/after pairs and daily aggregates")
    func mixedRun() {
        var f = flow(.full)
        // safety 8 (fine), breath 3 → 7, presence 9, emotional_flow 5 → 6, body 8
        let plan: [(before: Int, after: Int?)] = [
            (8, nil), (3, 7), (9, nil), (5, 6), (8, nil),
        ]
        for entry in plan {
            f.submitRating(score(entry.before), now: now)
            if let after = entry.after {
                f.completeRegulation()
                f.submitReRating(score(after), now: now)
            }
        }

        #expect(f.isComplete)
        #expect(f.checkIn.regulatedCount == 2)
        #expect(f.checkIn.scores.count == 5)

        let breath = f.checkIn.scores.first { $0.category == .breath }
        #expect(breath?.delta == 4)
        let flowScore = f.checkIn.scores.first { $0.category == .emotionalFlow }
        #expect(flowScore?.delta == 1)
        #expect(f.checkIn.averageDelta == 2.5)  // (4 + 1) / 2
    }

    @Test("server copy overrides the bundled seed, so Dr. Mia can edit without a release")
    func serverCopyWins() {
        let override = CoherenceQuestion(
            category: .safety,
            prompt: "Reworded by Dr. Mia",
            rePrompt: "And now?",
            regulationSummary: "Grounding."
        )
        let f = CheckInFlow(
            kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles",
            copy: [.safety: override]
        )
        if case .rating(let q) = f.step {
            #expect(q.prompt == "Reworded by Dr. Mia")
        } else {
            Issue.record("expected a rating step")
        }
    }

    @Test("a per-category exercise from the server is used instead of the fallback")
    func perCategoryExercise() {
        var f = CheckInFlow(
            kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles",
            exercises: [.safety: "grounding-slow-breath"]
        )
        f.submitRating(score(2), now: now)
        guard case .regulation(_, let slug) = f.step else {
            Issue.record("expected regulation")
            return
        }
        #expect(slug == "grounding-slow-breath")
    }
}
