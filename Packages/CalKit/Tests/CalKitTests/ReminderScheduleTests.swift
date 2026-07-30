import Foundation
import Testing

@testable import CalKit

@Suite("ReminderSchedule")
struct ReminderScheduleTests {
    let pacific = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        pacific.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("the default is off — we don't notify before the student opts in")
    func defaultIsOff() {
        #expect(!ReminderSchedule.default.isEnabled)
        #expect(ReminderSchedule.default.hour == 9)
    }

    @Test("a disabled schedule has no next occurrence, so it can't be scheduled")
    func disabledHasNoOccurrence() {
        let schedule = ReminderSchedule(isEnabled: false, hour: 9, minute: 0)
        #expect(schedule.nextOccurrence(after: date(2026, 7, 30, 8), in: pacific) == nil)
    }

    @Test("before the time, it fires today")
    func firesToday() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 9, minute: 0)
        let next = schedule.nextOccurrence(after: date(2026, 7, 30, 7, 30), in: pacific)
        #expect(next == date(2026, 7, 30, 9, 0))
    }

    @Test("after the time, it rolls to tomorrow rather than firing immediately")
    func rollsToTomorrow() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 9, minute: 0)
        let next = schedule.nextOccurrence(after: date(2026, 7, 30, 11), in: pacific)
        #expect(next == date(2026, 7, 31, 9, 0))
    }

    @Test("exactly at the time, it rolls forward — strictly after, never now")
    func strictlyAfter() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 9, minute: 0)
        let next = schedule.nextOccurrence(after: date(2026, 7, 30, 9, 0), in: pacific)
        #expect(next == date(2026, 7, 31, 9, 0))
    }

    // US Pacific springs forward at 2am on 2026-03-08, so 2:30am doesn't exist
    // that day. A naive implementation schedules a time that never arrives and the
    // reminder silently stops — the failure mode nobody notices until a user says
    // "it stopped reminding me".
    @Test("a time that doesn't exist on a spring-forward day still fires")
    func springForwardGap() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 2, minute: 30)
        let next = schedule.nextOccurrence(after: date(2026, 3, 8, 0, 30), in: pacific)
        #expect(next != nil, "a nonexistent local time must still resolve to a real instant")
        if let next {
            #expect(next > date(2026, 3, 8, 0, 30))
            // Same calendar day, not skipped to the 9th.
            #expect(LocalDate(next, in: pacific) == LocalDate(year: 2026, month: 3, day: 8))
        }
    }

    // Fall-back duplicates 1:00–2:00am on 2026-11-01. It must fire once, not twice
    // and not never.
    @Test("a duplicated hour on a fall-back day resolves to a single instant")
    func fallBackDuplicate() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 1, minute: 30)
        let next = schedule.nextOccurrence(after: date(2026, 10, 31, 12), in: pacific)
        #expect(next != nil)
        if let next {
            #expect(LocalDate(next, in: pacific) == LocalDate(year: 2026, month: 11, day: 1))
        }
    }

    @Test("the schedule follows the calendar's time zone, not a fixed offset")
    func followsTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let schedule = ReminderSchedule(isEnabled: true, hour: 9, minute: 0)

        let pacificNext = schedule.nextOccurrence(after: date(2026, 7, 30, 7), in: pacific)
        let tokyoNext = schedule.nextOccurrence(after: date(2026, 7, 30, 7), in: tokyo)
        #expect(pacificNext != tokyoNext, "9am should mean 9am locally in each zone")
    }

    @Test("out-of-range times are clamped rather than producing an unschedulable reminder")
    func clamping() {
        #expect(ReminderSchedule(isEnabled: true, hour: 99, minute: 99).hour == 23)
        #expect(ReminderSchedule(isEnabled: true, hour: 99, minute: 99).minute == 59)
        #expect(ReminderSchedule(isEnabled: true, hour: -4, minute: -1).hour == 0)
        #expect(ReminderSchedule(isEnabled: true, hour: -4, minute: -1).minute == 0)
    }

    @Test("it round-trips through Codable, since it lives in the profile")
    func codable() throws {
        let schedule = ReminderSchedule(isEnabled: true, hour: 7, minute: 45)
        let decoded = try JSONDecoder().decode(
            ReminderSchedule.self, from: try JSONEncoder().encode(schedule)
        )
        #expect(decoded == schedule)
    }

    @Test("formatting is locale-aware and non-empty")
    func formatting() {
        let schedule = ReminderSchedule(isEnabled: true, hour: 9, minute: 5)
        #expect(!schedule.formatted(in: pacific, locale: Locale(identifier: "en_US")).isEmpty)
        #expect(!schedule.formatted(in: pacific, locale: Locale(identifier: "en_GB")).isEmpty)
    }
}
