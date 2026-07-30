import Foundation

/// Everything the home screen shows, computed from history in one pass.
///
/// Pure, so the whole retention surface — streak, today's state, trend, the
/// headline delta — is unit-testable without a simulator or a store.
public struct CoherenceInsights: Sendable, Equatable {
    public let today: LocalDate
    /// Today's completed check-in, if there is one.
    public let todaysCheckIn: CheckIn?
    /// A started-but-unfinished check-in from today, if there is one.
    public let inProgress: CheckIn?
    /// Consecutive weeks with at least one check-in — the streak the UI shows.
    public let currentWeeklyStreak: Int
    /// Consecutive days. Computed but deliberately NOT the headline (see
    /// `StreakCalculator.currentWeeklyStreak`).
    public let currentStreak: Int
    public let longestStreak: Int
    public let totalCheckIns: Int
    public let windowAverage: Double?
    public let previousWindowAverage: Double?
    /// Mean before→after improvement across every regulated category ever
    /// recorded. The product's actual claim (§15) and the number worth leading
    /// with, rather than the streak.
    public let meanDelta: Double?
    /// Distinct days with a completed check-in in the trailing window.
    public let daysPracticedInWindow: Int
    public let windowDays: Int

    public var hasCheckedInToday: Bool { todaysCheckIn != nil }

    /// Direction of travel, `nil` when there isn't enough history to say.
    public enum Trend: String, Sendable { case up, down, steady }

    public var trend: Trend? {
        guard let current = windowAverage, let previous = previousWindowAverage else { return nil }
        let difference = current - previous
        // A tenth of a point on a 0–10 scale is noise, not a trend. Calling it one
        // would make the app claim improvement that isn't there.
        if abs(difference) < 0.1 { return .steady }
        return difference > 0 ? .up : .down
    }

    /// How many of the last `windowDays` had a check-in.
    ///
    /// Offered alongside the streak deliberately. Consistency is the honest
    /// measure — "18 of the last 30 days" survives a missed Tuesday, where a
    /// streak resets to zero and takes the credit with it.
    public var consistency: Double {
        guard windowDays > 0 else { return 0 }
        return Double(daysPracticedInWindow) / Double(windowDays)
    }
}

extension CoherenceInsights {
    public static func build(
        history: [CheckIn],
        today: LocalDate,
        calendar: Calendar,
        windowDays: Int = 30,
        averageWindowDays: Int = 7
    ) -> CoherenceInsights {
        let completed = history.filter(\.isComplete)
        let calculator = StreakCalculator()
        let dates = completed.map(\.localDate)

        func average(from lowerBound: Int, to upperBound: Int) -> Double? {
            let values = completed
                .filter {
                    let age = today.days(since: $0.localDate, in: calendar)
                    return age >= lowerBound && age < upperBound
                }
                .compactMap(\.averageAfter)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        let deltas = completed.flatMap { $0.scores.compactMap { $0.delta.map(Double.init) } }

        let practicedDays = Set(
            completed
                .map(\.localDate)
                .filter { (0..<windowDays).contains(today.days(since: $0, in: calendar)) }
        )

        return CoherenceInsights(
            today: today,
            todaysCheckIn: completed.first { $0.localDate == today },
            inProgress: history.first { $0.localDate == today && !$0.isComplete },
            currentWeeklyStreak: calculator.currentWeeklyStreak(
                checkInDates: dates, today: today, calendar: calendar
            ),
            currentStreak: calculator.currentStreak(checkInDates: dates, today: today, calendar: calendar),
            longestStreak: calculator.longestStreak(checkInDates: dates, calendar: calendar),
            totalCheckIns: completed.count,
            windowAverage: average(from: 0, to: averageWindowDays),
            previousWindowAverage: average(from: averageWindowDays, to: averageWindowDays * 2),
            meanDelta: deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count),
            daysPracticedInWindow: practicedDays.count,
            windowDays: windowDays
        )
    }

    /// Empty state, for a first launch.
    public static func empty(today: LocalDate, windowDays: Int = 30) -> CoherenceInsights {
        CoherenceInsights(
            today: today, todaysCheckIn: nil, inProgress: nil,
            currentWeeklyStreak: 0, currentStreak: 0, longestStreak: 0, totalCheckIns: 0,
            windowAverage: nil, previousWindowAverage: nil, meanDelta: nil,
            daysPracticedInWindow: 0, windowDays: windowDays
        )
    }
}
