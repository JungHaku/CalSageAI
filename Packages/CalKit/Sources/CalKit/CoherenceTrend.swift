import Foundation

/// How trend points are bucketed.
public enum TrendGranularity: String, CaseIterable, Sendable {
    case day, week, month

    public var displayName: String {
        switch self {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }
}

/// One bucket on a trend chart.
///
/// `averageBefore` and `averageAfter` are optional so a period with no check-in
/// is representable as a **gap**. Interpolating across a missed day, or plotting
/// it as zero, would both invent data — a student who skipped Tuesday did not
/// score zero on Tuesday.
public struct TrendPoint: Sendable, Equatable, Identifiable {
    public let periodStart: LocalDate
    public let averageBefore: Double?
    public let averageAfter: Double?
    public let checkInCount: Int

    public var id: String { periodStart.iso }
    public var isEmpty: Bool { checkInCount == 0 }

    /// Improvement within this period, when anything was regulated.
    public var delta: Double? {
        guard let before = averageBefore, let after = averageAfter, after != before else { return nil }
        return after - before
    }

    public init(
        periodStart: LocalDate,
        averageBefore: Double?,
        averageAfter: Double?,
        checkInCount: Int
    ) {
        self.periodStart = periodStart
        self.averageBefore = averageBefore
        self.averageAfter = averageAfter
        self.checkInCount = checkInCount
    }
}

/// A bucketed series over a window, plus the facts a chart needs to render
/// honestly.
public struct CoherenceTrend: Sendable, Equatable {
    public let granularity: TrendGranularity
    /// Contiguous buckets, oldest first, **including empty ones** — so gaps are
    /// visible rather than silently closed up.
    public let points: [TrendPoint]

    /// Buckets that actually contain data.
    public var populated: [TrendPoint] { points.filter { !$0.isEmpty } }

    /// Below this, a line is noise dressed as a trend. Three points is the
    /// minimum that can show a direction at all, and even that is weak — the UI
    /// says "not enough yet" rather than drawing something over-interpretable.
    public static let minimumPointsForTrend = 3

    public var hasEnoughForTrend: Bool { populated.count >= Self.minimumPointsForTrend }

    /// The y-axis domain. **Always the full 0–10 scale**, never auto-fitted to the
    /// data: on a bounded self-report scale a zoomed axis turns a 0.3 wobble into
    /// a dramatic cliff, which is the classic misleading-chart failure and would
    /// overstate both improvement and decline.
    public static let scaleDomain: ClosedRange<Double> = 0...10

    /// A trend with nothing in it.
    ///
    /// The memberwise initialiser stays internal so only `build` can produce a
    /// populated series — buckets have to be contiguous and correctly spaced for
    /// the gap logic to mean anything. This is the one named exception, for
    /// callers that need a safe starting value.
    public static func empty(granularity: TrendGranularity = .day) -> CoherenceTrend {
        CoherenceTrend(granularity: granularity, points: [])
    }

