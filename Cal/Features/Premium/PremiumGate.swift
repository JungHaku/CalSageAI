import CalKit
import CalStore
import SwiftUI

/// Wraps a premium screen: shows it when the person is entitled, and a locked
/// state with a way to the paywall when they aren't.
///
/// The one place gating is decided, so "is this locked?" has a single answer
/// rather than a scattering of `if` statements that can disagree.
struct PremiumGate<Content: View>: View {
    let feature: PremiumFeature
    @ViewBuilder var content: () -> Content

    @Environment(AppContainer.self) private var container
    @State private var showingPaywall = false

    var body: some View {
        Group {
            if !container.premium.hasResolved {
                // Deliberately neither the content nor the lock. Guessing here is
                // how a subscriber gets shown an upgrade prompt for the half-second
                // before StoreKit answers.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("premium-resolving")
            } else if container.premium.unlocks(feature) {
                content()
            } else {
                PremiumLockedView(feature: feature) { showingPaywall = true }
            }
        }
        .sheet(isPresented: $showingPaywall) {
            NavigationStack { PaywallView(context: feature) }
        }
    }
}

/// What a locked premium screen shows.
///
/// Says what the feature is and what the free version still does, rather than
/// only what's missing. Someone who isn't going to pay should leave this screen
/// knowing Cal still works for them — Dr. Mia's stated goal for the free tier is
/// that a student in trouble opens Cal, and that goal doesn't have an exception
/// for people who saw a paywall first.
struct PremiumLockedView: View {
    let feature: PremiumFeature
    let onUpgrade: () -> Void

    var body: some View {
        // The identifier goes on a leaf, never on the `ContentUnavailableView`.
        // An identifier on a SwiftUI container propagates down and overwrites its
        // descendants', which would silently rename the button below and make it
        // unfindable — the same trap that cost an afternoon in MVP-3.
        ContentUnavailableView {
            Label(feature.title, systemImage: "lock")
        } description: {
            VStack(spacing: 12) {
                Text(feature.blurb)
                    .accessibilityIdentifier("premium-locked-\(feature.rawValue)")
                Text(feature.freeAlternative)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("See Cal+") { onUpgrade() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("locked-upgrade")
        }
        .scrollableWhenLarge()
    }
}

extension PremiumFeature {
    /// What still works without paying. Every gated screen names one, so the
    /// locked state is a signpost rather than a dead end.
    var freeAlternative: String {
        switch self {
        case .fullCheckIn:
            "The daily check-in is still yours, with guided breathing whenever you need it."
        case .coherenceAnalytics:
            "Home still shows your streak and recent average, and History has every check-in you've made."
        case .practiceLibrary:
            "Guided breathing is still there inside every check-in."
        }
    }
}

#Preview("locked") {
    NavigationStack {
        PremiumGate(feature: .coherenceAnalytics) { Text("secret analytics") }
    }
    .environment(AppContainer.live(arguments: ["-CalEntitlement", "free"]))
}

#Preview("unlocked") {
    NavigationStack {
        PremiumGate(feature: .coherenceAnalytics) { Text("secret analytics") }
    }
    .environment(AppContainer.live(arguments: ["-CalEntitlement", "plus"]))
}
