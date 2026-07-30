import Foundation

/// The check-in state machine.
///
/// This is the product (ARCHITECTURE.md §19 Phase 1), so it lives here as pure
/// logic with no UI and no I/O: the view is a rendering of `step`, and every
/// transition is unit-tested without a simulator.
///
/// The shape follows Dr. Mia's premium spec exactly — regulation happens
/// **immediately**, per category, not batched at the end:
///
/// > "If a score is 5 or below, Cal immediately guides the user through a brief
/// > regulation exercise before asking them to rate that category again."
///
/// So the loop per category is: rate → (if low) regulate → re-rate → next.
///
/// Note the threshold differs by tier — see `RegulationPolicy`, and §20 item 9.
public struct CheckInFlow: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Asking for `score_before`.
        case rating(CoherenceQuestion)
        /// Guiding a regulation exercise before re-rating.
        case regulation(CoherenceQuestion, exerciseSlug: String)
        /// Asking for `score_after`.
        case reRating(CoherenceQuestion)
        /// Every category answered; `checkIn.completedAt` is set.
        case complete

        public var category: CoherenceCategory? {
            switch self {
            case .rating(let q), .reRating(let q): q.category
            case .regulation(let q, _): q.category
            case .complete: nil
            }
        }
    }

    public private(set) var checkIn: CheckIn
    public private(set) var step: Step

    /// Authored copy, defaulting to the bundled seed. The server's version wins
    /// when it has one, which is how Dr. Mia edits wording without a release (§8.4).
    private let copy: [CoherenceCategory: CoherenceQuestion]
    private let exercises: [CoherenceCategory: String]
    private let fallbackExerciseSlug: String

    public init(
        kind: CheckInKind,
        localDate: LocalDate,
        timeZoneIdentifier: String,
        copy: [CoherenceCategory: CoherenceQuestion] = CoherenceQuestion.seed,
        exercises: [CoherenceCategory: String] = [:],
        fallbackExerciseSlug: String = "seed-placeholder",
        id: UUID = UUID()
    ) {
        self.checkIn = CheckIn(
            id: id, kind: kind, localDate: localDate, timeZoneIdentifier: timeZoneIdentifier
        )
        self.copy = copy
        self.exercises = exercises
        self.fallbackExerciseSlug = fallbackExerciseSlug

        // A `kind` always has at least one category, so this is never empty.
        let first = kind.categories[0]
        self.step = .rating(Self.question(for: first, copy: copy))
    }

    // MARK: - Progress, for the UI

    /// How many categories have a first rating, out of the total.
    public var progress: (answered: Int, total: Int) {
        (checkIn.scores.count, checkIn.kind.categories.count)
    }

    public var isComplete: Bool { step == .complete }

    // MARK: - Transitions
    //
    // Each takes `now` explicitly rather than reading the clock. Completion time
    // has to be the moment the user finished, not the moment the flow was built,
    // and a hidden `Date()` here would make the completion tests untestable.

    /// Records `score_before`. Routes into regulation when the tier's threshold
    /// says so, otherwise straight to the next category.
    @discardableResult
    public mutating func submitRating(_ score: Score, now: Date) -> Step {
        guard case .rating(let question) = step else { return step }

        checkIn.scores.append(
            CategoryScore(category: question.category, before: score)
        )

        if checkIn.kind.regulationPolicy.needsRegulation(score) {
            let slug = exercises[question.category] ?? fallbackExerciseSlug
            checkIn.scores[checkIn.scores.count - 1].exerciseSlug = slug
            step = .regulation(question, exerciseSlug: slug)
        } else {
            advance(now: now)
        }
        return step
    }

    /// The exercise finished; ask for the second rating.
    @discardableResult
    public mutating func completeRegulation() -> Step {
        guard case .regulation(let question, _) = step else { return step }
        step = .reRating(question)
        return step
    }

    /// The user declined the exercise, or backed out of it.
    ///
    /// This has to exist. Trapping someone in a breathing exercise they don't want
    /// is bad product and worse clinically — the whole framework is about restoring
    /// a sense of choice, so the app can't remove it. `score_after` stays `nil`,
    /// which the analytics already treat as "not measured" rather than "no change".
    @discardableResult
    public mutating func skipRegulation(now: Date) -> Step {
        guard case .regulation = step else { return step }
        advance(now: now)
        return step
    }

    /// Records `score_after` for the category just regulated.
    @discardableResult
    public mutating func submitReRating(_ score: Score, now: Date) -> Step {
        guard case .reRating(let question) = step else { return step }
        if let index = checkIn.scores.lastIndex(where: { $0.category == question.category }) {
            checkIn.scores[index].after = score
        }
        advance(now: now)
        return step
    }

    private mutating func advance(now: Date) {
        if let next = checkIn.remainingCategories.first {
            step = .rating(Self.question(for: next, copy: copy))
        } else {
            checkIn.completedAt = now
            step = .complete
        }
    }

    private static func question(
        for category: CoherenceCategory,
        copy: [CoherenceCategory: CoherenceQuestion]
    ) -> CoherenceQuestion {
        copy[category] ?? CoherenceQuestion.seeded(category)
    }
}
