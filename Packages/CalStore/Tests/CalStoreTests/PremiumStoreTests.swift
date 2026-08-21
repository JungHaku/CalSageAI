import CalKit
import Foundation
import Testing

@testable import CalStore

@Suite("PremiumStore")
@MainActor
struct PremiumStoreTests {

    @Test("a fresh install resolves to free and unlocks nothing")
    func freeByDefault() async {
        let store = PremiumStore(provider: MockEntitlementProvider(entitlement: .free))
        await store.start()

        #expect(store.hasResolved)
        #expect(store.entitlement == .free)
        #expect(!store.unlocks(.practiceLibrary))
    }

    /// The launch-flicker guard. If `hasResolved` were not tracked separately, a
    /// subscriber would see a locked screen for the moment before StoreKit answers.
    @Test("entitlement is not treated as known before the store has answered")
    func unresolvedIsDistinctFromFree() async {
        let store = PremiumStore(provider: MockEntitlementProvider(entitlement: .plus))
        #expect(!store.hasResolved, "must not claim to know the tier before asking")
        #expect(store.entitlement == .free, "and must not guess generously either")

        await store.start()
        #expect(store.hasResolved)
        #expect(store.entitlement == .plus)
    }

    @Test("an existing subscriber resolves to plus and unlocks everything")
    func existingSubscriber() async {
        let store = PremiumStore(provider: MockEntitlementProvider(entitlement: .plus))
        await store.start()

        #expect(store.entitlement == .plus)
        for feature in PremiumFeature.allCases {
            #expect(store.unlocks(feature))
        }
    }

    // MARK: Purchase

    @Test("a completed purchase unlocks immediately")
    func purchaseUnlocks() async throws {
        let provider = MockEntitlementProvider(entitlement: .free)
        let store = PremiumStore(provider: provider)
        await store.start()

        let outcome = await store.purchase(.calPlusPreview)
        #expect(outcome == .purchased(.plus))
        #expect(store.entitlement == .plus)
        #expect(store.unlocks(.practiceLibrary))
        #expect(!store.isPurchasing, "the spinner must not be left running")
    }

    @Test("cancelling leaves the person exactly where they were")
    func cancelChangesNothing() async {
        let provider = MockEntitlementProvider(entitlement: .free)
        await provider.setNextPurchaseOutcome(.userCancelled)
        let store = PremiumStore(provider: provider)
        await store.start()

        let outcome = await store.purchase(.calPlusPreview)
        #expect(outcome == .userCancelled)
        #expect(store.entitlement == .free)
        #expect(!store.isAwaitingApproval, "cancelling is not waiting for anything")
        #expect(!store.isPurchasing)
    }

    /// Ask to Buy. With a 16+ rating some users are minors, so this is a routine
    /// path, not an edge case — and the one thing it must never do is unlock.
    @Test("a pending purchase does not unlock, and says it is waiting")
    func pendingDoesNotUnlock() async {
        let provider = MockEntitlementProvider(entitlement: .free)
        await provider.setNextPurchaseOutcome(.pending)
        let store = PremiumStore(provider: provider)
        await store.start()

        let outcome = await store.purchase(.calPlusPreview)
        #expect(outcome == .pending)
        #expect(store.entitlement == .free, "unapproved must never unlock")
        #expect(store.isAwaitingApproval)
        #expect(!store.isPurchasing)
    }

    /// A transaction that fails verification is a failure to buy, never a grant.
    @Test("an unverified transaction does not unlock")
    func unverifiedDoesNotUnlock() async {
        let provider = MockEntitlementProvider(entitlement: .free)
        await provider.setNextPurchaseOutcome(.unverified)
        let store = PremiumStore(provider: provider)
        await store.start()

        #expect(await store.purchase(.calPlusPreview) == .unverified)
        #expect(store.entitlement == .free)
    }

    @Test("a thrown purchase error leaves state clean rather than half-purchased")
    func purchaseErrorIsClean() async {
        let provider = MockEntitlementProvider(entitlement: .free)
        await provider.setPurchaseError(.storeUnavailable)
        let store = PremiumStore(provider: provider)
        await store.start()

        #expect(await store.purchase(.calPlusPreview) == nil)
        #expect(store.entitlement == .free)
        #expect(!store.isPurchasing)
        #expect(!store.isAwaitingApproval)
    }

    // MARK: Changes arriving from outside

