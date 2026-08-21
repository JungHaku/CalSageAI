import CalDesign
import CalKit
import CalStore
import SwiftUI

/// The upgrade screen for C.A.L+ Coherence.
///
/// ## What this screen may claim
///
/// Only what is built. `SPEC-premium.md` also promises an AI Coherence Coach, an
/// AI Journal, a Personalized Daily Action Plan, a Weekly Coherence Review,
/// community sessions, and a fifteen-title library — none of which exist yet.
/// Listing them here would be a guideline 2.3.1 rejection *and* a
/// misrepresentation to someone being asked for $11 a month, so the included list
/// is generated from `PremiumFeature.allCases` rather than typed by hand. Adding a
/// line to this screen means shipping the feature first.
struct PaywallView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    /// Which locked feature the person tapped, so the screen can lead with the
    /// thing they actually wanted instead of a generic pitch.
    var context: PremiumFeature?

    @State private var showingPendingNotice = false

    private var premium: PremiumStore { container.premium }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                includedList
                purchaseSection
                disclosures
            }
            .padding()
        }
        .navigationTitle("C.A.L+ Coherence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("paywall-close")
            }
        }
        .task { await premium.loadProducts() }
        .alert("Waiting for approval", isPresented: $showingPendingNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                """
                This purchase needs approval from your family organiser. Nothing has \
                been charged. C.A.L+ unlocks by itself once it's approved.
                """
            )
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.map(\.pitch) ?? "The guided practice library")
                .font(.title2.weight(.semibold))
            Text("C.A.L is his name. Coherence is his game.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("paywall-header")
    }

    // MARK: What you get

    private var includedList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's included")
                .font(.headline)

            ForEach(PremiumFeature.allCases, id: \.self) { feature in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.subheadline.weight(.medium))
                        Text(feature.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }

            // The honest counterweight to a feature list. Everything above is
            // working today; her spec promises more, and this screen will not
            // charge for it in advance.
            Text("More is planned, but you're only paying for what's here now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityIdentifier("paywall-scope-note")
        }
        .padding()
        .background(Surface.card, in: .rect(cornerRadius: 14))
    }

    // MARK: Buying

    @ViewBuilder
    private var purchaseSection: some View {
        if premium.entitlement == .plus {
            Label("You're subscribed", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("paywall-already-subscribed")
        } else if premium.isLoadingProducts {
            ProgressView().frame(maxWidth: .infinity)
        } else if let product = premium.products.first {
            VStack(spacing: 12) {
                // Schedule 2 §3.8(b) of the Developer Program License Agreement is
                // the binding list, and it is only three items: title, length,
                // price. All three appear here, and the *billed amount* is the
                // most prominent pricing element on the screen — Apple's
                // subscriptions guidance requires that hierarchy specifically, and
                // inverting it (a big "37¢/day" over a small "$11/month") is what
                // draws most cosmetic 3.1.2 rejections.
                VStack(spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    Text(product.priceLine)
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityIdentifier("paywall-price")
                    Text("Billed monthly. Cancel any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                // Directly above the button, not in a footer. California's
                // Automatic Renewal Law (as amended by AB 2863, in force since
                // 1 July 2025) requires the automatic-renewal terms to appear in
                // "visual proximity" to the control that gives consent. Apple is
                // our agent on the US storefront rather than the merchant of
                // record, so the obligation is ours — and §17602(a)(2) wants
                // consent to *the agreement containing the renewal terms*, which
                // a payment sheet authorising a charge does not by itself supply.
                // Hence this line, here, rather than relying on Apple's flow.
                renewalTerms

                Button {
                    Task { await buy(product) }
                } label: {
                    if premium.isPurchasing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Subscribe").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(premium.isPurchasing)
                .accessibilityIdentifier("paywall-subscribe")

                if let offer = product.introductoryOffer {
                    Text(introductoryLine(offer, then: product))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("paywall-intro-offer")
                }

                restoreButton
            }
        } else {
            // Not an error state — the product genuinely isn't on sale yet. Saying
            // so beats a Subscribe button that does nothing.
            VStack(alignment: .leading, spacing: 10) {
                Label("Not available yet", systemImage: "clock")
                    .font(.headline)
                Text(
                    """
                    C.A.L+ isn't on sale yet. Everything in the free version keeps \
                    working, and nothing here is charged.
                    """
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                restoreButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("paywall-unavailable")
        }
    }

    /// Present on every state of this screen except "already subscribed".
    ///
    /// Apple's subscriptions guidance lists "a way for current subscribers to sign
    /// in or restore purchases" among the things that *must* be on the sign-up
    /// screen. No single Review Guideline says it in those words — 3.1.1 only
    /// manages a "should" — but omitting it reliably draws a rejection, so it is
    /// treated as mandatory rather than as a nicety.
    private var restoreButton: some View {
        Button("Restore purchases") {
            Task { await premium.restore() }
        }
        .font(.subheadline)
        // 44×44pt is Apple's stated minimum and the audit reports anything under
        // it. A caption-sized control is around half that tall, which matters most
        // for exactly the people least able to hit a small target.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .accessibilityIdentifier("paywall-restore")
    }

    /// Spells out what happens after the trial ends. An introductory offer that
    /// says "free for a week" without saying what it renews at is the single most
    /// complained-about pattern in subscription apps, and is what California's
    /// auto-renewal law is aimed at.
    private func introductoryLine(_ offer: IntroductoryOffer, then product: SubscriptionProduct) -> String {
        let opening = offer.isFreeTrial
            ? "Free for \(offer.periodDescription)"
            : "\(offer.displayPrice) for \(offer.periodDescription)"
        return "\(opening), then \(product.priceLine). Cancel any time in Settings."
    }

    private func buy(_ product: SubscriptionProduct) async {
        let outcome = await premium.purchase(product)
        switch outcome {
        case .purchased:
            dismiss()
        case .pending:
            showingPendingNotice = true
        case .userCancelled, .unverified, .none:
            break
        }
    }

    // MARK: Required disclosures

    /// Deliberately short.
    ///
    /// The long "charged to your iTunes Account at confirmation of purchase… at
    /// least 24 hours before the end of the current period…" boilerplate that
    /// circulates on developer blogs was removed from Schedule 2 and is **not** an
    /// Apple requirement — the purchase sheet states renewal terms itself, and
    /// reproducing it would only compete with the price for prominence, which is a
    /// rule Apple does still enforce. What stays is the substance the auto-renewal
    /// statutes actually ask for: that it recurs, how often, and how to stop it.
    private var renewalTerms: some View {
        Text(
            """
            Renews every month until you cancel. Cancel any time in \
            Settings › Apple Account › Subscriptions.
            """
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("paywall-renewal-terms")
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Schedule 2 §3.8(b) requires both links be "accessible within Your
            // Licensed Application"; putting them on the purchase screen satisfies
            // that and removes any argument about it. Both must resolve — a 404
            // here is a 2.1(a) "fully functional URLs" rejection.
            HStack(spacing: 16) {
                Link("Terms of Use", destination: Legal.termsOfUse)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier("paywall-terms-link")
                Link("Privacy Policy", destination: Legal.privacyPolicy)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier("paywall-privacy-link")
            }
            // Footnote rather than caption: these are legally required links, and
            // the audit reported caption-sized ones failing contrast outright.
            .font(.footnote)
        }
    }
}

extension PremiumFeature {
    var title: String {
        switch self {
        case .practiceLibrary: "The guided library"
        }
    }

    var blurb: String {
        switch self {
        case .practiceLibrary:
            "Dr. Curcuruto's guided practices, to play whenever you want them."
        }
    }

    /// The line the paywall leads with when this is the thing that was tapped.
    var pitch: String {
        switch self {
        case .practiceLibrary: "Practise whenever you want"
        }
    }
}

/// Where the legal documents live.
///
/// Apple's standard EULA is the default for apps that don't supply their own, and
/// linking it is acceptable under 3.1.2 — but the privacy policy has to be Cal's
/// own, and the URL below must resolve before submission. Tracked in
/// `docs/LAUNCH-REQUIREMENTS.md` §18.6.
enum Legal {
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://breathehealthcenter.com/cal/privacy")!
}

#Preview("paywall") {
    NavigationStack { PaywallView(context: .practiceLibrary) }
        .environment(AppContainer.live(arguments: ["-CalEntitlement", "free"]))
}

#Preview("already subscribed") {
    NavigationStack { PaywallView() }
        .environment(AppContainer.live(arguments: ["-CalEntitlement", "plus"]))
}
