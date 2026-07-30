import Foundation

/// What a sync attempt did.
public enum SyncOutcome: Equatable, Sendable {
    /// No backend is configured. The MVP's permanent answer.
    case notConfigured
    case offline
    case synced(pushed: Int, pulled: Int)
}

/// The sync seam (ARCHITECTURE.md §2, §15).
///
/// Exists in the MVP so that (a) callers are written against it from day one and
/// (b) the UI can honestly say "N changes stored on this device" rather than
/// implying they're backed up somewhere.
public protocol SyncEngine: Sendable {
    /// Rows written locally and not yet pushed. In the MVP this is *everything*,
    /// because nothing ever clears `isDirty` — which is also exactly what the
    /// Phase B outbox needs on a device that has never synced.
    func pendingCount() async throws -> Int

    @discardableResult
    func sync() async throws -> SyncOutcome
}

/// The MVP implementation: reports what's pending, pushes nothing.
///
/// Deliberately not a silent no-op. `pendingCount` is real, so a settings screen
/// can tell the truth about what exists only on this phone, and the export path
/// (§5) is the user's actual backup until Phase B.
public struct NoOpSyncEngine: SyncEngine {
    private let pending: @Sendable () async throws -> Int

    /// - Parameter pendingCount: usually `store.pendingSyncCount`.
    public init(pendingCount: @escaping @Sendable () async throws -> Int) {
        self.pending = pendingCount
    }

    public func pendingCount() async throws -> Int {
        try await pending()
    }

    @discardableResult
    public func sync() async throws -> SyncOutcome {
        .notConfigured
    }
}
