import CalData
import CalKit
import Foundation
import Observation

/// Owns the settings screen's state.
///
/// A reference type rather than `@State` on the view: the toggle's work is async
/// (authorization, then a store write, then rescheduling), and driving that from
/// a closure that captured a copy of a `View` struct is how you get a control
/// that visibly does nothing. Every other screen in the app already uses this
/// shape — `CheckInViewModel` — so this is consistency, not a workaround.
@Observable
final class SettingsViewModel {
    private(set) var profile: Profile?
    private(set) var authorization: ReminderAuthorization = .notDetermined
    private(set) var pendingSync = 0

    private let profiles: any ProfileStoring
    private let reminders: any ReminderScheduling
    private let sync: any SyncEngine
    private let dates: any DateProvider

    init(
        profiles: any ProfileStoring,
        reminders: any ReminderScheduling,
        sync: any SyncEngine,
        dates: any DateProvider
    ) {
        self.profiles = profiles
        self.reminders = reminders
        self.sync = sync
        self.dates = dates
    }

    var reminder: ReminderSchedule { profile?.reminder ?? .default }
    /// The toggle can't fix a system-level denial — only Settings can.
    var isDenied: Bool { authorization == .denied }

    func load() async {
        profile = (try? await profiles.current()) ?? Profile()
        authorization = await reminders.authorization()
        pendingSync = (try? await sync.pendingCount()) ?? 0
    }

    func setEnabled(_ enabled: Bool) async {
        // Falls back to a fresh profile rather than returning: a control that
        // silently does nothing is worse than one that creates the record it
        // needs. (The view also waits for `load()` before rendering, so this is
        // belt and braces.)
        var updated = profile ?? Profile()

        if enabled {
            // Asked here — the moment the student opts in — rather than on first
            // launch. Apple's own guidance is to request at a contextually
            // relevant moment, and the prompt only ever appears once per install,
            // so spending it on a cold launch wastes it.
            authorization = await reminders.requestAuthorization()
            guard authorization.allowsScheduling else {
                // Leave the toggle off rather than showing it on while nothing
                // would ever fire.
                return
            }
        }

        updated.reminder.isEnabled = enabled
        await persist(updated)
    }

    func setTime(_ date: Date) async {
        var updated = profile ?? Profile()
        let components = dates.calendar.dateComponents([.hour, .minute], from: date)
        updated.reminder = ReminderSchedule(
            isEnabled: updated.reminder.isEnabled,
            hour: components.hour ?? ReminderSchedule.defaultHour,
            minute: components.minute ?? ReminderSchedule.defaultMinute
        )
        await persist(updated)
    }

    /// Re-applies the current schedule.
    ///
    /// Called on foreground and on time-zone change. Apple's documentation does
    /// not settle whether a repeating calendar trigger floats with local time or
    /// pins to the zone it was scheduled in — an Apple engineer says one thing on
    /// the forums and a developer's reproduction says the other — and DST
    /// behaviour is undocumented entirely. Re-applying is cheap and idempotent,
    /// so it costs nothing to stop depending on the answer.
    func reapplySchedule() async {
        guard let profile, profile.reminder.isEnabled else { return }
        await reminders.apply(profile.reminder)
    }

    /// The time picker needs a `Date`; the schedule stores hour and minute.
    func timeAsDate() -> Date {
        var components = dates.calendar.dateComponents([.year, .month, .day], from: dates.now)
        components.hour = reminder.hour
        components.minute = reminder.minute
        return dates.calendar.date(from: components) ?? dates.now
    }

    private func persist(_ updated: Profile) async {
        profile = updated
        try? await profiles.save(updated)
        await reminders.apply(updated.reminder)
    }
}
