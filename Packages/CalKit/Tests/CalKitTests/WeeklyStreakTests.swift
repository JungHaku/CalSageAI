import Foundation
import Testing

@testable import CalKit

@Suite("Weekly streak")
struct WeeklyStreakTests {
    let calculator = StreakCalculator()
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func days(_ isos: String...) -> [LocalDate] { isos.compactMap(LocalDate.init(iso:)) }
    private func weekly(_ dates: [LocalDate], today: String) -> Int {
        calculator.currentWeeklyStreak(
            checkInDates: dates, today: LocalDate(iso: today)!, calendar: calendar
        )
    }

    @Test("no history is a zero streak")
    func empty() {
        #expect(weekly([], today: "2026-07-30") == 0)
    }

    @Test("several check-ins in one week count as one week, not several")
    func oneWeekCountsOnce() {
        // Mon–Thu of the same week.
        #expect(weekly(days("2026-07-27", "2026-07-28", "2026-07-29", "2026-07-30"), today: "2026-07-30") == 1)
    }

    // The whole point: a single check-in per week keeps the run alive, so an exam
    // week or a bad stretch never produces a loss event.
    @Test("one check-in per week sustains the streak across four weeks")
    func onePerWeekIsEnough() {
        #expect(weekly(days("2026-07-08", "2026-07-15", "2026-07-22", "2026-07-29"), today: "2026-07-30") == 4)
    }

    @Test("missing several days inside a week doesn't break anything")
    func gapsWithinWeeksAreFine() {
        // Two check-ins a week, ragged, four weeks running.
        let dates = days(
            "2026-07-06", "2026-07-09",
            "2026-07-14", "2026-07-17",
            "2026-07-20", "2026-07-24",
            "2026-07-28"
        )
        #expect(weekly(dates, today: "2026-07-30") == 4)
    }

    @Test("a run ending last week is still alive — the same grace the daily streak gives yesterday")
    func lastWeekStillCounts() {
        #expect(weekly(days("2026-07-15", "2026-07-22"), today: "2026-07-30") == 2)
    }

    @Test("a fully skipped week ends the run")
    func skippedWeekBreaksIt() {
        // Nothing in the weeks of Jul 20 or Jul 27.
        #expect(weekly(days("2026-07-06", "2026-07-13"), today: "2026-07-30") == 0)
    }

    @Test("only the trailing run of weeks counts")
    func onlyTrailingRun() {
        let dates = days("2026-05-04", "2026-05-11", "2026-05-18", "2026-07-22", "2026-07-29")
        #expect(weekly(dates, today: "2026-07-30") == 2)
    }

    @Test("future-dated check-ins can't inflate the streak")
    func futureIgnored() {
        #expect(weekly(days("2026-07-29", "2026-08-20"), today: "2026-07-30") == 1)
    }

    @Test("a run spanning a year boundary is unbroken")
    func acrossNewYear() {
        #expect(weekly(days("2026-12-16", "2026-12-23", "2026-12-30", "2027-01-06"), today: "2027-01-07") == 4)
    }

    @Test("a run spanning both DST transitions is unbroken")
    func acrossDST() {
        // Spring forward 2026-03-08.
        #expect(weekly(days("2026-02-25", "2026-03-04", "2026-03-11", "2026-03-18"), today: "2026-03-19") == 4)
        // Fall back 2026-11-01.
        #expect(weekly(days("2026-10-21", "2026-10-28", "2026-11-04", "2026-11-11"), today: "2026-11-12") == 4)
    }

    // A 30-day daily history is 5 calendar weeks, not 30 — the number shown has to
    // read as weeks or it's just a confusing smaller streak.
    @Test("a 30-day daily history reads as five weeks")
    func dailyHistoryInWeeks() {
        let today = LocalDate(iso: "2026-07-30")!
        let history = CheckIn.syntheticHistory(days: 30, endingOn: today, calendar: calendar)
        let insights = CoherenceInsights.build(history: history, today: today, calendar: calendar)
        #expect(insights.currentStreak == 30)
        #expect(insights.currentWeeklyStreak == 5)
    }
}

@Suite("LocalDate.weekStart")
struct WeekStartTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    @Test("every day in a week maps to the same week start")
    func sameWeek() {
        let starts = ["2026-07-26", "2026-07-27", "2026-07-30", "2026-08-01"]
            .compactMap(LocalDate.init(iso:))
            .map { $0.weekStart(in: calendar) }
        #expect(Set(starts).count == 1, "expected one week start, got \(starts)")
    }

    @Test("adjacent weeks are exactly seven days apart")
    func sevenDaysApart() {
        let a = LocalDate(iso: "2026-07-30")!.weekStart(in: calendar)
        let b = LocalDate(iso: "2026-08-06")!.weekStart(in: calendar)
        #expect(b.days(since: a, in: calendar) == 7)
    }

    @Test("the week start follows the calendar's firstWeekday, not a hard-coded day")
    func respectsFirstWeekday() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2

        let day = LocalDate(iso: "2026-07-30")!
        #expect(day.weekStart(in: sundayFirst) != day.weekStart(in: mondayFirst))
    }

    @Test("a week containing a DST transition still spans seven days")
    func dstWeek() {
        let before = LocalDate(iso: "2026-03-04")!.weekStart(in: calendar)
        let after = LocalDate(iso: "2026-03-11")!.weekStart(in: calendar)
        #expect(after.days(since: before, in: calendar) == 7)
    }
}
