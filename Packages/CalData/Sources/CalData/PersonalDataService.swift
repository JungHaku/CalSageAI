import CalKit
import Foundation

/// Gathers everything the app holds about one person, and erases it.
///
/// Both operations exist in one place on purpose: they have to agree about what
/// "everything" means. An export that reads three stores and a delete that clears
/// two is the kind of divergence nobody notices until it matters.
public struct PersonalDataService: Sendable {
    private let checkIns: any CoherenceStoring
    private let profiles: any ProfileStoring
    private let sessions: any PracticeSessionStoring
    private let journal: any JournalStoring
    private let remoteMemory: any RemoteMemoryControlling

    public init(
        checkIns: any CoherenceStoring,
        profiles: any ProfileStoring,
        sessions: any PracticeSessionStoring,
        journal: any JournalStoring,
        remoteMemory: any RemoteMemoryControlling = NoOpRemoteMemory()
    ) {
        self.checkIns = checkIns
        self.profiles = profiles
        self.sessions = sessions
        self.journal = journal
        self.remoteMemory = remoteMemory
    }

    /// Everything, as one archive.
    ///
    /// The window is deliberately enormous rather than "the last year": an export
    /// that silently truncates old history is a worse failure than a slow one.
    public func export(today: LocalDate, calendar: Calendar) async throws -> ExportArchive {
        let start = LocalDate(year: 2000, month: 1, day: 1)
        // A far-future end date, so a check-in written by a device with a skewed
        // clock still comes out rather than being invisibly dropped.
        let end = today.adding(days: 365, in: calendar)

        return ExportArchive(
            generatedAt: Date(),
            profile: try await profiles.current(),
            checkIns: try await checkIns.checkIns(from: start, to: end),
            practiceSessions: try await sessions.sessions(from: start, to: end),
            journalEntries: try await journal.entries(from: start, to: end)
        )
    }

    /// Erases every store.
    ///
    /// Hard deletes, not tombstones. A tombstone is for telling a *server* that a
    /// row went away; when the person has asked for their data to be gone, leaving
    /// the contents on disk under a `deletedAt` flag would be exactly the wrong
    /// reading of the request.
    ///
    /// Ordering matters: check-ins, sessions, and journal first, profile last. The
    /// profile is the identity everything hangs off, so if this is interrupted the
    /// result is an empty profile rather than orphaned health data with no owner.
    public func deleteEverything() async throws {
        try await checkIns.purgeAll()
        try await sessions.purgeAll()
        try await journal.purgeAll()
        try await remoteMemory.forgetAll()
        try await remoteMemory.persistConsent(granted: false)
        try await profiles.purge()
    }
}
