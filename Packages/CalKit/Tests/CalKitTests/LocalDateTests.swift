import Foundation
import Testing

@testable import CalKit

@Suite("LocalDate")
struct LocalDateTests {
    let pacific = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    @Test("ISO round-trips in the format Postgres `date` expects")
    func isoRoundTrip() {
        let day = LocalDate(year: 2026, month: 7, day: 29)
        #expect(day.iso == "2026-07-29")
        #expect(LocalDate(iso: "2026-07-29") == day)
        #expect(LocalDate(iso: "2026-01-05")?.iso == "2026-01-05")
    }

    @Test("malformed ISO strings are rejected rather than silently coerced")
    func isoRejectsGarbage() {
        #expect(LocalDate(iso: "") == nil)
        #expect(LocalDate(iso: "2026-07") == nil)
        #expect(LocalDate(iso: "2026-13-01") == nil)
        #expect(LocalDate(iso: "2026-07-32") == nil)
        #expect(LocalDate(iso: "not-a-date") == nil)
    }

    @Test("day arithmetic crosses month and year boundaries")
    func boundaries() {
        let endOfMonth = LocalDate(year: 2026, month: 1, day: 31)
        #expect(endOfMonth.adding(days: 1, in: pacific) == LocalDate(year: 2026, month: 2, day: 1))

        let newYearsEve = LocalDate(year: 2026, month: 12, day: 31)
        #expect(newYearsEve.adding(days: 1, in: pacific) == LocalDate(year: 2027, month: 1, day: 1))
        #expect(newYearsEve.adding(days: -1, in: pacific) == LocalDate(year: 2026, month: 12, day: 30))
    }

    @Test("leap day exists in 2028 and not in 2026")
    func leapYear() {
        let feb28_2028 = LocalDate(year: 2028, month: 2, day: 28)
        #expect(feb28_2028.adding(days: 1, in: pacific) == LocalDate(year: 2028, month: 2, day: 29))

        let feb28_2026 = LocalDate(year: 2026, month: 2, day: 28)
        #expect(feb28_2026.adding(days: 1, in: pacific) == LocalDate(year: 2026, month: 3, day: 1))
    }

    // The reason LocalDate exists. US Pacific springs forward 2026-03-08 and
    // falls back 2026-11-01; a Date-based implementation drifts by a day here.
    @Test("day arithmetic and differences survive both DST transitions")
    func dstTransitions() {
        let beforeSpring = LocalDate(year: 2026, month: 3, day: 7)
        #expect(beforeSpring.adding(days: 1, in: pacific) == LocalDate(year: 2026, month: 3, day: 8))
        #expect(beforeSpring.adding(days: 2, in: pacific) == LocalDate(year: 2026, month: 3, day: 9))
        #expect(LocalDate(year: 2026, month: 3, day: 9).days(since: beforeSpring, in: pacific) == 2)

        let beforeFall = LocalDate(year: 2026, month: 10, day: 31)
        #expect(beforeFall.adding(days: 2, in: pacific) == LocalDate(year: 2026, month: 11, day: 2))
        #expect(LocalDate(year: 2026, month: 11, day: 2).days(since: beforeFall, in: pacific) == 2)
    }

    @Test("differences are signed and ordering is chronological")
    func differenceAndOrdering() {
        let a = LocalDate(year: 2026, month: 7, day: 1)
        let b = LocalDate(year: 2026, month: 7, day: 15)
        #expect(b.days(since: a, in: pacific) == 14)
        #expect(a.days(since: b, in: pacific) == -14)
        #expect(a.days(since: a, in: pacific) == 0)
        #expect(a < b)
        #expect(LocalDate(year: 2025, month: 12, day: 31) < LocalDate(year: 2026, month: 1, day: 1))
    }

    @Test("a late-night and an early-morning instant are different local days")
    func lateNightIsNotNextMorning() {
        let elevenPM = pacific.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 23))!
        let oneAM = pacific.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 1))!
        #expect(LocalDate(elevenPM, in: pacific) == LocalDate(year: 2026, month: 7, day: 29))
        #expect(LocalDate(oneAM, in: pacific) == LocalDate(year: 2026, month: 7, day: 30))
    }

    @Test("the same instant is a different local day in different time zones")
    func timeZoneDependence() {
        // 5pm in California is already the next morning in Tokyo (UTC+9 vs UTC-7).
        let instant = pacific.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 17))!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(LocalDate(instant, in: pacific) == LocalDate(year: 2026, month: 7, day: 29))
        #expect(LocalDate(instant, in: tokyo) == LocalDate(year: 2026, month: 7, day: 30))
    }
}
