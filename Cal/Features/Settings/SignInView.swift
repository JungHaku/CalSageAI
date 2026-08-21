import CalData
import CalDesign
import CalKit
import SwiftUI

/// Sign in, then — separately — decide whether Cal may remember.
///
/// Two steps, and the separation is legal rather than aesthetic. MHMDA requires
/// opt-in that cannot come from accepting terms; CMIA §56.06(b) treats this app
/// as a provider of health care. Signing in creates an account. It does not, on
/// its own, send one word of anyone's conversation anywhere — that needs the
/// second yes, and the second yes defaults to no.
///
/// ⚠️ The consent copy is engineering's best effort, not legal wording. §18.2
/// wants a standalone CMIA authorization in 14-point type with its own
/// signature, drafted by counsel. What is here is the right *shape* for it.
struct SignInView: View {
    @Environment(AppContainer.self) private var container

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var signedInEmail: String?
    @State private var pendingSync = 0
    @State private var lastSync: SyncOutcome?
    /// Tracked apart from `lastSync` because `try?` renders a refusal and a
    /// never-pressed button identically.
    @State private var syncFailed = false
    @State private var isSyncing = false

    // No NavigationStack of its own. This is pushed from Settings, which already
    // provides one, and nesting a second stack inside a pushed view makes the
    // outer stack pop straight back to the root — the row simply appeared not to
    // work. Found by tapping it, not by reading it.
    var body: some View {
        Form {
            if let signedInEmail {
                signedInSection(signedInEmail)
                consentSection
            } else {
                explanation
                credentialsSection
            }
        }
        .navigationTitle(signedInEmail == nil ? "Sign in" : "Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            signedInEmail = await container.auth.credentials()?.email
            pendingSync = (try? await container.sync.pendingCount()) ?? 0
        }
    }

    // MARK: Signed out

    private var explanation: some View {
        Section {
            Text(
                """
                An account is only needed so Cal can carry a conversation across \
                devices. Everything you have already done — practices, journal, \
                settings — is on this phone and stays there whether you sign in or not.
                """
            )
            .font(.footnote)
            .foregroundStyle(Surface.inkSecondary)
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("signin-email")

            SecureField("Password", text: $password)
                // `.newPassword` on the register path so the system offers a
                // strong one instead of trying to autofill an existing login.
                .textContentType(isRegistering ? .newPassword : .password)
                .accessibilityIdentifier("signin-password")

            Button(isRegistering ? "Create account" : "Sign in") {
                Task { await submit() }
            }
            .disabled(!canSubmit)
            .accessibilityIdentifier("signin-submit")

            Button(isRegistering ? "I already have an account" : "Create an account instead") {
                isRegistering.toggle()
                error = nil
            }
            .font(.footnote)
            .accessibilityIdentifier("signin-toggle-mode")
        } footer: {
            if let error {
                Text(error)
                    .foregroundStyle(CoherenceScale.textTint(for: .low))
                    .accessibilityIdentifier("signin-error")
            } else if isWorking {
                Text("Working…")
            }
        }
    }

    private var canSubmit: Bool {
        !isWorking
            && email.contains("@")
            && password.count >= 8
    }

    private func submit() async {
        isWorking = true
        error = nil
        defer { isWorking = false }

        do {
            let credentials = isRegistering
                ? try await container.auth.signUp(email: email, password: password)
                : try await container.auth.signIn(email: email, password: password)
            password = ""
            signedInEmail = credentials.email
            container.noteSignedIn()
        } catch let authError as AuthError {
            error = authError.userFacingMessage
        } catch is CancellationError {
            error = nil
        } catch let transport {
            // Named, because an unlabelled `catch` binds `error` and shadows the
            // `@State` of the same name — which compiles as a very confusing
            // type error rather than as the mistake it is.
            _ = transport
            error = "Couldn't reach the server. Check your connection and try again."
        }
    }

    // MARK: Signed in

