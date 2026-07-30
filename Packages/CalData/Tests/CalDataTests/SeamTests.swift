import CalKit
import Foundation
import SwiftData
import Testing

@testable import CalData

@Suite("ProfileStoring")
struct ProfileStoreTests {
    private func makeStore() throws -> SwiftDataProfileStore {
        SwiftDataProfileStore(modelContainer: try SwiftDataCoherenceStore.inMemoryContainer())
    }

    @Test("a fresh store has no profile")
    func emptyInitially() async throws {
        #expect(try await makeStore().current() == nil)
    }

    @Test("a profile round-trips with every field intact")
    func roundTrip() async throws {
        let store = try makeStore()
        let profile = Profile(
            displayName: "Cal Tester",
            major: "Molecular & Cell Biology",
            gradYear: 2028,
            goals: "Sleep more. Panic less.",
            interests: ["climbing", "ceramics"],
            favoriteSpotSlugs: ["moffitt-library"],
            onboardedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        try await store.save(profile)

        let loaded = try #require(try await store.current())
        #expect(loaded == profile)
        #expect(loaded.isOnboarded)
    }

    @Test("saving twice updates in place rather than creating a second profile")
    func saveIsUpsert() async throws {
        let store = try makeStore()
        var profile = Profile(displayName: "First")
        try await store.save(profile)

        profile.displayName = "Second"
        try await store.save(profile)

        let loaded = try #require(try await store.current())
        #expect(loaded.displayName == "Second")
        #expect(loaded.id == profile.id, "the id must be stable — it becomes the server PK")
    }

    @Test("purge removes the profile, since it is identity and not just data")
    func purge() async throws {
        let store = try makeStore()
        try await store.save(Profile(displayName: "Cal Tester"))
        try await store.purge()
        #expect(try await store.current() == nil)
    }
}

@Suite("LocalIdentity")
struct LocalIdentityTests {
    @Test("first call mints a profile; later calls return the same id")
    func stableAcrossCalls() async throws {
        let profiles = InMemoryProfileStore()
        let identity = LocalIdentity(profiles: profiles)

        let first = try await identity.currentProfileID()
        let second = try await identity.currentProfileID()
        #expect(first == second)
        #expect(try await profiles.current()?.id == first)
    }

    // The whole point of §2's claim migration: the id a device mints today is the
    // id the server row will carry after sign-in. If it changed across launches,
    // the first sync would duplicate everything.
    @Test("the id survives a relaunch — a new LocalIdentity over the same store")
    func stableAcrossRelaunch() async throws {
        let profiles = InMemoryProfileStore()
        let first = try await LocalIdentity(profiles: profiles).currentProfileID()
        let second = try await LocalIdentity(profiles: profiles).currentProfileID()
        #expect(first == second)
    }

    @Test("an existing profile is adopted rather than replaced")
    func adoptsExistingProfile() async throws {
        let existing = Profile(displayName: "Already here")
        let identity = LocalIdentity(profiles: InMemoryProfileStore(existing))
        #expect(try await identity.currentProfileID() == existing.id)
    }

    @Test("the MVP is never authenticated — that flag is Phase B's trigger")
    func neverAuthenticated() async {
        #expect(await LocalIdentity(profiles: InMemoryProfileStore()).isAuthenticated == false)
    }
}

@Suite("NoOpSyncEngine")
struct SyncEngineTests {
    let today = LocalDate(iso: "2026-07-30")!

    @Test("sync reports notConfigured rather than pretending to succeed")
    func syncIsHonest() async throws {
        let engine = NoOpSyncEngine { 0 }
        #expect(try await engine.sync() == .notConfigured)
    }

    // Not a silent no-op: a settings screen has to be able to say truthfully that
    // N check-ins exist only on this phone.
    @Test("pendingCount reports real unsynced rows")
    func pendingCountIsReal() async throws {
        let store = SwiftDataCoherenceStore(
            modelContainer: try SwiftDataCoherenceStore.inMemoryContainer()
        )
        let engine = NoOpSyncEngine { try await store.pendingSyncCount() }

        #expect(try await engine.pendingCount() == 0)

        try await store.save(CheckIn.fixture(band: .high, on: today))
        try await store.save(CheckIn.fixture(band: .low, on: LocalDate(iso: "2026-07-29")!))
        #expect(try await engine.pendingCount() == 2)
    }

    // On a device that has never synced, "everything dirty" is the entire history —
    // which is exactly what the Phase B outbox needs on first sign-in.
    @Test("nothing clears isDirty in the MVP, so the outbox is the whole history")
    func everythingStaysDirty() async throws {
        let store = SwiftDataCoherenceStore(
            modelContainer: try SwiftDataCoherenceStore.inMemoryContainer()
        )
        let engine = NoOpSyncEngine { try await store.pendingSyncCount() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for checkIn in CheckIn.syntheticHistory(days: 12, endingOn: today, calendar: calendar) {
            try await store.save(checkIn)
        }

        _ = try await engine.sync()
        #expect(try await engine.pendingCount() == 12, "a no-op sync must not mark anything clean")
    }
}
