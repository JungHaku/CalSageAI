import Foundation

/// The compact coherence context sent to the coach model (ARCHITECTURE.md §8.3).
///
/// This exists to *avoid* shipping raw history into a prompt. It is the
/// implementation of two things at once:
///
/// - **Privacy / minimum necessary (§18.2):** a numeric digest leaves the device
///   instead of the user's journal text and full rating history.
/// - **Cost (§10.4):** ~50 tokens instead of ~4,000, and it keeps the prompt's
///   volatile tail small so the cached prefix stays stable.
///
/// It is also, deliberately, a pure function with a deterministic string output —
/// so it is unit-testable, and so a prompt-affecting change shows up as a failing
/// test rather than as a surprise on the invoice.
public struct CoherenceSummary: Hashable, Sendable {
    public let windowDays: Int
    public let averageThisWindow: Double?
    public let averagePreviousWindow: Double?
    public let lowestCategories: [(category: CoherenceCategory, score: Int)]
    public let todayRegulatedCount: Int
    public let todayCategoryCount: Int
    public let todayAverageDelta: Double?

    public init(
        windowDays: Int,
        averageThisWindow: Double?,
        averagePreviousWindow: Double?,
        lowestCategories: [(category: CoherenceCategory, score: Int)],
        todayRegulatedCount: Int,
        todayCategoryCount: Int,
        todayAverageDelta: Double?
    ) {
        self.windowDays = windowDays
        self.averageThisWindow = averageThisWindow
        self.averagePreviousWindow = averagePreviousWindow
        self.lowestCategories = lowestCategories
        self.todayRegulatedCount = todayRegulatedCount
        self.todayCategoryCount = todayCategoryCount
        self.todayAverageDelta = todayAverageDelta
    }

    public static func == (lhs: CoherenceSummary, rhs: CoherenceSummary) -> Bool {
        lhs.promptText == rhs.promptText
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(promptText)
    }

    /// The exact text placed in the prompt's volatile tail.
    public var promptText: String {
        var lines: [String] = []

        if let avg = averageThisWindow {
            var line = "\(windowDays)-day avg coherence \(Self.oneDecimal(avg))"
            if let previous = averagePreviousWindow {
                let direction = avg >= previous ? "up" : "down"
                line += " (\(direction) from \(Self.oneDecimal(previous)))"
            }
            lines.append(line + ".")
        }

        if !lowestCategories.isEmpty {
            let parts = lowestCategories.map { "\($0.category.displayName.lowercased()) \($0.score)" }
            lines.append("Lowest categories: " + parts.joined(separator: ", ") + ".")
        }

        if todayCategoryCount > 0 {
            var line = "Today: regulated \(todayRegulatedCount) of \(todayCategoryCount) categories"
            if let delta = todayAverageDelta {
                let sign = delta >= 0 ? "+" : ""
                line += ", avg improvement \(sign)\(Self.oneDecimal(delta))"
            }
            lines.append(line + ".")
        }

        // No streak. Deliberately, and it is not an oversight to correct.
        //
        // §7.1 decided against showing a daily streak at all: the gamification
        // evidence associates streak mechanics with pressure and diminished
        // meaning, the engagement→outcome link is small (pooled r = 0.16), and
        // median users practise about three times a month — so a daily count
        // marks most people as failing. Home leads with days-practised instead.
        //
        // Putting the number in Cal's context would route it straight back to the
        // student in conversation ("nice work on your 18-day streak!") — the
        // metric the UI refuses to display, delivered by the warmest surface in
        // the app. `CoherenceSummaryTests.digestNeverMentionsAStreak` fails if it
        // comes back.
        return lines.joined(separator: "\n")
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

extension CoherenceCategory {
    public var displayName: String {
        switch self {
        case .overall:             "Overall"
        case .safety:              "Safety"
        case .breath:              "Breath"
        case .presence:            "Presence"
        case .emotionalFlow:       "Emotional flow"
        case .bodyAwareness:       "Body awareness"
        case .choice:              "Choice"
        case .connection:          "Connection"
        case .energy:              "Energy"
        case .innerKnowing:        "Inner knowing"
        case .authenticExpression: "Authentic expression"
        }
    }
}

extension CoherenceSummary {
    /// Build a summary from a history of completed check-ins.
    ///
    /// `history` may be in any order and may contain incomplete check-ins; those
    /// are ignored, because a half-finished check-in shouldn't move the averages
    /// Cal reasons about.
    public static func build(
        history: [CheckIn],
        today: LocalDate,
        calendar: Calendar,
        windowDays: Int = 7,
        lowestCount: Int = 3
    ) -> CoherenceSummary {
        let completed = history.filter(\.isComplete)

        func average(from lowerBound: Int, to upperBound: Int) -> Double? {
            let window = completed.filter {
                let age = today.days(since: $0.localDate, in: calendar)
                return age >= lowerBound && age < upperBound
            }
            let values = window.compactMap(\.averageAfter)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        // Lowest categories are drawn from the current window's *pre-regulation*
        // scores: the point is which dimensions keep showing up low, not how well
        // an exercise patched them afterwards.
        var sums: [CoherenceCategory: (total: Int, count: Int)] = [:]
        for checkIn in completed
        where today.days(since: checkIn.localDate, in: calendar) < windowDays {
            for score in checkIn.scores where score.category != .overall {
                let existing = sums[score.category] ?? (0, 0)
                sums[score.category] = (existing.total + score.before.value, existing.count + 1)
            }
        }
        let lowest = sums
            .map { (category: $0.key, score: Int((Double($0.value.total) / Double($0.value.count)).rounded())) }
            .sorted { ($0.score, $0.category.rawValue) < ($1.score, $1.category.rawValue) }
            .prefix(lowestCount)

        let todays = completed.filter { $0.localDate == today }

        return CoherenceSummary(
            windowDays: windowDays,
            averageThisWindow: average(from: 0, to: windowDays),
            averagePreviousWindow: average(from: windowDays, to: windowDays * 2),
            lowestCategories: Array(lowest),
            todayRegulatedCount: todays.reduce(0) { $0 + $1.regulatedCount },
            todayCategoryCount: todays.reduce(0) { $0 + $1.scores.count },
            todayAverageDelta: {
                let deltas = todays.flatMap { $0.scores.compactMap { $0.delta.map(Double.init) } }
                guard !deltas.isEmpty else { return nil }
                return deltas.reduce(0, +) / Double(deltas.count)
            }()
        )
    }
}
