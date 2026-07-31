import CalKit
import Foundation
import StoreKit

// Note the `StoreKit.Transaction` qualification throughout this file. SwiftUI
// also exports a `Transaction` type, so the bare name becomes ambiguous the
// moment anything here imports SwiftUI — qualifying now costs nothing and saves
// a confusing failure later.

/// The real thing: entitlement read from the device's own transaction history.
///
/// No server. `Transaction.currentEntitlements` is maintained by the system and
/// is readable offline, which is what makes a device-local entitlement viable for
/// an MVP with no backend (ARCHITECTURE.md §2). At Phase B this same protocol gets
/// a server-validated implementation and nothing above it changes.
///
/// ## What verification does and does not buy
///
/// Every transaction arrives inside a `VerificationResult`, signed by Apple and
/// checked by StoreKit against the device's trust store. `.verified` means the
/// payload genuinely came from Apple and was not altered in transit. It does
/// **not** defend against someone who controls the device — a jailbroken phone can
/// lie to any local check. That is an accepted trade for this app: the downside of
/// a bypassed paywall here is one unpaid subscription, not exposure of anyone
/// else's data. Anything that actually needs to be trustworthy would have to be
/// validated server-side, which is a Phase B conversation.
public actor StoreKitEntitlementProvider: EntitlementProviding {
    private let productIDs: [String]

    nonisolated public let entitlementUpdates: AsyncStream<Entitlement>
    nonisolated private let continuation: AsyncStream<Entitlement>.Continuation
    private var updateListener: Task<Void, Never>?

    public init(productIDs: [String] = [SubscriptionProduct.calPlusMonthlyID]) {
        self.productIDs = productIDs
        let (stream, continuation) = AsyncStream<Entitlement>.makeStream()
        self.entitlementUpdates = stream
        self.continuation = continuation
    }

    deinit {
        updateListener?.cancel()
        continuation.finish()
    }

    /// Begins listening for transactions.
    ///
    /// Must be called as early as possible in the app's life, and this is not
    /// stylistic. `Transaction.updates` is where StoreKit delivers anything that
    /// happened outside a purchase this session: a renewal, a refund, a purchase
    /// made on another device, an Ask to Buy approval, or a transaction that
    /// arrived while the app was not running. A transaction that is never observed
    /// is never finished, and the App Store will keep re-presenting it — including
    /// showing the person a repeat purchase prompt.
    public func startListening() {
        guard updateListener == nil else { return }
        updateListener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        // Finish in **both** cases. Granting is conditional on verification;
        // finishing is not. An unfinished transaction is redelivered on every
        // launch forever, so silently dropping the unverified ones would leave a
        // permanent backlog that the App Store keeps re-presenting.
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            continuation.yield(await currentEntitlement())
        case .unverified(let transaction, _):
            await transaction.finish()
        }
    }

    // MARK: Entitlement

    /// Reads the current entitlement from the device.
    ///
    /// `currentEntitlements` is the right question to ask. It returns only what is
    /// *active right now* — the system has already accounted for expiry, upgrades,
    /// family sharing, and refunds, so this does not need to compare dates itself.
    /// Asking `Transaction.latest` instead would happily return a subscription that
    /// lapsed months ago.
    public func currentEntitlement() async -> Entitlement {
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard productIDs.contains(transaction.productID) else { continue }
            // A refunded or upgraded-away transaction carries a revocation date and
            // must not grant anything, even while it is still listed.
            guard transaction.revocationDate == nil else { continue }
            return .plus
        }
        return .free
    }

    // MARK: Catalogue

    public func products() async throws -> [SubscriptionProduct] {
        let storeProducts: [Product]
        do {
            storeProducts = try await Product.products(for: productIDs)
        } catch {
            throw PurchaseError.storeUnavailable
        }
        return storeProducts.map(Self.describe)
    }

    /// Maps StoreKit's `Product` onto the value type the paywall renders.
    ///
    /// `displayPrice` and the localised period come from StoreKit rather than being
    /// composed here: the App Store sets the price in the person's own currency and
    /// storefront, and a hardcoded "$11.00" would be wrong for most of the world
    /// and a false price disclosure besides.
    nonisolated private static func describe(_ product: Product) -> SubscriptionProduct {
        let period = product.subscription.map { Self.periodName($0.subscriptionPeriod) } ?? ""
        var offer: IntroductoryOffer?
        if let introductory = product.subscription?.introductoryOffer {
            offer = IntroductoryOffer(
                displayPrice: introductory.displayPrice,
                periodDescription: Self.periodName(introductory.period),
                isFreeTrial: introductory.paymentMode == .freeTrial
            )
        }
        return SubscriptionProduct(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            period: period,
            introductoryOffer: offer
        )
    }

    nonisolated private static func periodName(_ period: Product.SubscriptionPeriod) -> String {
        let unit = switch period.unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        @unknown default: "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }

    // MARK: Purchase

    public func purchase(_ product: SubscriptionProduct) async throws -> PurchaseOutcome {
        let matches = try await Product.products(for: [product.id])
        guard let storeProduct = matches.first else {
            throw PurchaseError.productUnavailable(product.id)
        }

        let result: Product.PurchaseResult
        do {
            result = try await storeProduct.purchase()
        } catch {
            throw PurchaseError.storeUnavailable
        }

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                // Signature check failed. Not a grant — and still finished, or it
                // would be redelivered on every launch.
                if case .unverified(let transaction, _) = verification {
                    await transaction.finish()
                }
                return .unverified
            }
            await transaction.finish()
            let entitlement = await currentEntitlement()
            continuation.yield(entitlement)
            return .purchased(entitlement)

        case .userCancelled:
            return .userCancelled

        // Ask to Buy: a minor has requested the purchase and a parent has not
        // approved it. Nothing has been charged and nothing is owed — the
        // transaction will arrive later on `Transaction.updates`, if ever.
        case .pending:
            return .pending

        @unknown default:
            return .userCancelled
        }
    }

    // MARK: Restore

    /// Explicitly re-syncs with the App Store.
    ///
    /// Ordinary reinstalls do not need this — `currentEntitlements` repopulates on
    /// its own — but Apple requires a visible restore control, and it is the
    /// genuine fix when a person is signed into a different Apple Account than the
    /// one that bought the subscription. It can prompt for authentication, which is
    /// why it must never run automatically at launch.
    @discardableResult
    public func restore() async throws -> Entitlement {
        do {
            try await AppStore.sync()
        } catch {
            throw PurchaseError.storeUnavailable
        }
        let entitlement = await currentEntitlement()
        continuation.yield(entitlement)
        return entitlement
    }
}
