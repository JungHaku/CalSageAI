import Foundation

/// A calendar day with no time and no time zone — the Swift mirror of the
/// `local_date date` columns in Postgres (ARCHITECTURE.md §5.2).
///
/// Streaks, "today's check-in", and weekly reviews are all reasoning about *the
/// user's day*, not about instants. Modelling that as a `Date` invites a whole
/// family of bugs: a check-in at 11pm PDT and one at 1am PDT the next morning
/// are 2 hours apart but are different days, and a `Date`-based streak breaks
/// across a DST transition. Keeping days as (year, month, day) makes those
/// bugs unrepresentable.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The calendar day that `instant` falls on, in `calendar`'s time zone.
    public init(_ instant: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        self.year = c.year ?? 1
        self.month = c.month ?? 1
        self.day = c.day ?? 1
    }

    // MARK: Wire format

    /// ISO-8601 calendar date, e.g. `2026-07-29` — what Postgres `date` expects.
    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { iso }

    // MARK: Day arithmetic

    /// Anchored at noon on purpose. Midnight is the one instant a DST
    /// transition can erase or duplicate, so anchoring day arithmetic there can
    /// shift a date by one. Noon is never ambiguous for any real-world zone.
    private func noon(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    public func adding(days: Int, in calendar: Calendar) -> LocalDate {
        guard let anchor = noon(in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: anchor)
        else { return self }
        return LocalDate(moved, in: calendar)
    }

    /// Whole calendar days from `other` to `self`. Positive when `self` is later.
    public func days(since other: LocalDate, in calendar: Calendar) -> Int {
        guard let a = other.noon(in: calendar), let b = noon(in: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: Comparable

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
