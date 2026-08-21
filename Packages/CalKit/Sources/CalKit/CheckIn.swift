import Foundation

/// Which check-in flow was taken. Mirrors the `checkin_kind` Postgres enum.
///
/// `CaseIterable` so `CalToolDescriptor` can derive the values it offers the
/// voice agent from the type rather than restating them — a hand-written copy of
/// this list is one that goes stale the day a third kind is added.
public enum CheckInKind: String, Codable, Sendable, CaseIterable {
    case quick   // free: one `.overall` question
    case full    // daily: the first five of Dr. Mia's categories

    public var categories: [CoherenceCategory] {
        switch self {
        case .quick: [.overall]
        case .full:  CoherenceCategory.fullCheckIn
        }
    }

    public var regulationPolicy: RegulationPolicy {
        switch self {
        case .quick: .quick
        case .full:  .full
        }
    }
}

/// One category's before/after pair.
///
/// Both scores live on one value because that's the product's core claim —
/// Dr. Mia: *"Both scores are saved so the user can see how much their coherence
/// improved in just a few minutes."* Mirrors `checkin_scores` (§5.2), including
/// `delta` and `regulated` being derived rather than stored independently.
public struct CategoryScore: Hashable, Codable, Sendable, Identifiable {
    public let category: CoherenceCategory
    public let before: Score
    public var after: Score?
    public var exerciseSlug: String?

    public var id: String { category.rawValue }

    public init(category: CoherenceCategory, before: Score, after: Score? = nil, exerciseSlug: String? = nil) {
        self.category = category
        self.before = before
        self.after = after
        self.exerciseSlug = exerciseSlug
    }

    /// True once a regulation exercise has been completed and re-rated.
    public var isRegulated: Bool { after != nil }

    /// Improvement from the exercise. `nil` until re-rated — deliberately not
    /// `0`, so "no change" and "not yet measured" stay distinguishable in the
    /// analytics that average this.
    public var delta: Int? {
        guard let after else { return nil }
        return after.value - before.value
    }

    /// The score to report for the day: post-regulation when it exists.
    public var effective: Score { after ?? before }
}

/// One check-in session.
public struct CheckIn: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let kind: CheckInKind
    public let localDate: LocalDate
    public let timeZoneIdentifier: String
    public var scores: [CategoryScore]
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: CheckInKind,
        localDate: LocalDate,
        timeZoneIdentifier: String,
        scores: [CategoryScore] = [],
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.localDate = localDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.scores = scores
        self.completedAt = completedAt
    }

    public var isComplete: Bool { completedAt != nil }

    /// Categories still needing a first rating.
    public var remainingCategories: [CoherenceCategory] {
        let answered = Set(scores.map(\.category))
        return kind.categories.filter { !answered.contains($0) }
    }

    /// Categories whose score triggered regulation but haven't been re-rated yet.
    public var awaitingReRating: [CategoryScore] {
        scores.filter { kind.regulationPolicy.needsRegulation($0.before) && !$0.isRegulated }
    }

    // MARK: Daily aggregates — the same arithmetic as the `daily_coherence` view (§5.2)

    public var averageBefore: Double? { Self.mean(scores.map { Double($0.before.value) }) }

    public var averageAfter: Double? { Self.mean(scores.map { Double($0.effective.value) }) }

    /// Mean improvement across the categories that were actually regulated.
    /// `nil` when nothing was regulated — the product's headline metric (§15) and
    /// worth keeping honest rather than reporting 0.
    public var averageDelta: Double? { Self.mean(scores.compactMap { $0.delta.map(Double.init) }) }

    public var regulatedCount: Int { scores.count(where: \.isRegulated) }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
