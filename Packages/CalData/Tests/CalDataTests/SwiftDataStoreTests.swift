import CalKit
import Foundation
import SwiftData
import Testing

@testable import CalData

@Suite("SwiftDataCoherenceStore")
struct SwiftDataStoreTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    let today = LocalDate(iso: "2026-07-29")!

    private func makeStore() throws -> SwiftDataCoherenceStore {
        SwiftDataCoherenceStore(modelContainer: try SwiftDataCoherenceStore.inMemoryContainer())
    }

    @Test("a check-in round-trips through SwiftData unchanged")
    func roundTrip() async throws {
        let store = try makeStore()
        let original = CheckIn.fixture(band: .low, on: today, regulated: true)
        try await store.save(original)

        let loaded = try await store.checkIn(id: original.id)
        #expect(loaded?.id == original.id)
        #expect(loaded?.kind == original.kind)
        #expect(loaded?.localDate == original.localDate)
        #expect(loaded?.completedAt == original.completedAt)
        #expect(loaded?.scores.count == original.scores.count)
        #expect(loaded?.scores == original.scores)
    }

    @Test("before/after pairs and derived deltas survive the round trip")
    func preservesBeforeAfter() async throws {
        let store = try makeStore()
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [
            CategoryScore(category: .safety, before: Score(clamping: 9)),
            CategoryScore(category: .breath, before: Score(clamping: 2), after: Score(clamping: 6), exerciseSlug: "x"),
        ]
        checkIn.completedAt = Date(timeIntervalSince1970: 1_785_000_000)
        try await store.save(checkIn)

        let loaded = try #require(try await store.checkIn(id: checkIn.id))
        let breath = try #require(loaded.scores.first { $0.category == .breath })
        #expect(breath.before.value == 2)
        #expect(breath.after?.value == 6)
        #expect(breath.delta == 4)
        #expect(breath.exerciseSlug == "x")

        let safety = try #require(loaded.scores.first { $0.category == .safety })
        #expect(safety.after == nil)
        #expect(safety.delta == nil, "unmeasured must not become zero on the way through the database")
    }

    @Test("categories come back in Dr. Mia's order, not insertion order")
    func restoresCanonicalOrder() async throws {
        let store = try makeStore()
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        // Deliberately scrambled.
        checkIn.scores = [
            CategoryScore(category: .energy, before: Score(clamping: 7)),
            CategoryScore(category: .safety, before: Score(clamping: 7)),
            CategoryScore(category: .presence, before: Score(clamping: 7)),
        ]
        try await store.save(checkIn)

        let loaded = try #require(try await store.checkIn(id: checkIn.id))
        #expect(loaded.scores.map(\.category) == [.safety, .presence, .energy])
    }

    @Test("saving the same id twice updates in place instead of duplicating")
    func saveIsUpsert() async throws {
        let store = try makeStore()
        var checkIn = CheckIn.fixture(band: .low, on: today, regulated: false)
        try await store.save(checkIn)

        checkIn.scores[0].after = Score(clamping: 8)
        checkIn.completedAt = Date(timeIntervalSince1970: 1_785_000_100)
        try await store.save(checkIn)

        #expect(try await store.checkIns(from: today, to: today).count == 1)
        let loaded = try #require(try await store.checkIn(id: checkIn.id))
        #expect(loaded.scores[0].after?.value == 8)
        #expect(loaded.isComplete)
    }

    // Repeated saves are how an in-progress check-in survives a crash, so the
    // score rows must not accumulate each time.
    @Test("repeated saves don't leak score rows")
    func repeatedSavesDoNotLeakScores() async throws {
        let store = try makeStore()
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")

        for category in CoherenceCategory.fullCheckIn {
            checkIn.scores.append(CategoryScore(category: category, before: Score(clamping: 6)))
            try await store.save(checkIn)
        }

        let loaded = try #require(try await store.checkIn(id: checkIn.id))
        #expect(loaded.scores.count == 5)
    }

    @Test("range queries are inclusive and exclude days outside the window")
    func rangeQuery() async throws {
        let store = try makeStore()
        for checkIn in CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: calendar) {
            try await store.save(checkIn)
        }

        #expect(try await store.checkIns(from: today, to: today).count == 1)
        #expect(try await store.recent(days: 7, today: today, calendar: calendar).count == 7)
        #expect(try await store.checkIns(from: today.adding(days: -9, in: calendar), to: today).count == 10)

        let future = today.adding(days: 1, in: calendar)
        #expect(try await store.checkIns(from: future, to: future).isEmpty)
    }

    @Test("range results are ordered oldest to newest, for charting")
    func rangeIsOrdered() async throws {
        let store = try makeStore()
        // Insert in reverse so ordering can't come from insertion order.
        for checkIn in CheckIn.syntheticHistory(days: 5, endingOn: today, calendar: calendar).reversed() {
            try await store.save(checkIn)
        }
        let loaded = try await store.recent(days: 5, today: today, calendar: calendar)
        #expect(loaded.map(\.localDate) == loaded.map(\.localDate).sorted())
    }

    // MARK: Sync bookkeeping (§7)

    @Test("new rows are dirty so the outbox picks them up")
    func newRowsAreDirty() async throws {
        let store = try makeStore()
        #expect(try await store.pendingSyncCount() == 0)
        try await store.save(CheckIn.fixture(band: .high, on: today))
        #expect(try await store.pendingSyncCount() == 1)
    }

    // A hard delete would let the row reappear on the next pull, because the
    // server has no way to know it was removed locally.
    @Test("delete is a soft delete: hidden from reads, still tracked for sync")
    func deleteIsSoft() async throws {
        let store = try makeStore()
        let checkIn = CheckIn.fixture(band: .high, on: today)
        try await store.save(checkIn)
        try await store.delete(id: checkIn.id)

        #expect(try await store.checkIn(id: checkIn.id) == nil)
        #expect(try await store.checkIns(from: today, to: today).isEmpty)
        #expect(try await store.pendingSyncCount() == 0, "deleted rows aren't pending creation")
    }

    @Test("re-saving a deleted id resurrects it, so an id can be reused after an undo")
    func resaveClearsTombstone() async throws {
        let store = try makeStore()
        let checkIn = CheckIn.fixture(band: .high, on: today)
        try await store.save(checkIn)
        try await store.delete(id: checkIn.id)
        try await store.save(checkIn)

        #expect(try await store.checkIn(id: checkIn.id) != nil)
    }

    @Test("deleting an unknown id is a no-op rather than an error")
    func deleteUnknown() async throws {
        let store = try makeStore()
        try await store.delete(id: UUID())
        #expect(try await store.checkIns(from: today, to: today).isEmpty)
    }

    @Test("purgeAll empties the store, for account deletion")
    func purge() async throws {
        let store = try makeStore()
        for checkIn in CheckIn.syntheticHistory(days: 5, endingOn: today, calendar: calendar) {
            try await store.save(checkIn)
        }
        try await store.purgeAll()
        #expect(try await store.checkIns(from: today.adding(days: -30, in: calendar), to: today).isEmpty)
    }

    // MARK: Mapping failures

    // Coercing a bad row to a default would quietly corrupt the averages, so the
    // mapping throws instead.
    @Test("a row with a drifted enum or an out-of-range score throws rather than coercing")
    func mappingRejectsCorruptRows() throws {
        let bad = StoredCheckIn(
            id: UUID(), kindRaw: "telepathy", localDateISO: "2026-07-29",
            timeZoneIdentifier: "America/Los_Angeles", completedAt: nil,
            updatedAt: .now, isDirty: false
        )
        #expect(throws: StoreMappingError.unknownKind("telepathy")) { try bad.toDomain() }

        let badDate = StoredCheckIn(
            id: UUID(), kindRaw: "full", localDateISO: "not-a-date",
            timeZoneIdentifier: "America/Los_Angeles", completedAt: nil,
            updatedAt: .now, isDirty: false
        )
        #expect(throws: StoreMappingError.malformedLocalDate("not-a-date")) { try badDate.toDomain() }

        let badScore = StoredCategoryScore(
            categoryRaw: "breath", scoreBefore: 42, scoreAfter: nil, exerciseSlug: nil, answeredAt: .now
        )
        #expect(throws: StoreMappingError.scoreOutOfRange(42)) { try badScore.toDomain() }

        let badCategory = StoredCategoryScore(
            categoryRaw: "vibes", scoreBefore: 5, scoreAfter: nil, exerciseSlug: nil, answeredAt: .now
        )
        #expect(throws: StoreMappingError.unknownCategory("vibes")) { try badCategory.toDomain() }
    }
}
