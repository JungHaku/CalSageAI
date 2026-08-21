import CalData
import CalDesign
import CalKit
import CalStore
import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @State private var moderation = ModerationStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SettingsViewModel?

    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportFailed = false
    @State private var confirmingDelete = false
    @State private var ambassadorEmail = ""
    @State private var ambassadorNotice: String?
    @State private var ambassadorWorking = false
    @State private var ambassadorSignedUp = false
    @State private var deleteFailed = false

    var body: some View {
        Form {
            if let model {
                profileSection
                subscriptionSection
                reminderSection(model)
                dataSection(model)
                aboutSection
                ambassadorSection
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
            if ambassadorEmail.isEmpty {
                ambassadorEmail = await container.auth.credentials()?.email ?? ""
            }
            if let existing = await container.ambassadorSignup.currentEmail() {
                ambassadorEmail = existing
                ambassadorSignedUp = true
            }
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
                This erases every practice session, journal entry, and your profile \
                from this phone. It does not delete your sign-in. Export first if \
                you want to keep a copy. This can't be undone.
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
            NavigationLink("Account and memory") { SignInView() }
                .accessibilityIdentifier("open-account")
        }
    }

    // MARK: Subscription

    /// Status, a way in, and a way out.
    ///
    /// The cancel path is a link to the App Store's own subscription screen,
    /// because that is where cancellation actually happens — but do not read that
    /// as Apple owning the obligation. On the US storefront Apple is appointed our
    /// **agent**, not the merchant of record (Schedule 2, Exhibit A §1), and we are
    /// the principal, so California's Automatic Renewal Law binds *us*.
    ///
    /// This placement is expressly contemplated rather than merely tolerated:
    /// §17602(d)(1)(A) requires "a prominently located direct link or button which
    /// may be located within either a customer account or profile, **or within
    /// either device or user settings**." Linking out to iOS Settings is the
    /// statute's own example, not a workaround. `docs/LAUNCH-REQUIREMENTS.md`
    /// §18.7 carries the obligations this does *not* discharge.
    @ViewBuilder
    private var subscriptionSection: some View {
        Section {
            if container.premium.entitlement == .plus {
                LabeledContent("C.A.L+ Coherence", value: "Subscribed")
                    .accessibilityIdentifier("subscription-status")
                Link("Manage or cancel", destination: Self.manageSubscriptions)
                    .accessibilityIdentifier("manage-subscription")
            } else {
                NavigationLink("C.A.L+ Coherence") { PaywallView() }
                    .accessibilityIdentifier("open-paywall")
                Button("Restore purchases") {
                    Task { await container.premium.restore() }
                }
                .accessibilityIdentifier("settings-restore")
            }
        } header: {
            Text("Subscription")
        }
    }

    /// The system's own subscription management screen.
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!

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
                Text("Notifications are turned off for C.A.L in iOS Settings.")
            } else {
                Text("One gentle nudge a day. No streak warnings, no badges.")
            }
        }
    }

    // MARK: Data

    private func dataSection(_ model: SettingsViewModel) -> some View {
        Section {
            // Deliberately says "not yet backed up", not "stored on this device".
            // The old wording was true when nothing synced and is misleading now:
            // a signed-in person needs to know which rows are *only* here.
            LabeledContent(
                "Not yet backed up",
                value: model.pendingSync == 1 ? "1 item" : "\(model.pendingSync) items"
            )
            .accessibilityIdentifier("pending-sync")

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
            Text(
                """
                Practice sessions and journal entries live on this phone. Signing \
                in lets Cal back them up to your account. Deleting the app deletes \
                the local copy. A copy may still exist in an iPhone backup you've \
                already made.
                """
            )
        }
    }

    /// Two sections, so this needs the builder.
    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("C.A.L", value: "MVP")
            NavigationLink("Emergency help") { EmergencyView() }
        }

        // Guideline 1.2 asks for published contact information and a way to
        // block. Both live here rather than only inside the chat, because
        // someone who has already blocked Cal cannot reach a control that only
        // exists on the chat screen.
        Section {
            Toggle(
                "Block C.A.L",
                isOn: Binding(
                    get: { moderation.isBlocked },
                    set: { moderation.setBlocked($0) }
                )
            )
            .accessibilityIdentifier("settings-block-cal")

            if let url = Support.mailtoURL {
                Link("Contact support", destination: url)
                    .accessibilityIdentifier("settings-contact")
            } else {
                LabeledContent("Contact support", value: Support.contactEmail)
            }
        } header: {
            Text("Chat and safety")
        } footer: {
            Text(
                "Blocking stops C.A.L replying. You can report any reply from the "
                + "chat itself. We aim to respond to reports within two business days."
            )
        }
    }

    // MARK: Ambassador

    private var ambassadorSection: some View {
        Section {
            TextField("Email", text: $ambassadorEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("ambassador-email")

            Button {
                Task { await submitAmbassador() }
            } label: {
                if ambassadorWorking {
                    ProgressView()
                } else {
                    Text(ambassadorSignedUp ? "Update signup" : "Sign up")
                }
            }
            .disabled(ambassadorWorking || ambassadorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("ambassador-submit")

            if let ambassadorNotice {
                Text(ambassadorNotice)
                    .font(.footnote)
                    .foregroundStyle(Surface.inkSecondary)
                    .accessibilityIdentifier("ambassador-notice")
            }
        } header: {
            Text("Ambassador program")
        } footer: {
            Text(
                "Leave your email if you want to help get Cal into more students' hands. "
                    + "We'll only use it to reach you about the program."
            )
        }
    }

    private func submitAmbassador() async {
        ambassadorWorking = true
        ambassadorNotice = nil
        defer { ambassadorWorking = false }
        do {
            try await container.ambassadorSignup.submit(email: ambassadorEmail)
            ambassadorSignedUp = true
            ambassadorEmail = RestAmbassadorSignup.normalize(ambassadorEmail)
            ambassadorNotice = "You're on the list."
        } catch AmbassadorSignupError.invalidEmail {
            ambassadorNotice = "Enter a valid email address."
        } catch AmbassadorSignupError.unsigned {
            ambassadorNotice = "Sign in again to join the program."
        } catch {
            ambassadorNotice = "Couldn't save that just now. Try again."
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
            // an untitled blob. A URL also skips the `preview:` argument a custom
            // `Transferable` requires, and the reports of one breaking "Save to
            // Files" (FB forums 719429) are old enough that they may well be fixed
            // — the filename alone is reason enough not to find out.
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
