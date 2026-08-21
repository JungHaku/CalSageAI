import CalKit
import Foundation
import SwiftData
import Testing

@testable import CalData

@Suite("JournalStore")
struct JournalStoreTests {
    let today = LocalDate(iso: "2026-07-30")!

    private func store() throws -> SwiftDataJournalStore {
        let container = try SwiftDataCoherenceStore.inMemoryContainer()
        return SwiftDataJournalStore(modelContainer: container)
    }

    @Test("save then load round-trips the body")
    func saveAndLoad() async throws {
        let store = try store()
        let entry = JournalEntry(
            localDate: today,
            body: "What happened: a long walk.",
            promptID: "what-happened"
        )
        try await store.save(entry)
        let loaded = try await store.entry(id: entry.id)
        #expect(loaded?.body == entry.body)
        #expect(loaded?.promptID == "what-happened")
    }

    @Test("upsert updates the body without duplicating")
    func upsert() async throws {
        let store = try store()
        var entry = JournalEntry(localDate: today, body: "Draft")
        try await store.save(entry)
        entry.body = "Finished thought"
        entry.updatedAt = Date()
        try await store.save(entry)
        let all = try await store.entries(from: today, to: today)
        #expect(all.count == 1)
        #expect(all.first?.body == "Finished thought")
    }

    @Test("delete removes the row")
    func delete() async throws {
        let store = try store()
        let entry = JournalEntry(localDate: today, body: "Temporary")
        try await store.save(entry)
        try await store.delete(id: entry.id)
        #expect(try await store.entry(id: entry.id) == nil)
    }

    @Test("in-memory store matches the protocol")
    func inMemory() async throws {
        let store = InMemoryJournalStore()
        let entry = JournalEntry(localDate: today, body: "Hello")
        try await store.save(entry)
        #expect(try await store.entries(from: today, to: today).count == 1)
        try await store.purgeAll()
        #expect(try await store.entries(from: today, to: today).isEmpty)
    }
}
