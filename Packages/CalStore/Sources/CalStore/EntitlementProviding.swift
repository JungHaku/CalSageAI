import CalKit
import Foundation

/// The purchase seam (ARCHITECTURE.md §2).
///
/// MVP: `StoreKitEntitlementProvider`, reading the device's own transaction
/// history. Phase B: the same protocol backed by a server that validates with
/// Apple and syncs entitlement across a person's devices. Consumers never change.
///
/// Everything here is expressed in `CalKit` value types rather than StoreKit ones,
/// which is the whole point — the paywall, the gating, and the tests all run
/// against `SubscriptionProduct` and `PurchaseOutcome`, never against `Product`
/// or `Transaction`.
public protocol EntitlementProviding: Sendable {
    /// Begins observing transactions that originate outside this app — renewals,
    /// refunds, purchases made on another device, Ask to Buy approvals, and
    /// anything that arrived while the app was closed.
    ///
    /// On the protocol rather than left to the implementation so that
    /// `PremiumStore.start()` always calls it. Forgetting to observe transactions
    /// is the classic StoreKit bug, and its symptom — the App Store re-presenting
    /// a purchase the person already made — appears long after the mistake.
    /// Defaulted to a no-op, since only the StoreKit-backed provider needs it.
    func startListening() async

    /// What the person is entitled to right now.
    func currentEntitlement() async -> Entitlement

    /// Entitlement changes over the life of the app: a purchase completing, a
    /// renewal, a lapse, a refund, a family-sharing grant, or a transaction that
    /// arrived while the app wasn't running.
    ///
    /// Not optional to observe. A subscription can change state without the person
    /// touching the app, so polling once at launch would leave the UI wrong for
    /// the rest of the session.
    var entitlementUpdates: AsyncStream<Entitlement> { get }

    /// What's for sale. Empty is a legitimate answer — the product may not be
    /// approved or released yet — and the paywall has to render that honestly
    /// rather than showing a dead Subscribe button.
    func products() async throws -> [SubscriptionProduct]

    func purchase(_ product: SubscriptionProduct) async throws -> PurchaseOutcome

    /// Re-reads entitlement from the store. Distinct from `currentEntitlement()`
    /// in that it may go to the network and prompt for an App Store sign-in, so it
    /// belongs behind an explicit "Restore purchases" control rather than running
    /// at launch.
    @discardableResult
    func restore() async throws -> Entitlement
}

extension EntitlementProviding {
    public func startListening() async {}
}

/// A subscription product, as the paywall needs to show it.
///
/// A plain value type on purpose: it carries the App Store's *localised* price
/// string rather than a number and a currency code, because formatting money
/// correctly for every storefront is StoreKit's job and getting it wrong is both
/// a review rejection and a lie about the price.
public struct SubscriptionProduct: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let description: String
    /// Already formatted for the person's storefront, e.g. "$11.00" or "£8.99".
    public let displayPrice: String
    /// The billing period, e.g. "month". Shown next to the price because
    /// guideline 3.1.2 requires the duration to be visible before purchase.
    public let period: String
    /// An introductory offer, if one is configured.
    public let introductoryOffer: IntroductoryOffer?

    public init(
        id: String,
        displayName: String,
        description: String,
        displayPrice: String,
        period: String,
        introductoryOffer: IntroductoryOffer? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.period = period
        self.introductoryOffer = introductoryOffer
    }

    /// The price line, as one string. Built here rather than in the view so the
    /// disclosure requirement is unit-tested — an auto-renewing price has to state
    /// its period, and "$11.00" alone does not.
    public var priceLine: String { "\(displayPrice)/\(period)" }
}

public struct IntroductoryOffer: Sendable, Equatable, Hashable {
    public let displayPrice: String
    public let periodDescription: String
    public let isFreeTrial: Bool

    public init(displayPrice: String, periodDescription: String, isFreeTrial: Bool) {
        self.displayPrice = displayPrice
        self.periodDescription = periodDescription
        self.isFreeTrial = isFreeTrial
    }
}

/// The result of asking to buy.
///
/// `pending` is not a rarity to be folded into failure: with a 16+ rating some
/// users are minors, and Family Sharing's Ask to Buy puts every one of their
/// purchases here until a parent approves. The UI has to say "waiting for
/// approval" and leave it at that — no spinner that never ends, and no unlock.
public enum PurchaseOutcome: Sendable, Equatable, Hashable {
    case purchased(Entitlement)
    case userCancelled
    case pending
    /// The transaction did not pass verification. Treated as a failure to
    /// purchase, never as a grant.
    case unverified
}

public enum PurchaseError: Error, Equatable, Sendable {
    /// Asked to buy something that isn't for sale — product withdrawn, not
    /// approved, or the wrong identifier.
    case productUnavailable(String)
    case storeUnavailable
}
