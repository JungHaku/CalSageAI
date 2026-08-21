import CalKit
import Foundation
import SwiftData

/// Persistence for journal entries (`PLAN-journal.md`).
public protocol JournalStoring: Sendable {
    func entries(from: LocalDate, to: LocalDate) async throws -> [JournalEntry]
    func entry(id: UUID) async throws -> JournalEntry?
    func save(_ entry: JournalEntry) async throws
    func delete(id: UUID) async throws
    func purgeAll() async throws
}

@Model
public final class StoredJournalEntry {
    public var id: UUID = UUID()
    public var localDateISO: String = ""
    public var body: String = ""
    public var promptID: String?
    public var createdAt: Date = Date(timeIntervalSince1970: 0)
    public var updatedAt: Date = Date(timeIntervalSince1970: 0)
    public var isDirty: Bool = true

    public init(
        id: UUID,
        localDateISO: String,
        body: String,
        promptID: String?,
        createdAt: Date,
        updatedAt: Date,
        isDirty: Bool
    ) {
        self.id = id
        self.localDateISO = localDateISO
        self.body = body
        self.promptID = promptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }

    func toDomain() throws -> JournalEntry {
        guard let localDate = LocalDate(iso: localDateISO) else {
            throw StoreMappingError.malformedLocalDate(localDateISO)
        }
        return JournalEntry(
            id: id,
            localDate: localDate,
            body: body,
            promptID: promptID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

@ModelActor
public actor SwiftDataJournalStore: JournalStoring {
    public func entries(from: LocalDate, to: LocalDate) async throws -> [JournalEntry] {
        let lower = from.iso
        let upper = to.iso
        let descriptor = FetchDescriptor<StoredJournalEntry>(
            predicate: #Predicate { $0.localDateISO >= lower && $0.localDateISO <= upper },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    public func entry(id: UUID) async throws -> JournalEntry? {
        try fetchStored(id: id)?.toDomain()
    }

    public func save(_ entry: JournalEntry) async throws {
        let id = entry.id
        if let existing = try fetchStored(id: id) {
            // Local body always wins on device. Sync must not call this with a
            // remote body over an unsynced dirty row (ARCHITECTURE.md §15).
            existing.body = entry.body
            existing.promptID = entry.promptID
            existing.localDateISO = entry.localDate.iso
            existing.updatedAt = entry.updatedAt
            existing.isDirty = true
        } else {
            modelContext.insert(
                StoredJournalEntry(
                    id: entry.id,
                    localDateISO: entry.localDate.iso,
                    body: entry.body,
                    promptID: entry.promptID,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    isDirty: true
                )
            )
        }
        try modelContext.save()
    }

    public func delete(id: UUID) async throws {
        guard let existing = try fetchStored(id: id) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    public func purgeAll() async throws {
        try modelContext.delete(model: StoredJournalEntry.self)
        try modelContext.save()
    }

    private func fetchStored(id: UUID) throws -> StoredJournalEntry? {
        try modelContext.fetch(
            FetchDescriptor<StoredJournalEntry>(predicate: #Predicate { $0.id == id })
        ).first
    }
}

/// In-memory store for tests and previews.
public actor InMemoryJournalStore: JournalStoring {
    private var storage: [UUID: JournalEntry] = [:]

    public init(_ seed: [JournalEntry] = []) {
        for entry in seed { storage[entry.id] = entry }
    }

    public func entries(from: LocalDate, to: LocalDate) async throws -> [JournalEntry] {
        storage.values
            .filter { $0.localDate >= from && $0.localDate <= to }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func entry(id: UUID) async throws -> JournalEntry? {
        storage[id]
    }

    public func save(_ entry: JournalEntry) async throws {
        storage[entry.id] = entry
    }

    public func delete(id: UUID) async throws {
        storage[id] = nil
    }

    public func purgeAll() async throws {
        storage.removeAll()
    }
}