    /// Two sections, so this needs the builder.
    @ViewBuilder
    private func signedInSection(_ address: String) -> some View {
        Section {
            LabeledContent("Signed in as", value: address)
            Button("Sign out", role: .destructive) {
                container.signOut()
                signedInEmail = nil
            }
            .accessibilityIdentifier("signin-signout")
        } footer: {
            Text("Signing out on this phone doesn't delete anything. Use Settings › Delete everything for that.")
        }

        // Backup lives here rather than in Settings, and that is a design call
        // rather than a tidy-up: it does nothing at all without an account, so
        // putting it beside sign-in is where someone would look for it.
        //
        // It also keeps Settings' destructive row where it was. Adding a row
        // above "Delete everything" pushed it below the fold, and a SwiftUI List
        // does not build off-screen rows — so the control that erases everything
        // stopped existing as far as the accessibility tree was concerned. A UI
        // test caught that; nothing on screen looked wrong.
        Section {
            LabeledContent(
                "Not yet backed up",
                value: pendingSync == 1 ? "1 item" : "\(pendingSync) items"
            )
            Button {
                Task { await backUpNow() }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Label(syncLabel, systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isSyncing)
            .accessibilityIdentifier("sync-now")
        } header: {
            Text("Backup")
        } footer: {
            Text("Your data is copied to your account so it survives losing this phone.")
        }
    }

    private var syncLabel: String {
        if syncFailed { return "Couldn't back up — try again" }
        switch lastSync {
        case .none: return "Back up now"
        case .notConfigured: return "Sign in to back up"
        case .offline: return "Offline — try again"
        case .synced(let pushed, let pulled):
            return pushed == 0 && pulled == 0
                ? "Up to date" : "Backed up \(pushed), received \(pulled)"
        }
    }

    private func backUpNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            lastSync = try await container.sync.sync()
            syncFailed = false
        } catch {
            lastSync = nil
            syncFailed = true
        }
        pendingSync = (try? await container.sync.pendingCount()) ?? pendingSync
    }

    /// The second yes — two explicit choices, not a switch.
    ///
    /// Replaced a `Toggle`, for two reasons. The weaker one is that the toggle
    /// did not respond to taps in the simulator while a `Button` in the same
    /// Form did, and a consent control that silently does nothing is the worst
    /// possible failure for this particular control.
    ///
    /// The stronger one is that a toggle is the wrong affordance here. MHMDA and
    /// CMIA both want a *distinct affirmative act*, and a switch you might have
    /// brushed past is not obviously one. Two labelled choices, where the current
    /// answer is visibly ticked and declining has its own words, is what "the
    /// person chose this" looks like. `MemoryConsentCopy` already carried both
    /// strings; only one of them was being used.
    private var consentSection: some View {
        Section {
            Text(MemoryConsentCopy.body)
                .font(.subheadline)

            Text(MemoryConsentCopy.sharingNote)
                .font(.footnote)
                .foregroundStyle(Surface.inkSecondary)

            choice(MemoryConsentCopy.acceptTitle, isSelected: isRemembering, grants: true)
                .accessibilityIdentifier("memory-consent-accept")
            choice(MemoryConsentCopy.declineTitle, isSelected: !isRemembering, grants: false)
                .accessibilityIdentifier("memory-consent-decline")
        } header: {
            Text(MemoryConsentCopy.title)
        } footer: {
            // States the current position plainly, in both directions. A student
            // should never have to infer whether this is on.
            Text(
                isRemembering
                    ? "C.A.L is keeping what you type in Chat. Choose the second option to stop."
                    : "C.A.L is not keeping anything. Chat still works; it just starts fresh each time."
            )
            .accessibilityIdentifier("memory-consent-state")
        }
    }

    private var isRemembering: Bool {
        container.memoryConsent.permitsRemoteMemory
    }

    private func choice(_ title: String, isSelected: Bool, grants: Bool) -> some View {
        Button {
            container.setMemoryConsent(grants)
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Brand.action : Surface.inkSecondary)
                Text(title)
                    .foregroundStyle(Surface.inkPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            // The whole row, so the target is the sentence rather than the circle.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("signed out") {
    NavigationStack { SignInView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
