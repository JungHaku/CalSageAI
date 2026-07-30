import Foundation

/// One run of a guided practice.
///
/// Recorded whether the practice was finished or abandoned, and whether it was
/// reached from a check-in or from the library. Two reasons this exists rather
/// than the library just playing audio into the void:
///
/// - Dr. Mia's weekly review promises *"most effective regulation exercises"*
///   (`SPEC-premium.md`). That's only computable if regulation sessions are linked
///   to the check-in whose delta they produced — hence `checkInID`.
/// - Abandonment is the honest signal for pacing. A practice people consistently
///   quit 40 seconds into is a timing problem, and §17 question 5 is exactly the
///   question this data answers.
///
/// Mirrors a future `practice_sessions` table and carries the same on-device UUID
/// and sync conventions as everything else (ARCHITECTURE.md §2).
public struct PracticeSession: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let exerciseSlug: String
    public let localDate: LocalDate
    public let startedAt: Date
    public var completedAt: Date?
    /// How far through the timeline the student got, 0…1. Meaningful even when
    /// abandoned — that's the point.
    public var progress: Double
    /// Set when this run was the regulation step of a check-in, `nil` when it was
    /// started from the library.
    public var checkInID: UUID?

    public init(
        id: UUID = UUID(),
        exerciseSlug: String,
        localDate: LocalDate,
        startedAt: Date,
        completedAt: Date? = nil,
        progress: Double = 0,
        checkInID: UUID? = nil
    ) {
        self.id = id
        self.exerciseSlug = exerciseSlug
        self.localDate = localDate
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.progress = max(0, min(1, progress))
        self.checkInID = checkInID
    }

    public var wasCompleted: Bool { completedAt != nil }

    /// Started from the library rather than routed to by a low score.
    public var wasSelfInitiated: Bool { checkInID == nil }

    /// Wall-clock time spent, once finished.
    public var elapsed: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public mutating func finish(at date: Date) {
        completedAt = date
        progress = 1
    }

    public mutating func abandon(atProgress value: Double) {
        progress = max(0, min(1, value))
        completedAt = nil
    }
}

extension Collection where Element == PracticeSession {
    /// Completion rate for a practice — the first number to look at when deciding
    /// whether its pacing is wrong.
    public func completionRate(for slug: String) -> Double? {
        let runs = filter { $0.exerciseSlug == slug }
        guard !runs.isEmpty else { return nil }
        return Double(runs.count(where: \.wasCompleted)) / Double(runs.count)
    }

    /// Practices ordered by how often they're finished, least first — the pacing
    /// review queue.
    public func slugsByCompletionRate() -> [(slug: String, rate: Double)] {
        Dictionary(grouping: self, by: \.exerciseSlug)
            .compactMap { slug, runs in
                let rate = Double(runs.count(where: \.wasCompleted)) / Double(runs.count)
                return (slug, rate)
            }
            .sorted { ($0.rate, $0.slug) < ($1.rate, $1.slug) }
    }
}
