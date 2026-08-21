import CalKit
import Foundation
import UserNotifications

nonisolated enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional

    var allowsScheduling: Bool { self == .authorized || self == .provisional }
}

/// The notification seam.
///
/// A protocol because UI tests must never reach the real notification centre — a
/// system permission alert appearing mid-run blocks the test with no useful
/// failure. `MockReminderScheduler` is injected whenever the app launches under
/// test (ARCHITECTURE.md §11).
nonisolated protocol ReminderScheduling: Sendable {
    func authorization() async -> ReminderAuthorization
    @discardableResult
    func requestAuthorization() async -> ReminderAuthorization
    /// Applies the schedule: clears any existing reminder, then re-adds it if
    /// enabled. Idempotent, so calling it repeatedly can't stack duplicates.
    func apply(_ schedule: ReminderSchedule) async
    func pendingIdentifiers() async -> [String]
}

nonisolated struct NotificationReminderScheduler: ReminderScheduling {
    /// One stable identifier, so re-applying replaces rather than accumulates.
    /// iOS caps pending requests (64), and a scheduler that added a new one on
    /// every settings change would quietly exhaust it.
    static let identifier = "cal.daily-checkin"

    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> ReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: .authorized
        case .provisional: .provisional
        case .denied: .denied
        default: .notDetermined
        }
    }

    @discardableResult
    func requestAuthorization() async -> ReminderAuthorization {
        // `.badge` is deliberately not requested: an unread count on a wellness
        // app is a nagging mechanic, and we have nothing meaningful to count.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func apply(_ schedule: ReminderSchedule) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard schedule.isEnabled, await authorization().allowsScheduling else { return }

        let content = UNMutableNotificationContent()
        content.title = "A moment with C.A.L"
        content.body = "How do you feel right here in the moment?"
        content.sound = .default
        // Default (.active) interruption level on purpose. `.timeSensitive` would
        // break through Focus and needs an entitlement; a wellness nudge is not
        // time-sensitive and claiming otherwise is the kind of thing review
        // notices.

        var components = DateComponents()
        components.hour = schedule.hour
        components.minute = schedule.minute

        try? await center.add(
            UNNotificationRequest(
                identifier: Self.identifier,
                content: content,
                // A repeating calendar trigger re-evaluates against the device's
                // current calendar each day, so it follows the user across time
                // zones and DST without rescheduling.
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
        )
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

/// Records what would have been scheduled, and never touches the system.
actor MockReminderScheduler: ReminderScheduling {
    private var status: ReminderAuthorization
    private(set) var applied: [ReminderSchedule] = []
    private(set) var requestCount = 0

    init(status: ReminderAuthorization = .notDetermined) {
        self.status = status
    }

    func authorization() async -> ReminderAuthorization { status }

    @discardableResult
    func requestAuthorization() async -> ReminderAuthorization {
        requestCount += 1
        if status == .notDetermined { status = .authorized }
        return status
    }

    func apply(_ schedule: ReminderSchedule) async {
        applied.append(schedule)
    }

    func pendingIdentifiers() async -> [String] {
        (applied.last?.isEnabled ?? false) ? [NotificationReminderScheduler.identifier] : []
    }

    func setStatus(_ new: ReminderAuthorization) { status = new }
}
