import CalKit
import EventKit
import Foundation

/// One entry on today's schedule.
nonisolated struct PlannerEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarName: String

    var timeLabel: String {
        isAllDay
            ? "All day"
            : "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

nonisolated enum CalendarAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case granted

    var canRead: Bool { self == .granted }
}

/// The calendar seam.
///
/// A protocol for the same reason as the reminder scheduler: a system permission
/// alert appearing mid-run blocks a UI test with no useful failure.
nonisolated protocol CalendarAccess: Sendable {
    func authorization() async -> CalendarAuthorization
    @discardableResult
    func requestAccess() async -> CalendarAuthorization
    func events(on day: LocalDate, calendar: Calendar) async -> [PlannerEvent]
}

/// Reads the student's existing iOS calendars.
///
/// ⚠️ **There is no read-only tier.** Apple: *"Your app can't request read-only
/// access to either events or reminders. To read events... your app needs full
/// access."* So a feature that only ever displays today's schedule still shows the
/// full read-**and-write** permission prompt. That's worth knowing before pitching
/// it as harmless — and it's why the prompt is deferred until the student taps
/// Connect rather than fired on first launch.
nonisolated struct EventKitCalendarAccess: CalendarAccess {
    private var store: EKEventStore { EKEventStore() }

    func authorization() async -> CalendarAuthorization {
        // `.authorized` is a deprecated alias for `.fullAccess` with the same raw
        // value, which is why stale `== .authorized` checks silently keep working
        // and hide the migration. Switch on the real cases.
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .denied  // write-only cannot read events at all
        default: .notDetermined
        }
    }

    @discardableResult
    func requestAccess() async -> CalendarAuthorization {
        // `requestAccess(to:)` is deprecated AND functionally dead on iOS 17+ — it
        // never prompts and immediately errors. This is the current call.
        _ = try? await store.requestFullAccessToEvents()
        return await authorization()
    }

    func events(on day: LocalDate, calendar: Calendar) async -> [PlannerEvent] {
        guard await authorization().canRead else { return [] }

        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            // `events(matching:)` is synchronous and blocking — Apple says to run
            // it off the calling thread. On an account with several CalDAV or
            // Exchange calendars it can take hundreds of milliseconds, so it must
            // not run on the main actor.
            var components = DateComponents()
            components.year = day.year
            components.month = day.month
            components.day = day.day
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { return [] }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate)
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .map {
                    PlannerEvent(
                        id: $0.eventIdentifier ?? UUID().uuidString,
                        title: $0.title ?? "Untitled",
                        start: $0.startDate ?? start,
                        end: $0.endDate ?? start,
                        isAllDay: $0.isAllDay,
                        calendarName: $0.calendar?.title ?? ""
                    )
                }
        }.value
    }
}

/// Never touches the system. Injected under test.
actor MockCalendarAccess: CalendarAccess {
    private var status: CalendarAuthorization
    private let seeded: [PlannerEvent]
    private(set) var requestCount = 0

    init(status: CalendarAuthorization = .notDetermined, events: [PlannerEvent] = []) {
        self.status = status
        self.seeded = events
    }

    func authorization() async -> CalendarAuthorization { status }

    @discardableResult
    func requestAccess() async -> CalendarAuthorization {
        requestCount += 1
        if status == .notDetermined { status = .granted }
        return status
    }

    func events(on day: LocalDate, calendar: Calendar) async -> [PlannerEvent] {
        status.canRead ? seeded : []
    }
}
