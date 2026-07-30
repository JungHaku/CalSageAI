import Foundation

/// Consecutive-day streaks over check-in dates.
///
/// All arithmetic goes through `LocalDate`, so a user who checks in at 11pm and
/// again at 8am the next morning gets two days, and a streak spanning a DST
/// transition doesn't silently break.
public struct StreakCalculator: Sendable {
    public init() {}

    /// The live streak ending today.
    ///
    /// A streak stays alive if the most recent check-in was **today or
    /// yesterday** — you haven't broken it until a full day passes with nothing.
    /// Checking in at 8am today after checking in yesterday should read as
    /// "2 days", not reset to 1.
    public func currentStreak(
        checkInDates: some Sequence<LocalDate>,
        today: LocalDate,
        calendar: Calendar
    ) -> Int {
        // Future-dated rows (clock skew, a device with the wrong date) shouldn't
        // inflate the streak — ignore anything after today.
        let usable = Set(checkInDates).filter { $0 <= today }.sorted(by: >)
        guard let mostRecent = usable.first else { return 0 }

        guard today.days(since: mostRecent, in: calendar) <= 1 else { return 0 }

        var streak = 1
        var cursor = mostRecent
        for day in usable.dropFirst() {
            if cursor.days(since: day, in: calendar) == 1 {
                streak += 1
                cursor = day
            } else {
                break
            }
        }
        return streak
    }

    /// The longest run of consecutive days ever recorded.
    public func longestStreak(
        checkInDates: some Sequence<LocalDate>,
        calendar: Calendar
    ) -> Int {
        let days = Set(checkInDates).sorted()
        guard !days.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for (previous, current) in zip(days, days.dropFirst()) {
            if current.days(since: previous, in: calendar) == 1 {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }
}
