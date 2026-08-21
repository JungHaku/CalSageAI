import CalKit
import Foundation
import SwiftData

/// `CoherenceStoring` backed by SwiftData.
///
/// A `@ModelActor`, so all context access is serialised on its own actor and Swift
/// 6's strict concurrency checking is satisfied without passing `ModelContext`
/// across isolation boundaries (which is unsupported and crashes at runtime).
@ModelActor
public actor SwiftDataCoherenceStore: CoherenceStoring {
    /// Rows written locally but not yet pushed. Drives the outbox in §7.
    public func pendingSyncCount() throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<StoredCheckIn>(predicate: #Predicate { $0.isDirty && $0.deletedAt == nil })
        )
    }

    public func checkIns(from: LocalDate, to: LocalDate) async throws -> [CheckIn] {
        // Filtering on the ISO day string works because `YYYY-MM-DD` sorts
        // lexicographically in calendar order — that's why the format is
        // zero-padded rather than something friendlier.
        let lower = from.iso
        let upper = to.iso
        let descriptor = FetchDescriptor<StoredCheckIn>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.localDateISO >= lower && $0.localDateISO <= upper
            },
            sortBy: [SortDescriptor(\.localDateISO), SortDescriptor(\.updatedAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    public func checkIn(id: UUID) async throws -> CheckIn? {
        // Tombstones are filtered here rather than in `fetchStored`, because
        // `save` and `delete` deliberately need to *find* a soft-deleted row —
        // save to resurrect it, delete to avoid re-tombstoning.
        guard let stored = try fetchStored(id: id), stored.deletedAt == nil else { return nil }
        return try stored.toDomain()
    }

    /// Upsert. Called repeatedly during a check-in — once per rating — so that a
    /// backgrounded or crashed app doesn't lose a partly finished session.
    public func save(_ checkIn: CheckIn) async throws {
        let now = Date()

        if let existing = try fetchStored(id: checkIn.id) {
            existing.kindRaw = checkIn.kind.rawValue
            existing.localDateISO = checkIn.localDate.iso
            existing.timeZoneIdentifier = checkIn.timeZoneIdentifier
            existing.completedAt = checkIn.completedAt
            existing.updatedAt = now
            existing.isDirty = true
            existing.deletedAt = nil

            // Scores are replaced wholesale rather than diffed. A check-in has at
            // most 10 of them and they're append-mostly, so a diff would be more
            // code and more bugs for no measurable gain.
            for score in existing.scores { modelContext.delete(score) }
            existing.scores = checkIn.scores.map {
                StoredCategoryScore(
                    categoryRaw: $0.category.rawValue,
                    scoreBefore: $0.before.value,
                    scoreAfter: $0.after?.value,
                    exerciseSlug: $0.exerciseSlug,
                    answeredAt: now
                )
            }
        } else {
            modelContext.insert(checkIn.toStored(updatedAt: now))
        }
        try modelContext.save()
    }

    /// Soft delete. A hard delete would let the row come back on the next pull,
    /// because the server has no way to know it was removed here.
    public func delete(id: UUID) async throws {
        guard let existing = try fetchStored(id: id) else { return }
        existing.deletedAt = Date()
        existing.updatedAt = Date()
        existing.isDirty = true
        try modelContext.save()
    }

    /// Hard delete, for the account-deletion path where the whole store goes (§5.4).
    public func purgeAll() async throws {
        try modelContext.delete(model: StoredCheckIn.self)
        try modelContext.save()
    }

    private func fetchStored(id: UUID) throws -> StoredCheckIn? {
        try modelContext.fetch(
            FetchDescriptor<StoredCheckIn>(predicate: #Predicate { $0.id == id })
        ).first
    }

    // MARK: The outbox (§15 step 5)

    /// Everything waiting to be pushed, tombstones included.
    ///
    /// Tombstones are *not* filtered here, unlike everywhere else in this type.
    /// A deleted row is precisely the thing the server has no other way to learn
    /// about, so `delete` marks it dirty and this hands it over. `PendingCheckIn`
    /// carries `deletedAt` so the engine can tell the two cases apart.
    ///
    /// Returns a snapshot rather than the `@Model` objects: they belong to this
    /// actor's context and cannot cross an isolation boundary.
    public func pendingCheckIns(limit: Int = 500) throws -> [PendingCheckIn] {
        var descriptor = FetchDescriptor<StoredCheckIn>(
            predicate: #Predicate { $0.isDirty },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { stored in
            PendingCheckIn(
                checkIn: try? stored.toDomain(),
                id: stored.id,
                updatedAt: stored.updatedAt,
                deletedAt: stored.deletedAt
            )
        }
    }

    /// Clears the dirty flag for rows the server has accepted.
    ///
    /// Takes ids rather than the rows, and re-reads them, because between the
    /// fetch and the acknowledgement the person may have edited a check-in. It
    /// compares `updatedAt` and leaves anything newer dirty: marking that clean
    /// would drop an edit silently, which is the one sync bug with no recovery.
    public func markSynced(_ acknowledged: [UUID: Date]) throws {
        guard !acknowledged.isEmpty else { return }
        let ids = Set(acknowledged.keys)
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredCheckIn>(predicate: #Predicate { ids.contains($0.id) })
        )
        for row in rows {
            guard let pushedAt = acknowledged[row.id] else { continue }
            // Strictly greater: equal means this is the same version we pushed.
            if row.updatedAt > pushedAt { continue }
            row.isDirty = false
        }
        try modelContext.save()
    }

    /// Applies rows pulled from the server.
    ///
    /// Last-write-wins on `updatedAt`, and a local row that is still dirty always
    /// wins regardless — an unpushed local edit is newer than anything the server
    /// can know about, and losing it would be losing the person's own writing.
    @discardableResult
    public func merge(_ remote: [CheckIn], updatedAt: [UUID: Date]) throws -> Int {
        var applied = 0
        for incoming in remote {
            let existing = try fetchStored(id: incoming.id)
            if let existing {
                if existing.isDirty { continue }
                if let remoteStamp = updatedAt[incoming.id], existing.updatedAt >= remoteStamp {
                    continue
                }
                for score in existing.scores { modelContext.delete(score) }
                modelContext.delete(existing)
            }
            let stored = incoming.toStored(
                updatedAt: updatedAt[incoming.id] ?? Date(), isDirty: false
            )
            modelContext.insert(stored)
            applied += 1
        }
        if applied > 0 { try modelContext.save() }
        return applied
    }
}

/// A check-in waiting to be pushed, detached from SwiftData.
///
/// `checkIn` is `nil` only for a row that cannot be decoded — a tombstone for
/// something never fully written, in practice. The id and the timestamps are
/// always present because a delete has to travel even when the body cannot.
public struct PendingCheckIn: Sendable {
    public let checkIn: CheckIn?
    public let id: UUID
    public let updatedAt: Date
    public let deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(checkIn: CheckIn?, id: UUID, updatedAt: Date, deletedAt: Date?) {
        self.checkIn = checkIn
        self.id = id
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension SwiftDataCoherenceStore {
    /// One schema for the whole app, so the check-in store and the profile store
    /// share a container and a migration story.
    public static let schema = Schema([
        StoredCheckIn.self,
        StoredCategoryScore.self,
        StoredProfile.self,
        StoredPracticeSession.self,
        StoredJournalEntry.self,
    ])

    /// On-disk container for the app.
    public static func container() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
        )
    }

    /// Ephemeral container for tests and previews.
    public static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
