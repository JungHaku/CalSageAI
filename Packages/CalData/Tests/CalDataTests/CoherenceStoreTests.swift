import CalKit
import Foundation
import Testing

@testable import CalData

@Suite("InMemoryCoherenceStore")
struct CoherenceStoreTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    @Test("save then read back by id")
    func roundTrip() async throws {
        let store = InMemoryCoherenceStore()
        let checkIn = CheckIn.fixture(band: .moderate)
        try await store.save(checkIn)
        #expect(try await store.checkIn(id: checkIn.id)?.id == checkIn.id)
    }

    @Test("range queries are inclusive on both ends and sorted by day")
    func rangeQuery() async throws {
        let today = LocalDate(iso: "2026-07-29")!
        let history = CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: calendar)
        let store = InMemoryCoherenceStore(history)

        let all = try await store.checkIns(from: today.adding(days: -9, in: calendar), to: today)
        #expect(all.count == 10)
        #expect(all.map(\.localDate) == all.map(\.localDate).sorted())

        let justToday = try await store.checkIns(from: today, to: today)
        #expect(justToday.count == 1)
        #expect(justToday.first?.localDate == today)
    }

    @Test("the recent(days:) helper spans exactly that many days, inclusive of today")
    func recentWindow() async throws {
        let today = LocalDate(iso: "2026-07-29")!
        let store = InMemoryCoherenceStore(
            CheckIn.syntheticHistory(days: 30, endingOn: today, calendar: calendar)
        )
        let week = try await store.recent(days: 7, today: today, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.last?.localDate == today)
        #expect(week.first?.localDate == today.adding(days: -6, in: calendar))
    }

    @Test("saving the same id twice updates rather than duplicating")
    func saveIsUpsert() async throws {
        let store = InMemoryCoherenceStore()
        var checkIn = CheckIn.fixture(band: .low, regulated: false)
        try await store.save(checkIn)

        checkIn.scores[0].after = Score(clamping: 8)
        try await store.save(checkIn)

        let today = checkIn.localDate
        #expect(try await store.checkIns(from: today, to: today).count == 1)
        #expect(try await store.checkIn(id: checkIn.id)?.scores[0].after?.value == 8)
    }

    @Test("delete removes the row")
    func delete() async throws {
        let store = InMemoryCoherenceStore()
        let checkIn = CheckIn.fixture(band: .high)
        try await store.save(checkIn)
        try await store.delete(id: checkIn.id)
        #expect(try await store.checkIn(id: checkIn.id) == nil)
    }
}
