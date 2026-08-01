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
        .task { signedInEmail = await container.auth.credentials()?.email }
    }

    // MARK: Signed out

    private var explanation: some View {
        Section {
            Text(
                """
                An account is only needed so Cal can carry a conversation across \
                devices. Everything you have already done — check-ins, practices, \
                history — is on this phone and stays there whether you sign in or not.
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

    private func signedInSection(_ address: String) -> some View {
        Section {
            LabeledContent("Signed in as", value: address)
            Button("Sign out", role: .destructive) {
                Task {
                    await container.auth.signOut()
                    signedInEmail = nil
                }
            }
            .accessibilityIdentifier("signin-signout")
        } footer: {
            Text("Signing out on this phone doesn't delete anything. Use Settings › Delete everything for that.")
        }
    }

    /// The second yes. Defaults to no, and says so in a sentence a person can
    /// act on rather than a sentence that survives a lawsuit.
    private var consentSection: some View {
        Section {
            Text(MemoryConsentCopy.body)
                .font(.subheadline)

            Text(MemoryConsentCopy.sharingNote)
                .font(.footnote)
                .foregroundStyle(Surface.inkSecondary)

            Toggle(
                MemoryConsentCopy.acceptTitle,
                isOn: Binding(
                    get: { container.memoryConsent.permitsRemoteMemory },
                    set: { container.setMemoryConsent($0) }
                )
            )
            .accessibilityIdentifier("memory-consent-toggle")
        } header: {
            Text(MemoryConsentCopy.title)
        } footer: {
            // States the current position plainly, in both directions. A student
            // should never have to infer whether this is on.
            Text(
                container.memoryConsent.permitsRemoteMemory
                    ? "Cal is keeping what you type in Chat. Turn this off to stop."
                    : "Cal is not keeping anything. Chat still works; it just starts fresh each time."
            )
            .accessibilityIdentifier("memory-consent-state")
        }
    }
}

#Preview("signed out") {
    NavigationStack { SignInView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
