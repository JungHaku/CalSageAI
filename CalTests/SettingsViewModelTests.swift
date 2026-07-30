import CalData
import CalKit
import Foundation
import Testing

@testable import Cal

/// Isolates the settings logic from SwiftUI. When the toggle looked broken, this
/// is what distinguished "the model is wrong" from "the view isn't observing".
@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    private func makeModel(
        status: ReminderAuthorization = .notDetermined
    ) -> (SettingsViewModel, MockReminderScheduler) {
        let reminders = MockReminderScheduler(status: status)
        let model = SettingsViewModel(
            profiles: InMemoryProfileStore(),
            reminders: reminders,
            sync: NoOpSyncEngine { 0 },
            dates: FixedDateProvider(day: LocalDate(iso: "2026-07-30")!)
        )
        return (model, reminders)
    }

    @Test("enabling asks for authorization and turns the reminder on")
    func enabling() async {
        let (model, reminders) = makeModel()
        await model.load()
        #expect(model.reminder.isEnabled == false)

        await model.setEnabled(true)

        #expect(await reminders.requestCount == 1, "permission should be asked at opt-in")
        #expect(model.reminder.isEnabled, "the schedule should be on after enabling")
        #expect(await reminders.applied.last?.isEnabled == true, "it should have been scheduled")
    }

    @Test("a denied user leaves the toggle off rather than showing it on for nothing")
    func denied() async {
        let (model, reminders) = makeModel(status: .denied)
        await model.load()

        await model.setEnabled(true)

        #expect(!model.reminder.isEnabled)
        #expect(model.isDenied)
        #expect(await reminders.applied.isEmpty, "nothing should be scheduled when denied")
    }

    @Test("disabling clears the scheduled reminder")
    func disabling() async {
        let (model, reminders) = makeModel(status: .authorized)
        await model.load()
        await model.setEnabled(true)
        await model.setEnabled(false)

        #expect(!model.reminder.isEnabled)
        #expect(await reminders.applied.last?.isEnabled == false)
    }

    @Test("changing the time keeps the enabled state and reschedules")
    func changingTime() async {
        let (model, reminders) = makeModel(status: .authorized)
        await model.load()
        await model.setEnabled(true)

        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 30
        components.hour = 7; components.minute = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        await model.setTime(calendar.date(from: components)!)

        #expect(model.reminder.hour == 7)
        #expect(model.reminder.minute == 15)
        #expect(model.reminder.isEnabled, "changing the time must not switch it off")
        #expect(await reminders.applied.last?.hour == 7)
    }

    // Apple's docs don't settle whether a repeating calendar trigger floats with
    // local time or pins to the scheduling zone, and DST is undocumented — so we
    // re-apply on foreground rather than depend on the answer.
    @Test("re-applying reschedules when enabled and is a no-op when not")
    func reapply() async {
        let (model, reminders) = makeModel(status: .authorized)
        await model.load()

        await model.reapplySchedule()
        #expect(await reminders.applied.isEmpty, "nothing to re-apply while disabled")

        await model.setEnabled(true)
        let afterEnable = await reminders.applied.count
        await model.reapplySchedule()
        #expect(await reminders.applied.count == afterEnable + 1)
    }

    @Test("the profile survives a reload, so the setting is persistent")
    func persists() async {
        let profiles = InMemoryProfileStore()
        let model = SettingsViewModel(
            profiles: profiles,
            reminders: MockReminderScheduler(status: .authorized),
            sync: NoOpSyncEngine { 0 },
            dates: FixedDateProvider(day: LocalDate(iso: "2026-07-30")!)
        )
        await model.load()
        await model.setEnabled(true)

        let reloaded = SettingsViewModel(
            profiles: profiles,
            reminders: MockReminderScheduler(status: .authorized),
            sync: NoOpSyncEngine { 0 },
            dates: FixedDateProvider(day: LocalDate(iso: "2026-07-30")!)
        )
        await reloaded.load()
        #expect(reloaded.reminder.isEnabled)
    }
}
