import CalData
import CalKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SettingsViewModel?

    var body: some View {
        Form {
            if let model {
                reminderSection(model)
                dataSection(model)
                aboutSection
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Settings")
        .task {
            guard model == nil else { return }
            let created = SettingsViewModel(
                profiles: container.profiles,
                reminders: container.reminders,
                sync: container.sync,
                dates: container.dates
            )
            // Loaded BEFORE being published. Assigning first renders the form
            // against a nil profile, and a tap in that window hits the guard in
            // `setEnabled` and silently does nothing — which is exactly how the
            // toggle looked broken.
            await created.load()
            model = created
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-apply on foreground: a repeating calendar trigger's behaviour
            // across time-zone changes and DST is not settled by Apple's docs, so
            // we stop relying on it (see SettingsViewModel.reapplySchedule).
            if phase == .active { Task { await model?.reapplySchedule() } }
        }
    }

    // MARK: Reminder

    private func reminderSection(_ model: SettingsViewModel) -> some View {
        Section {
            Toggle(
                "Daily reminder",
                isOn: Binding(
                    get: { model.reminder.isEnabled },
                    set: { enabled in Task { await model.setEnabled(enabled) } }
                )
            )
            .accessibilityIdentifier("reminder-toggle")

            if model.reminder.isEnabled {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { model.timeAsDate() },
                        set: { newDate in Task { await model.setTime(newDate) } }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("reminder-time")
            }
        } header: {
            Text("Reminder")
        } footer: {
            if model.isDenied {
                Text("Notifications are turned off for Cal in iOS Settings.")
            } else {
                Text("One gentle nudge a day. No streak warnings, no badges.")
            }
        }
    }

    // MARK: Data

    private func dataSection(_ model: SettingsViewModel) -> some View {
        Section {
            LabeledContent("Stored on this device", value: "\(model.pendingSync) check-ins")
        } header: {
            Text("Your data")
        } footer: {
            // Honest about what the MVP is: no account, no server, so the phone is
            // the only copy (ARCHITECTURE.md §1, §14).
            Text(
                """
                Everything stays on this phone. There's no account and nothing is \
                uploaded — which also means deleting the app deletes your history.
                """
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Cal", value: "MVP")
            NavigationLink("Emergency help") { EmergencyView() }
        }
    }
}

#Preview("settings") {
    NavigationStack { SettingsView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
