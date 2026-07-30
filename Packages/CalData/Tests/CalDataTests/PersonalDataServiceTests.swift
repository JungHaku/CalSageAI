import CalKit
import Foundation
import SwiftData
import Testing

@testable import CalData

@Suite("PersonalDataService")
struct PersonalDataServiceTests {
    let today = LocalDate(iso: "2026-07-30")!
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func makeStack() throws -> (
        PersonalDataService,
        SwiftDataCoherenceStore,
        SwiftDataProfileStore,
        SwiftDataPracticeSessionStore
    ) {
        let container = try SwiftDataCoherenceStore.inMemoryContainer()
        let checkIns = SwiftDataCoherenceStore(modelContainer: container)
        let profiles = SwiftDataProfileStore(modelContainer: container)
        let sessions = SwiftDataPracticeSessionStore(modelContainer: container)
        return (
            PersonalDataService(checkIns: checkIns, profiles: profiles, sessions: sessions),
            checkIns, profiles, sessions
        )
    }

    private func seed(
        _ checkIns: SwiftDataCoherenceStore,
        _ profiles: SwiftDataProfileStore,
        _ sessions: SwiftDataPracticeSessionStore
    ) async throws {
        try await profiles.save(Profile(displayName: "Cal Tester", major: "MCB"))
        for checkIn in CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: calendar) {
            try await checkIns.save(checkIn)
        }
        var session = PracticeSession(
            exerciseSlug: "presence-of-light", localDate: today, startedAt: Date()
        )
        session.finish(at: Date())
        try await sessions.save(session)
    }

    @Test("an export gathers all three stores")
    func exportsEverything() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)

        let archive = try await service.export(today: today, calendar: calendar)
        #expect(archive.profile?.displayName == "Cal Tester")
        #expect(archive.checkIns.count == 10)
        #expect(archive.practiceSessions.count == 1)
        #expect(!archive.isEmpty)
    }

    @Test("an export on a fresh install is empty rather than an error")
    func exportsEmpty() async throws {
        let (service, _, _, _) = try makeStack()
        let archive = try await service.export(today: today, calendar: calendar)
        #expect(archive.isEmpty)
        #expect(try archive.jsonData().count > 0, "an empty archive still produces a valid file")
    }

    // An export that silently truncates old history is a worse failure than a
    // slow one — the window has to cover everything the store can hold.
    @Test("very old and future-dated entries are still exported")
    func exportWindowCoversEverything() async throws {
        let (service, checkIns, _, _) = try makeStack()
        try await checkIns.save(CheckIn.fixture(band: .high, on: LocalDate(iso: "2021-03-04")!))
        try await checkIns.save(CheckIn.fixture(band: .high, on: LocalDate(iso: "2026-09-01")!))

        let archive = try await service.export(today: today, calendar: calendar)
        #expect(archive.checkIns.count == 2, "the export window must not truncate history")
    }

    @Test("the exported archive is valid JSON that decodes back")
    func exportIsValidJSON() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)

        let archive = try await service.export(today: today, calendar: calendar)
        let decoded = try ExportArchive.decode(from: try archive.jsonData())
        #expect(decoded.checkIns.count == archive.checkIns.count)
        #expect(decoded.practiceSessions.count == archive.practiceSessions.count)
    }

    // MARK: Deletion

    /// The point of the whole feature. If any store survives, "delete my data"
    /// is a false claim.
    @Test("delete erases every store, leaving nothing behind")
    func deleteErasesEverything() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)

        try await service.deleteEverything()

        #expect(try await profiles.current() == nil)
        #expect(try await checkIns.checkIns(from: LocalDate(iso: "2000-01-01")!, to: today).isEmpty)
        #expect(try await sessions.sessions(forExercise: "presence-of-light").isEmpty)

        // The strongest check: a fresh export finds nothing.
        #expect(try await service.export(today: today, calendar: calendar).isEmpty)
    }

    // Hard deletes, not tombstones. A `deletedAt` flag keeps the contents on disk,
    // which is the wrong reading of "delete my data".
    @Test("deletion is a hard delete — nothing is left tombstoned")
    func deleteIsNotATombstone() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)

        try await service.deleteEverything()

        #expect(
            try await checkIns.pendingSyncCount() == 0,
            "a tombstoned row would still be counted as pending"
        )
    }

    @Test("deleting twice is safe")
    func deleteIsIdempotent() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)

        try await service.deleteEverything()
        try await service.deleteEverything()
        #expect(try await service.export(today: today, calendar: calendar).isEmpty)
    }

    @Test("deleting on a fresh install is a no-op rather than an error")
    func deleteOnEmptyStore() async throws {
        let (service, _, _, _) = try makeStack()
        try await service.deleteEverything()
    }

    @Test("the app is usable again after deletion")
    func usableAfterDelete() async throws {
        let (service, checkIns, profiles, sessions) = try makeStack()
        try await seed(checkIns, profiles, sessions)
        try await service.deleteEverything()

        // A new identity mints cleanly, so the student can just carry on.
        let identity = LocalIdentity(profiles: profiles)
        let newID = try await identity.currentProfileID()
        #expect(try await profiles.current()?.id == newID)

        try await checkIns.save(CheckIn.fixture(band: .high, on: today))
        #expect(try await checkIns.checkIns(from: today, to: today).count == 1)
    }
}
