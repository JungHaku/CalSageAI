import CalDesign
import SwiftUI

/// First-run story: what C.A.L. is.
///
/// Shown after Create account (check-your-email) and once after the first
/// sign-in, until `Profile.onboardedAt` is set.
struct WelcomeView: View {
    enum Kind {
        /// Account created; confirm mail, then sign in.
        case checkEmail
        /// First session on this phone.
        case firstSession
    }

    let kind: Kind
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                CalAvatar(.hero, halo: .sageAndGold, activity: .idle, label: "C.A.L.")

                if kind == .checkEmail {
                    VStack(spacing: 8) {
                        Text("Thanks for creating an account")
                            .font(.title.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text("Confirm the email we just sent, then come back and sign in.")
                            .font(.body)
                            .foregroundStyle(Surface.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("Your personal coherence coach.")
                            .font(.title.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("welcome-headline")
                        Text("C.A.L. is the name, coherence is the game.")
                            .font(.title3)
                            .foregroundStyle(Surface.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            Button(kind == .checkEmail ? "Back to sign in" : "Meet C.A.L.") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .accessibilityIdentifier("welcome-continue")
        }
        .background(Surface.appBackground.ignoresSafeArea())
        .tint(Brand.action)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-page")
    }
}

#Preview("after signup") {
    WelcomeView(kind: .checkEmail, onContinue: {})
}

#Preview("first session") {
    WelcomeView(kind: .firstSession, onContinue: {})
}
