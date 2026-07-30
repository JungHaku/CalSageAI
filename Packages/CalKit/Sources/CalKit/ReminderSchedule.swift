import Foundation

/// When the daily check-in reminder fires.
///
/// Pure and calendar-driven, so the interesting cases — a time that has already
/// passed today, DST transitions, the user changing time zone — are testable
/// without touching `UNUserNotificationCenter`.
public struct ReminderSchedule: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int

    public static let defaultHour = 9
    public static let defaultMinute = 0

    /// Off by default. A wellness app that starts sending notifications before the
    /// student has decided they want them is the kind of thing that gets deleted
    /// on day two — and permission is worth asking for only once there's something
    /// to remind them about.
    public static let `default` = ReminderSchedule(
        isEnabled: false, hour: defaultHour, minute: defaultMinute
    )

    public init(isEnabled: Bool, hour: Int, minute: Int) {
        self.isEnabled = isEnabled
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    /// The next moment this schedule should fire, strictly after `date`.
    ///
    /// Returns `nil` when disabled, so callers can't accidentally schedule an
    /// inactive reminder.
    public func nextOccurrence(after date: Date, in calendar: Calendar) -> Date? {
        guard isEnabled else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        // `.nextTime` with `.forward` handles the two cases that matter: the time
        // has already passed today (roll to tomorrow), and the time doesn't exist
        // today because of a spring-forward transition (roll to the next valid
        // instant rather than silently never firing).
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }

    /// Display form, in the user's locale.
    public func formatted(in calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return "\(hour):\(minute)" }
        return date.formatted(.dateTime.hour().minute().locale(locale))
    }
}
