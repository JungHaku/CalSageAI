import Foundation
import Testing

@testable import CalKit

@Suite("StreakCalculator")
struct StreakTests {
    let calculator = StreakCalculator()
    let pacific = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func days(_ isos: String...) -> [LocalDate] {
        isos.compactMap(LocalDate.init(iso:))
    }

    @Test("no check-ins is a zero streak")
    func empty() {
        #expect(calculator.currentStreak(checkInDates: [], today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 0)
        #expect(calculator.longestStreak(checkInDates: [], calendar: pacific) == 0)
    }

    @Test("a run ending today counts through today")
    func endingToday() {
        let dates = days("2026-07-27", "2026-07-28", "2026-07-29")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 3)
    }

    // You haven't broken a streak until a full day passes with nothing. Resetting
    // to 1 the moment the user checks in at 8am would punish them for the clock.
    @Test("a run ending yesterday is still live")
    func endingYesterdayStaysAlive() {
        let dates = days("2026-07-27", "2026-07-28")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 2)
    }

    @Test("a gap of two or more days breaks the streak")
    func gapBreaksIt() {
        let dates = days("2026-07-25", "2026-07-26")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 0)
    }

    @Test("only the trailing consecutive run counts, not total check-ins")
    func onlyTrailingRun() {
        let dates = days("2026-07-01", "2026-07-02", "2026-07-03", "2026-07-28", "2026-07-29")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 2)
    }

    @Test("two check-ins on the same day count once")
    func duplicatesCollapse() {
        let dates = days("2026-07-28", "2026-07-29", "2026-07-29", "2026-07-29")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 2)
    }

    @Test("unsorted input gives the same answer as sorted")
    func orderIndependent() {
        let scrambled = days("2026-07-29", "2026-07-27", "2026-07-28")
        #expect(calculator.currentStreak(checkInDates: scrambled, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 3)
    }

    // A device with a wrong clock, or a row synced from a phone in a later time
    // zone, must not be able to inflate a streak.
    @Test("future-dated check-ins are ignored")
    func futureDatesIgnored() {
        let dates = days("2026-07-28", "2026-07-29", "2026-08-05")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 2)
    }

    @Test("a streak spanning the spring-forward transition is unbroken")
    func springForward() {
        let dates = days("2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-03-09")!, calendar: pacific) == 4)
    }

    @Test("a streak spanning the fall-back transition is unbroken")
    func fallBack() {
        let dates = days("2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-11-02")!, calendar: pacific) == 4)
    }

    @Test("a streak spanning new year is unbroken")
    func acrossNewYear() {
        let dates = days("2026-12-30", "2026-12-31", "2027-01-01")
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2027-01-01")!, calendar: pacific) == 3)
    }

    @Test("longest streak finds the best historical run, not the current one")
    func longest() {
        let dates = days(
            "2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04",  // 4
            "2026-07-10",                                            // 1
            "2026-07-28", "2026-07-29"                               // 2
        )
        #expect(calculator.longestStreak(checkInDates: dates, calendar: pacific) == 4)
        #expect(calculator.currentStreak(checkInDates: dates, today: LocalDate(iso: "2026-07-29")!, calendar: pacific) == 2)
    }

    @Test("a 30-day synthetic history produces a 30-day streak")
    func syntheticHistoryIsContiguous() {
        let today = LocalDate(iso: "2026-07-29")!
        let history = CheckIn.syntheticHistory(days: 30, endingOn: today, calendar: pacific)
        #expect(history.count == 30)
        #expect(calculator.currentStreak(checkInDates: history.map(\.localDate), today: today, calendar: pacific) == 30)
    }
}
