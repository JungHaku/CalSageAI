import CalData
import CalKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SettingsViewModel?

    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportFailed = false
    @State private var confirmingDelete = false
    @State private var deleteFailed = false

    var body: some View {
        Form {
            if let model {
                profileSection
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
        .sheet(
            isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { clearExport() } })
        ) {
            if let exportURL {
                ShareSheet(url: exportURL) { clearExport() }
            }
        }
        // Destructive and genuinely irreversible, so it asks — and the message
        // names exactly what goes, rather than a vague "are you sure?".
        .confirmationDialog(
            "Delete everything?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            // Identified explicitly: the dialog's title, its confirm button, and
            // the settings row all read "Delete everything", so a label query
            // matches three things.
            Button("Delete everything", role: .destructive) {
                Task { await deleteEverything() }
            }
            .accessibilityIdentifier("confirm-delete")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cancel-delete")
        } message: {
            Text(
                """
                This erases every check-in, practice session, and your profile \
                from this phone. There's no account and no copy on our side, so it \
                can't be undone. Export first if you want to keep a copy.
                """
            )
        }
        .alert("Couldn't export", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong building the file. Your data is unchanged.")
        }
        .alert("Couldn't delete", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong. Your data is unchanged.")
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-apply on foreground: a repeating calendar trigger's behaviour
            // across time-zone changes and DST is not settled by Apple's docs, so
            // we stop relying on it (see SettingsViewModel.reapplySchedule).
            if phase == .active { Task { await model?.reapplySchedule() } }
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            NavigationLink("Profile") { ProfileView() }
                .accessibilityIdentifier("open-profile")
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

            Button {
                Task { await prepareExport() }
            } label: {
                if isExporting {
                    ProgressView()
                } else {
                    Label("Export my data", systemImage: "square.and.arrow.up")
                }
            }
            .accessibilityIdentifier("export-data")

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete everything", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-data")
        } header: {
            Text("Your data")
        } footer: {
            // Honest about what the MVP is: no account, no server, so the phone is
            // the only copy (ARCHITECTURE.md §1, §14). The backup caveat matters —
            // an in-app delete cannot reach a device backup taken yesterday, and
            // implying otherwise would be the dishonest version.
            Text(
                """
                Everything stays on this phone — there's no account and nothing is \
                uploaded. Deleting the app deletes your history too. A copy may \
                still exist in an iPhone backup you've already made.
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

    // MARK: Export and delete

    private func prepareExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let archive = try await container.personalData.export(
                today: container.dates.today, calendar: container.dates.calendar
            )
            let data = try archive.jsonData()
            // A real file rather than raw `Data`, so the share sheet carries a
            // real filename — "cal-coherence-export-2026-07-30.json" rather than
            // an untitled blob. Sharing a file URL also avoids a long-standing bug
            // where a custom `Transferable` breaks "Save to Files".
            //
            // In its own UUID subdirectory: two exports on the same day would
            // otherwise collide on the filename, and overwriting a file the share
            // sheet is still reading fails silently.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent(archive.suggestedFilename(on: container.dates.today))
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            exportFailed = true
        }
    }

    /// Removes the temp file only once the share sheet is finished with it.
    /// Deleting earlier can leave a share extension holding a URL that no longer
    /// resolves, which fails silently and looks like an empty file.
    /// Removes the whole export directory once the share sheet is finished with
    /// it. `ShareLink` would be tidier than the wrapper above but has no
    /// completion handler in any initialiser, so there'd be no moment at which
    /// cleanup is safe — deleting earlier leaves a share extension holding a URL
    /// that no longer resolves, which fails silently and looks like an empty file.
    private func clearExport() {
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
        }
        exportURL = nil
    }

    private func deleteEverything() async {
        do {
            try await container.personalData.deleteEverything()
            // Reload so the "stored on this device" count reflects reality
            // immediately rather than after a relaunch.
            await model?.load()
        } catch {
            deleteFailed = true
        }
    }
}

#Preview("settings") {
    NavigationStack { SettingsView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}

/// Wraps `UIActivityViewController`.
///
/// `ShareLink` would be tidier, but it wants its payload up front, and this
/// archive is produced asynchronously — building it eagerly on every render of
/// the settings screen would encode the whole store for a button nobody tapped.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
