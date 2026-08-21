import CalData
import CalDesign
import CalKit
import SwiftUI

/// The app front door. Email and password against Supabase Auth.
///
/// Emergency Help is behind this screen by product choice. The 988 line is
/// here so a first launch with no account is not a blank wall.
struct LoginGateView: View {
    @Environment(AppContainer.self) private var container

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var recoverNotice: String?
    @State private var showingWelcome = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        """
                        Sign in so Cal can keep your account. What you do after \
                        that lives on this phone and can back up to your account.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(Surface.inkSecondary)
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin-email")

                    SecureField("Password", text: $password)
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
                        recoverNotice = nil
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("signin-toggle-mode")

                    if !isRegistering {
                        Button("Forgot password") {
                            Task { await sendReset() }
                        }
                        .font(.footnote)
                        .disabled(!email.contains("@") || isWorking)
                        .accessibilityIdentifier("signin-forgot")
                    }
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(CoherenceScale.textTint(for: .low))
                            .accessibilityIdentifier("signin-error")
                    } else if let recoverNotice {
                        Text(recoverNotice)
                            .accessibilityIdentifier("signin-recover-notice")
                    } else if isWorking {
                        Text("Working…")
                    }
                }

                Section {
                    Link("If you are in crisis, call 988", destination: URL(string: "tel:988")!)
                        .accessibilityIdentifier("login-crisis-line")
                }
            }
            .navigationTitle(isRegistering ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingWelcome) {
                WelcomeView(kind: .checkEmail) {
                    showingWelcome = false
                    isRegistering = false
                }
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
        recoverNotice = nil
        defer { isWorking = false }

        do {
            _ = isRegistering
                ? try await container.auth.signUp(email: email, password: password)
                : try await container.auth.signIn(email: email, password: password)
            password = ""
            container.noteSignedIn()
        } catch AuthError.confirmationRequired {
            password = ""
            showingWelcome = true
        } catch let authError as AuthError {
            error = authError.userFacingMessage
        } catch is CancellationError {
            error = nil
        } catch {
            self.error = "Couldn't reach the server. Check your connection and try again."
        }
    }

    private func sendReset() async {
        isWorking = true
        error = nil
        recoverNotice = nil
        defer { isWorking = false }
        do {
            try await container.auth.recover(email: email)
            recoverNotice = "Check your email for a reset link, then sign in."
        } catch let authError as AuthError {
            error = authError.userFacingMessage
        } catch {
            self.error = "Couldn't reach the server. Check your connection and try again."
        }
    }
}

#Preview("login") {
    LoginGateView()
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1", "-CalForceLogin", "1"]))
}
