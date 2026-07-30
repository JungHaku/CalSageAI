import CalKit
import Foundation

/// Persistence boundary for check-in data.
///
/// Deliberately a protocol: view models depend on this rather than on SwiftData or
/// Supabase, so previews and unit tests inject `InMemoryCoherenceStore` and never
/// stand up a database (ARCHITECTURE.md §4, §11.1).
///
/// The SwiftData-backed implementation, plus the sync engine described in §7,
/// lands in Phase 1 — the check-in flow is the first thing that needs it.
public protocol CoherenceStoring: Sendable {
    func checkIns(from: LocalDate, to: LocalDate) async throws -> [CheckIn]
    func checkIn(id: UUID) async throws -> CheckIn?
    func save(_ checkIn: CheckIn) async throws
    func delete(id: UUID) async throws
}

extension CoherenceStoring {
    /// Every completed check-in within the trailing `days` window.
    public func recent(days: Int, today: LocalDate, calendar: Calendar) async throws -> [CheckIn] {
        let start = today.adding(days: -(days - 1), in: calendar)
        return try await checkIns(from: start, to: today)
    }
}

/// In-memory store for previews and tests.
///
/// An actor rather than a struct with a lock: `CoherenceStoring` is async and
/// `Sendable`, and Swift 6's strict concurrency checking will not let mutable
/// shared state across it be fudged.
public actor InMemoryCoherenceStore: CoherenceStoring {
    private var storage: [UUID: CheckIn]

    public init(_ seed: [CheckIn] = []) {
        self.storage = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    public func checkIns(from: LocalDate, to: LocalDate) async throws -> [CheckIn] {
        storage.values
            .filter { $0.localDate >= from && $0.localDate <= to }
            .sorted { $0.localDate < $1.localDate }
    }

    public func checkIn(id: UUID) async throws -> CheckIn? { storage[id] }

    public func save(_ checkIn: CheckIn) async throws { storage[checkIn.id] = checkIn }

    public func delete(id: UUID) async throws { storage[id] = nil }
}
