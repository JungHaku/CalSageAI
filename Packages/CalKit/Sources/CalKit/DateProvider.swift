import Foundation

/// Injectable source of "now" and of the user's calendar.
///
/// Every streak, `local_date`, and weekly-review boundary in this app is date
/// math, and date math cannot be tested against the real calendar — you can't
/// wait for a DST transition in CI. So nothing in CalKit reads `Date()`
/// directly; it takes a `DateProvider`.
///
/// Named `DateProvider` rather than `Clock` to avoid colliding with the Swift
/// standard library's `Clock` protocol.
public protocol DateProvider: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

extension DateProvider {
    /// The user's current calendar day.
    public var today: LocalDate { LocalDate(now, in: calendar) }
}

/// Production implementation. Defaults to the device's time zone.
public struct SystemDateProvider: DateProvider {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.timeZone = timeZone
    }

    public var now: Date { Date() }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
}

/// Test/preview implementation: a frozen instant in an explicit time zone.
public struct FixedDateProvider: DateProvider {
    public let now: Date
    public let timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles")!) {
        self.now = now
        self.timeZone = timeZone
    }

    /// Convenience: freeze at noon on a given local day.
    public init(day: LocalDate, timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles")!) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        self.now = c.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
            ?? Date(timeIntervalSince1970: 0)
        self.timeZone = timeZone
    }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
}