    /// Contiguous runs of populated buckets.
    ///
    /// A charting library draws one connected line per series, so plotting all
    /// points as a single series would draw a straight segment across a week the
    /// student skipped — inventing a smooth decline (or recovery) that never
    /// happened. Splitting into runs makes each gap an actual gap.
    public var segments: [[TrendPoint]] {
        var runs: [[TrendPoint]] = []
        var current: [TrendPoint] = []
        for point in points {
            if point.isEmpty {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

extension CoherenceTrend {
    public static func build(
        history: [CheckIn],
        granularity: TrendGranularity,
        from start: LocalDate,
        to end: LocalDate,
        calendar: Calendar
    ) -> CoherenceTrend {
        let completed = history.filter(\.isComplete)

        // Group by the bucket each check-in falls in.
        var buckets: [LocalDate: [CheckIn]] = [:]
        for checkIn in completed where checkIn.localDate >= start && checkIn.localDate <= end {
            let key = bucketStart(for: checkIn.localDate, granularity: granularity, calendar: calendar)
            buckets[key, default: []].append(checkIn)
        }

        // Walk the whole window so empty periods are emitted, not skipped.
        var points: [TrendPoint] = []
        var cursor = bucketStart(for: start, granularity: granularity, calendar: calendar)
        let last = bucketStart(for: end, granularity: granularity, calendar: calendar)

        while cursor <= last {
            let inBucket = buckets[cursor] ?? []
            let befores = inBucket.compactMap(\.averageBefore)
            let afters = inBucket.compactMap(\.averageAfter)
            points.append(
                TrendPoint(
                    periodStart: cursor,
                    averageBefore: befores.isEmpty ? nil : befores.reduce(0, +) / Double(befores.count),
                    averageAfter: afters.isEmpty ? nil : afters.reduce(0, +) / Double(afters.count),
                    checkInCount: inBucket.count
                )
            )
            guard let next = advance(cursor, granularity: granularity, calendar: calendar),
                  next > cursor
            else { break }
            cursor = next
        }

        return CoherenceTrend(granularity: granularity, points: points)
    }

    static func bucketStart(
        for day: LocalDate,
        granularity: TrendGranularity,
        calendar: Calendar
    ) -> LocalDate {
        switch granularity {
        case .day: day
        case .week: day.weekStart(in: calendar)
        case .month: LocalDate(year: day.year, month: day.month, day: 1)
        }
    }

    private static func advance(
        _ day: LocalDate,
        granularity: TrendGranularity,
        calendar: Calendar
    ) -> LocalDate? {
        switch granularity {
        case .day: day.adding(days: 1, in: calendar)
        case .week: day.adding(days: 7, in: calendar)
        case .month:
            day.month == 12
                ? LocalDate(year: day.year + 1, month: 1, day: 1)
                : LocalDate(year: day.year, month: day.month + 1, day: 1)
        }
    }
}

/// One category's standing over a window — the data behind the before→after
/// dumbbell.
public struct CategorySummary: Sendable, Equatable, Identifiable {
    public let category: CoherenceCategory
    public let averageBefore: Double
    /// `nil` when this category was never low enough to regulate in the window.
    public let averageAfter: Double?
    public let timesRated: Int
    public let timesRegulated: Int

    public var id: String { category.rawValue }

    public var delta: Double? {
        guard let averageAfter else { return nil }
        return averageAfter - averageBefore
    }

    public init(
        category: CoherenceCategory,
        averageBefore: Double,
        averageAfter: Double?,
        timesRated: Int,
        timesRegulated: Int
    ) {
        self.category = category
        self.averageBefore = averageBefore
        self.averageAfter = averageAfter
        self.timesRated = timesRated
        self.timesRegulated = timesRegulated
    }
}

extension CategorySummary {
    /// Per-category summaries over a window, weakest first.
    ///
    /// Weakest-first because the useful question is "where do I keep getting
    /// stuck", not "what am I already good at". Ties break on category order so
    /// the list is stable between renders.
    public static func build(
        history: [CheckIn],
        from start: LocalDate,
        to end: LocalDate
    ) -> [CategorySummary] {
        let scores = history
            .filter { $0.isComplete && $0.localDate >= start && $0.localDate <= end }
            .flatMap(\.scores)
            .filter { $0.category != .overall }

        let grouped = Dictionary(grouping: scores, by: \.category)

        return grouped
            .map { category, entries -> CategorySummary in
                let befores = entries.map { Double($0.before.value) }
                let afters = entries.compactMap { $0.after.map { Double($0.value) } }
                return CategorySummary(
                    category: category,
                    averageBefore: befores.reduce(0, +) / Double(befores.count),
                    averageAfter: afters.isEmpty ? nil : afters.reduce(0, +) / Double(afters.count),
                    timesRated: entries.count,
                    timesRegulated: afters.count
                )
            }
            .sorted {
                (
                    $0.averageBefore,
                    CoherenceCategory.fullCheckIn.firstIndex(of: $0.category) ?? .max
                ) < (
                    $1.averageBefore,
                    CoherenceCategory.fullCheckIn.firstIndex(of: $1.category) ?? .max
                )
            }
    }
}
