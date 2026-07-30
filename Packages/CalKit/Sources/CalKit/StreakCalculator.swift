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

    /// Consecutive **weeks** containing at least one check-in.
    ///
    /// This is the streak the app actually shows, and the daily one is not.
    /// The evidence for a wellness app aimed at students points hard this way:
    ///
    /// - A 2025 scoping review of gamification for college students associates
    ///   streak/point mechanics with pressure and diminished meaning.
    /// - The engagement→clinical-outcome link across mental-health apps is real
    ///   but small (pooled r = 0.16), so the upside being bought with that
    ///   pressure is slight.
    /// - Median meditation-app users practise around three times a month, so a
    ///   daily streak would mark most people as failing every single week.
    ///
    /// A weekly count survives an exam week, a flu, or a bad mental-health day
    /// without ever producing a loss event — no freeze inventory, no rescue
    /// dialog, nothing to buy. Nike Run Club does exactly this.
    public func currentWeeklyStreak(
        checkInDates: some Sequence<LocalDate>,
        today: LocalDate,
        calendar: Calendar
    ) -> Int {
        let thisWeek = today.weekStart(in: calendar)
        let weeks = Set(
            checkInDates
                .filter { $0 <= today }
                .map { $0.weekStart(in: calendar) }
        ).sorted(by: >)

        guard let mostRecent = weeks.first else { return 0 }

        // Alive if there was a check-in this week or last week — the same grace
        // the daily streak gives to yesterday, one scale up.
        let gapWeeks = thisWeek.days(since: mostRecent, in: calendar) / 7
        guard gapWeeks <= 1 else { return 0 }

        var streak = 1
        var cursor = mostRecent
        for week in weeks.dropFirst() {
            if cursor.days(since: week, in: calendar) == 7 {
                streak += 1
                cursor = week
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