    /// The reason the stream exists: a subscription can lapse while the app is
    /// open, and the UI has to relock without a relaunch.
    @Test("a lapse arriving from the store relocks the app")
    func lapseRelocks() async throws {
        let provider = MockEntitlementProvider(entitlement: .plus)
        let store = PremiumStore(provider: provider)
        await store.start()
        #expect(store.entitlement == .plus)

        await provider.simulate(.free)
        try await waitUntil { store.entitlement == .free }
        #expect(!store.unlocks(.practiceLibrary))
    }

    @Test("a renewal arriving while the app is open unlocks without a relaunch")
    func renewalUnlocks() async throws {
        let provider = MockEntitlementProvider(entitlement: .free)
        let store = PremiumStore(provider: provider)
        await store.start()

        await provider.simulate(.plus)
        try await waitUntil { store.entitlement == .plus }
        #expect(store.unlocks(.practiceLibrary))
    }

    @Test("an entitlement arriving resolves a pending purchase")
    func approvalClearsPending() async throws {
        let provider = MockEntitlementProvider(entitlement: .free)
        await provider.setNextPurchaseOutcome(.pending)
        let store = PremiumStore(provider: provider)
        await store.start()
        _ = await store.purchase(.calPlusPreview)
        #expect(store.isAwaitingApproval)

        // The parent approves; the transaction arrives on the stream.
        await provider.simulate(.plus)
        try await waitUntil { !store.isAwaitingApproval }
        #expect(store.entitlement == .plus)
    }

    @Test("calling start twice does not stack listeners")
    func startIsIdempotent() async throws {
        let provider = MockEntitlementProvider(entitlement: .free)
        let store = PremiumStore(provider: provider)
        await store.start()
        await store.start()

        await provider.simulate(.plus)
        try await waitUntil { store.entitlement == .plus }
        #expect(store.entitlement == .plus)
    }

    // MARK: Catalogue

    @Test("products load for the paywall")
    func loadsProducts() async {
        let store = PremiumStore(provider: MockEntitlementProvider())
        await store.loadProducts()

        #expect(store.products.count == 1)
        #expect(!store.productsUnavailable)
        #expect(!store.isLoadingProducts)
    }

    /// The product is not released for sale yet, which is exactly the state this
    /// app is in until the premium features are actually built.
    @Test("an empty catalogue reads as unavailable rather than as a broken screen")
    func emptyCatalogueIsUnavailable() async {
        let provider = MockEntitlementProvider()
        await provider.setProducts([])
        let store = PremiumStore(provider: provider)
        await store.loadProducts()

        #expect(store.products.isEmpty)
        #expect(store.productsUnavailable)
    }

    @Test("a store error reads as unavailable, not as a crash")
    func productsErrorIsUnavailable() async {
        let provider = MockEntitlementProvider()
        await provider.setProductsError(.storeUnavailable)
        let store = PremiumStore(provider: provider)
        await store.loadProducts()

        #expect(store.products.isEmpty)
        #expect(store.productsUnavailable)
        #expect(!store.isLoadingProducts)
    }

    // MARK: Restore

    @Test("restore recovers an entitlement on a new device")
    func restoreRecovers() async {
        let provider = MockEntitlementProvider(entitlement: .plus)
        let store = PremiumStore(provider: provider)
        // Deliberately not started: this is the reinstall case, where the app
        // knows nothing until the person taps Restore.
        #expect(store.entitlement == .free)

        #expect(await store.restore() == .plus)
        #expect(store.entitlement == .plus)
        #expect(store.hasResolved)
        #expect(await provider.restoreCallCount == 1)
    }

    // MARK: Price disclosure

    /// Guideline 3.1.2 wants the duration visible before purchase, so the price
    /// line is built in the model and asserted, not left to a view to remember.
    @Test("the price line always states the period, never a bare amount")
    func priceLineStatesPeriod() {
        #expect(SubscriptionProduct.calPlusPreview.priceLine == "$11.00/month")

        let annual = SubscriptionProduct(
            id: "x", displayName: "y", description: "z",
            displayPrice: "£88.00", period: "year"
        )
        #expect(annual.priceLine == "£88.00/year")
    }
}

/// Polls until `condition` holds, so a test can wait on the update stream without
/// sleeping for a fixed interval and hoping.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "timed out waiting for the condition to hold")
}
