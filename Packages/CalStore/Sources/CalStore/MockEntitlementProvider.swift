import CalKit
import Foundation

/// A scriptable stand-in for the App Store.
///
/// This is what makes the paywall testable at all. A real StoreKit purchase is a
/// system-level sheet that XCUITest cannot reliably drive and that needs a sandbox
/// account; behind this seam, "a purchase succeeded and the app unlocked" becomes
/// an ordinary assertion (ARCHITECTURE.md §11.2).
///
/// Also used by previews and by UI tests via `-CalEntitlement` (see `AppContainer`).
public actor MockEntitlementProvider: EntitlementProviding {
    private var entitlement: Entitlement
    private var catalogue: [SubscriptionProduct]

    /// What the next `purchase(_:)` returns. Defaults to succeeding at `.plus`.
    public var nextPurchaseOutcome: PurchaseOutcome
    /// When set, `purchase(_:)` throws this instead of returning an outcome.
    public var purchaseError: PurchaseError?
    /// When set, `products()` throws — the "App Store is unreachable" path.
    public var productsError: PurchaseError?

    public private(set) var restoreCallCount = 0
    public private(set) var purchaseCallCount = 0

    nonisolated public let entitlementUpdates: AsyncStream<Entitlement>
    nonisolated private let continuation: AsyncStream<Entitlement>.Continuation

    public init(
        entitlement: Entitlement = .free,
        products: [SubscriptionProduct] = [.calPlusPreview],
        nextPurchaseOutcome: PurchaseOutcome = .purchased(.plus)
    ) {
        self.entitlement = entitlement
        self.catalogue = products
        self.nextPurchaseOutcome = nextPurchaseOutcome
        let (stream, continuation) = AsyncStream<Entitlement>.makeStream()
        self.entitlementUpdates = stream
        self.continuation = continuation
    }

    public func currentEntitlement() async -> Entitlement { entitlement }

    public func products() async throws -> [SubscriptionProduct] {
        if let productsError { throw productsError }
        return catalogue
    }

    public func purchase(_ product: SubscriptionProduct) async throws -> PurchaseOutcome {
        purchaseCallCount += 1
        if let purchaseError { throw purchaseError }
        guard catalogue.contains(where: { $0.id == product.id }) else {
            throw PurchaseError.productUnavailable(product.id)
        }
        let outcome = nextPurchaseOutcome
        // Only a completed purchase grants anything. `pending` deliberately leaves
        // the entitlement alone — that's the Ask to Buy case, where a parent has
        // not approved yet and the person has not been charged.
        if case .purchased(let granted) = outcome { apply(granted) }
        return outcome
    }

    @discardableResult
    public func restore() async throws -> Entitlement {
        restoreCallCount += 1
        return entitlement
    }

    // MARK: Test control

    /// Drives an entitlement change from outside a purchase — a renewal, a lapse,
    /// a refund, or a transaction arriving while the app was closed.
    public func simulate(_ newValue: Entitlement) { apply(newValue) }

    public func setNextPurchaseOutcome(_ outcome: PurchaseOutcome) {
        nextPurchaseOutcome = outcome
    }

    public func setPurchaseError(_ error: PurchaseError?) { purchaseError = error }
    public func setProductsError(_ error: PurchaseError?) { productsError = error }
    public func setProducts(_ products: [SubscriptionProduct]) { catalogue = products }

    private func apply(_ newValue: Entitlement) {
        entitlement = newValue
        continuation.yield(newValue)
    }
}

extension SubscriptionProduct {
    /// Stand-in for the real product, for previews and tests.
    ///
    /// The price here is Dr. Mia's stated $11/month. It is **not** authoritative:
    /// at runtime the paywall shows `displayPrice` straight from StoreKit, because
    /// the App Store decides the price in the person's own currency and hardcoding
    /// a formatted price is how apps end up lying about what they charge.
    public static let calPlusPreview = SubscriptionProduct(
        id: Self.calPlusMonthlyID,
        displayName: "C.A.L+ Coherence",
        description: "The ten-question coherence framework, your full progress, and the guided library.",
        displayPrice: "$11.00",
        period: "month"
    )

    /// The App Store Connect product identifier. Reverse-DNS, matching the bundle
    /// ID, so it is unambiguous which app it belongs to.
    public static let calPlusMonthlyID = "org.wholelifeministries.cal.plus.monthly"
}
