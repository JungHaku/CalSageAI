import CalKit
import Foundation
import SwiftData
import Testing

@testable import CalData

@Suite("SwiftDataPracticeSessionStore")
struct PracticeSessionStoreTests {
    let day = LocalDate(iso: "2026-07-30")!
    let start = Date(timeIntervalSince1970: 1_785_000_000)

    private func makeStore() throws -> SwiftDataPracticeSessionStore {
        SwiftDataPracticeSessionStore(modelContainer: try SwiftDataCoherenceStore.inMemoryContainer())
    }

    private func session(
        _ slug: String = "presence-of-light",
        on date: LocalDate? = nil,
        checkIn: UUID? = nil
    ) -> PracticeSession {
        PracticeSession(
            exerciseSlug: slug,
            localDate: date ?? day,
            startedAt: start,
            checkInID: checkIn
        )
    }

    @Test("a session round-trips with its link and progress intact")
    func roundTrip() async throws {
        let store = try makeStore()
        let checkInID = UUID()
        var s = session(checkIn: checkInID)
        s.finish(at: start.addingTimeInterval(82))
        try await store.save(s)

        let loaded = try #require(try await store.sessions(forExercise: "presence-of-light").first)
        #expect(loaded == s)
        #expect(loaded.checkInID == checkInID)
        #expect(loaded.wasCompleted)
    }

    // Saved once on start and again on finish — an abandoned run must leave one
    // row carrying how far the student actually got.
    @Test("saving twice updates in place and preserves abandonment progress")
    func saveIsUpsert() async throws {
        let store = try makeStore()
        var s = session()
        try await store.save(s)

        s.abandon(atProgress: 0.37)
        try await store.save(s)

        let all = try await store.sessions(forExercise: "presence-of-light")
        #expect(all.count == 1)
        #expect(!all[0].wasCompleted)
        #expect(abs(all[0].progress - 0.37) < 0.0001)
    }

    @Test("date-range queries are inclusive and ordered by start time")
    func rangeQuery() async throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        for offset in 0..<5 {
            let d = day.adding(days: -offset, in: calendar)
            var s = PracticeSession(
                exerciseSlug: "presence-of-light",
                localDate: d,
                startedAt: start.addingTimeInterval(Double(-offset) * 86_400)
            )
            s.finish(at: s.startedAt.addingTimeInterval(82))
            try await store.save(s)
        }

        let all = try await store.sessions(from: day.adding(days: -4, in: calendar), to: day)
        #expect(all.count == 5)
        #expect(all.map(\.startedAt) == all.map(\.startedAt).sorted())

        #expect(try await store.sessions(from: day, to: day).count == 1)
        let future = day.adding(days: 1, in: calendar)
        #expect(try await store.sessions(from: future, to: future).isEmpty)
    }

    @Test("filtering by exercise doesn't leak other practices")
    func filterByExercise() async throws {
        let store = try makeStore()
        try await store.save(session("presence-of-light"))
        try await store.save(session("solar-plexus-light"))
        try await store.save(session("solar-plexus-light"))

        #expect(try await store.sessions(forExercise: "presence-of-light").count == 1)
        #expect(try await store.sessions(forExercise: "solar-plexus-light").count == 2)
        #expect(try await store.sessions(forExercise: "nothing").isEmpty)
    }

    @Test("a malformed stored date throws rather than coercing to today")
    func rejectsCorruptDate() throws {
        let bad = StoredPracticeSession(
            id: UUID(), exerciseSlug: "x", localDateISO: "not-a-date",
            startedAt: start, completedAt: nil, progress: 0, checkInID: nil,
            updatedAt: start, isDirty: true
        )
        #expect(throws: StoreMappingError.malformedLocalDate("not-a-date")) { try bad.toDomain() }
    }

    @Test("purgeAll empties the store, for account deletion")
    func purge() async throws {
        let store = try makeStore()
        try await store.save(session())
        try await store.purgeAll()
        #expect(try await store.sessions(forExercise: "presence-of-light").isEmpty)
    }

    @Test("the in-memory store behaves the same, so previews match the device")
    func inMemoryParity() async throws {
        let store = InMemoryPracticeSessionStore()
        var s = session()
        try await store.save(s)
        s.finish(at: start.addingTimeInterval(82))
        try await store.save(s)

        let all = try await store.sessions(forExercise: "presence-of-light")
        #expect(all.count == 1)
        #expect(all[0].wasCompleted)
    }
}
