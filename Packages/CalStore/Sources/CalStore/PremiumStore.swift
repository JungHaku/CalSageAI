import CalKit
import Foundation
import Observation

/// The entitlement, as the UI observes it.
///
/// Wraps any `EntitlementProviding` and turns it into observable state, so views
/// ask `store.unlocks(.coherenceAnalytics)` and re-render when a purchase lands,
/// a renewal happens, or a subscription lapses.
@Observable
@MainActor
public final class PremiumStore {
    private let provider: any EntitlementProviding
    /// Held in a `Sendable` box rather than a plain property so `deinit` — which
    /// is nonisolated — can still cancel it.
    private let listener = TaskBox()

    public private(set) var entitlement: Entitlement = .default

    /// False until the store has actually been asked.
    ///
    /// The distinction matters more than it looks. Without it, `entitlement`
    /// starts at `.free` and every launch shows a paying subscriber a locked
    /// screen and an upgrade prompt for the moment before StoreKit answers.
    /// Gated views wait on this rather than reading `entitlement` directly.
    public private(set) var hasResolved = false

    public private(set) var products: [SubscriptionProduct] = []
    public private(set) var isLoadingProducts = false
    /// Set when the catalogue could not be fetched. The paywall says so plainly
    /// instead of rendering a Subscribe button that cannot work.
    public private(set) var productsUnavailable = false

    public private(set) var isPurchasing = false
    /// True after a purchase came back `.pending` — Ask to Buy, waiting on a
    /// parent. Neither success nor failure, and the UI has to say exactly that.
    public private(set) var isAwaitingApproval = false

    public init(provider: any EntitlementProviding) {
        self.provider = provider
    }

    deinit { listener.cancel() }

    /// Resolves the current entitlement and starts listening for changes.
    ///
    /// Safe to call more than once; only the first call starts a listener.
    public func start() async {
        // Before reading the entitlement, not after: a transaction can land while
        // the first read is in flight, and the listener has to be up to catch it.
        await provider.startListening()
        entitlement = await provider.currentEntitlement()
        hasResolved = true

        guard !listener.isRunning else { return }
        let stream = provider.entitlementUpdates
        // Inherits MainActor from the enclosing context, so `apply` is a direct
        // call — the state it touches is observed by SwiftUI and belongs there.
        listener.set(
            Task { [weak self] in
                for await updated in stream {
                    guard let self else { return }
                    self.apply(updated)
                }
            }
        )
    }

    private func apply(_ updated: Entitlement) {
        entitlement = updated
        hasResolved = true
        // An entitlement arriving is the definitive answer to a pending purchase.
        if updated != .free { isAwaitingApproval = false }
    }

    public func unlocks(_ feature: PremiumFeature) -> Bool {
        entitlement.unlocks(feature)
    }

    /// The check-in flow this person gets. While unresolved, the free flow — the
    /// alternative is starting someone on the ten-question framework and yanking
    /// it away mid-flow when StoreKit answers.
    public var checkInKind: CheckInKind { entitlement.checkInKind }

    public func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await provider.products()
            // An empty catalogue is not an error — the product may simply not be
            // released for sale yet — but it is equally unbuyable, so it reads the
            // same way to the person looking at the screen.
            productsUnavailable = products.isEmpty
        } catch {
            products = []
            productsUnavailable = true
        }
    }

    @discardableResult
    public func purchase(_ product: SubscriptionProduct) async -> PurchaseOutcome? {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let outcome = try await provider.purchase(product)
            switch outcome {
            case .purchased(let granted):
                entitlement = granted
                hasResolved = true
                isAwaitingApproval = false
            case .pending:
                isAwaitingApproval = true
            case .userCancelled, .unverified:
                break
            }
            return outcome
        } catch {
            return nil
        }
    }

    @discardableResult
    public func restore() async -> Entitlement? {
        do {
            let restored = try await provider.restore()
            entitlement = restored
            hasResolved = true
            return restored
        } catch {
            return nil
        }
    }
}

/// A `Sendable` holder for the update-listening task.
///
/// Exists only because `deinit` is nonisolated and so cannot read a
/// `@MainActor` stored property. A `let` of a `Sendable` type it can read.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var isRunning: Bool { lock.withLock { task != nil } }

    func set(_ newTask: Task<Void, Never>) {
        lock.withLock {
            task?.cancel()
            task = newTask
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}
