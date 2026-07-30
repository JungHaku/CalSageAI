import CalKit
import Foundation
import SwiftData

/// Persistence for guided-practice runs.
public protocol PracticeSessionStoring: Sendable {
    func sessions(from: LocalDate, to: LocalDate) async throws -> [PracticeSession]
    func sessions(forExercise slug: String) async throws -> [PracticeSession]
    func save(_ session: PracticeSession) async throws
    func purgeAll() async throws
}

@Model
public final class StoredPracticeSession {
    #Unique<StoredPracticeSession>([\.id])
    public var id: UUID = UUID()

    public var exerciseSlug: String = ""
    public var localDateISO: String = ""
    public var startedAt: Date = Date(timeIntervalSince1970: 0)
    public var completedAt: Date?
    public var progress: Double = 0
    /// Links a regulation run back to the check-in it belongs to, so the weekly
    /// review can eventually answer "most effective regulation exercises".
    public var checkInID: UUID?

    // Same sync bookkeeping as everything else (§2).
    public var updatedAt: Date = Date(timeIntervalSince1970: 0)
    public var isDirty: Bool = true

    public init(
        id: UUID,
        exerciseSlug: String,
        localDateISO: String,
        startedAt: Date,
        completedAt: Date?,
        progress: Double,
        checkInID: UUID?,
        updatedAt: Date,
        isDirty: Bool
    ) {
        self.id = id
        self.exerciseSlug = exerciseSlug
        self.localDateISO = localDateISO
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.progress = progress
        self.checkInID = checkInID
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }

    func toDomain() throws -> PracticeSession {
        guard let localDate = LocalDate(iso: localDateISO) else {
            throw StoreMappingError.malformedLocalDate(localDateISO)
        }
        return PracticeSession(
            id: id,
            exerciseSlug: exerciseSlug,
            localDate: localDate,
            startedAt: startedAt,
            completedAt: completedAt,
            progress: progress,
            checkInID: checkInID
        )
    }
}

@ModelActor
public actor SwiftDataPracticeSessionStore: PracticeSessionStoring {
    public func sessions(from: LocalDate, to: LocalDate) async throws -> [PracticeSession] {
        let lower = from.iso
        let upper = to.iso
        let descriptor = FetchDescriptor<StoredPracticeSession>(
            predicate: #Predicate { $0.localDateISO >= lower && $0.localDateISO <= upper },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    public func sessions(forExercise slug: String) async throws -> [PracticeSession] {
        let descriptor = FetchDescriptor<StoredPracticeSession>(
            predicate: #Predicate { $0.exerciseSlug == slug },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.toDomain() }
    }

    /// Upsert. Called twice per run — once when playback starts and once when it
    /// ends — so an abandoned session still leaves a row with its progress, which
    /// is the signal that matters for pacing.
    public func save(_ session: PracticeSession) async throws {
        let id = session.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredPracticeSession>(predicate: #Predicate { $0.id == id })
        ).first

        if let existing {
            existing.completedAt = session.completedAt
            existing.progress = session.progress
            existing.checkInID = session.checkInID
            existing.updatedAt = Date()
            existing.isDirty = true
        } else {
            modelContext.insert(
                StoredPracticeSession(
                    id: session.id,
                    exerciseSlug: session.exerciseSlug,
                    localDateISO: session.localDate.iso,
                    startedAt: session.startedAt,
                    completedAt: session.completedAt,
                    progress: session.progress,
                    checkInID: session.checkInID,
                    updatedAt: Date(),
                    isDirty: true
                )
            )
        }
        try modelContext.save()
    }

    public func purgeAll() async throws {
        try modelContext.delete(model: StoredPracticeSession.self)
        try modelContext.save()
    }
}

/// In-memory store for tests and previews.
public actor InMemoryPracticeSessionStore: PracticeSessionStoring {
    private var sessions: [UUID: PracticeSession] = [:]

    public init(_ seed: [PracticeSession] = []) {
        for session in seed { sessions[session.id] = session }
    }

    public func sessions(from: LocalDate, to: LocalDate) async throws -> [PracticeSession] {
        sessions.values
            .filter { $0.localDate >= from && $0.localDate <= to }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func sessions(forExercise slug: String) async throws -> [PracticeSession] {
        sessions.values
            .filter { $0.exerciseSlug == slug }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func save(_ session: PracticeSession) async throws {
        sessions[session.id] = session
    }

    public func purgeAll() async throws {
        sessions.removeAll()
    }
}
