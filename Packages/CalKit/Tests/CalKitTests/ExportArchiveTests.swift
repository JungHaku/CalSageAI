import Foundation
import Testing

@testable import CalKit

@Suite("ExportArchive")
struct ExportArchiveTests {
    let generatedAt = Date(timeIntervalSince1970: 1_785_000_000)
    let today = LocalDate(iso: "2026-07-30")!
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func archive(
        profile: Profile? = Profile(displayName: "Cal Tester"),
        checkIns: [CheckIn]? = nil,
        sessions: [PracticeSession]? = nil
    ) -> ExportArchive {
        ExportArchive(
            generatedAt: generatedAt,
            profile: profile,
            checkIns: checkIns ?? CheckIn.syntheticHistory(days: 5, endingOn: today, calendar: calendar),
            practiceSessions: sessions ?? [
                PracticeSession(
                    exerciseSlug: "presence-of-light", localDate: today, startedAt: generatedAt
                )
            ]
        )
    }

    @Test("an empty archive is recognisable as empty")
    func emptyArchive() {
        let empty = ExportArchive(
            generatedAt: generatedAt, profile: nil, checkIns: [], practiceSessions: []
        )
        #expect(empty.isEmpty)
        #expect(!archive().isEmpty)
    }

    /// Dates round-trip to millisecond precision, not exactly — see
    /// `ExportArchive.makeDateFormatter`. Everything else must be identical.
    @Test("it round-trips through JSON, to the archive's stated millisecond precision")
    func roundTrip() throws {
        let original = archive()
        let decoded = try ExportArchive.decode(from: try original.jsonData())

        #expect(decoded.formatVersion == ExportArchive.currentFormatVersion)
        #expect(abs(decoded.generatedAt.timeIntervalSince(original.generatedAt)) < 0.001)
        #expect(decoded.checkIns == original.checkIns)
        #expect(decoded.practiceSessions == original.practiceSessions)

        let profile = try #require(decoded.profile)
        let source = try #require(original.profile)
        #expect(profile.id == source.id)
        #expect(profile.displayName == source.displayName)
        #expect(profile.reminder == source.reminder)
        #expect(abs(profile.createdAt.timeIntervalSince(source.createdAt)) < 0.001)
    }

    @Test("the stated millisecond precision actually holds")
    func millisecondPrecision() throws {
        // A timestamp with deliberate sub-millisecond detail.
        let precise = Date(timeIntervalSince1970: 1_785_000_000.123_456_7)
        let decoded = try ExportArchive.decode(
            from: try ExportArchive(
                generatedAt: precise, profile: nil, checkIns: [], practiceSessions: []
            ).jsonData()
        )
        let drift = abs(decoded.generatedAt.timeIntervalSince(precise))
        #expect(drift < 0.001, "drifted \(drift)s — worse than the documented millisecond floor")
    }

    // An export that quietly drops a store is a false claim, not a simplification.
    // If a new store is added, this fails until the archive carries it.
    @Test("the archive carries every store the app writes to")
    func coversEveryStore() throws {
        let json = try archive().jsonData()
        let object = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        #expect(
            Set(object.keys) == ["formatVersion", "generatedAt", "app", "profile", "checkIns", "practiceSessions"],
            "archive keys changed: \(object.keys.sorted())"
        )
    }

    @Test("scores survive the round trip, including the unmeasured-vs-zero distinction")
    func preservesScoreSemantics() throws {
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [
            CategoryScore(category: .safety, before: Score(clamping: 9)),
            CategoryScore(category: .breath, before: Score(clamping: 2), after: Score(clamping: 6)),
        ]
        checkIn.completedAt = generatedAt

        let decoded = try ExportArchive.decode(from: try archive(checkIns: [checkIn]).jsonData())
        let restored = try #require(decoded.checkIns.first)
        #expect(restored.scores[0].after == nil, "unmeasured must not export as zero")
        #expect(restored.scores[1].delta == 4)
    }

    @Test("entries are ordered chronologically so the file reads in order")
    func chronological() {
        let scrambled = [
            CheckIn.fixture(band: .high, on: today),
            CheckIn.fixture(band: .high, on: today.adding(days: -5, in: calendar)),
            CheckIn.fixture(band: .high, on: today.adding(days: -2, in: calendar)),
        ]
        let dates = archive(checkIns: scrambled).checkIns.map(\.localDate)
        #expect(dates == dates.sorted())
    }

    // Pretty-printed and key-sorted so a person can open it without tooling and
    // so two exports are diffable.
    @Test("the JSON is human-readable, key-sorted, and uses ISO dates")
    func readableOutput() throws {
        let text = String(decoding: try archive().jsonData(), as: UTF8.self)
        #expect(text.contains("\n"), "should be pretty-printed")
        #expect(text.contains("2026-"), "dates should be ISO-8601, not raw timestamps")
        // Sorted keys: `app` precedes `checkIns` precedes `formatVersion`.
        let appIndex = try #require(text.range(of: "\"app\""))
        let checkInsIndex = try #require(text.range(of: "\"checkIns\""))
        #expect(appIndex.lowerBound < checkInsIndex.lowerBound)
    }

    @Test("the filename is dated, sortable, and safe for Files and Mail")
    func filename() {
        let name = archive().suggestedFilename(on: today)
        #expect(name == "cal-coherence-export-2026-07-30.json")
        #expect(!name.contains(" "))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test("the summary names what's actually in the file")
    func summary() {
        let text = archive().summary
        #expect(text.contains("5 check-ins"))
        #expect(text.contains("1 practice session"))
        #expect(text.contains("your profile"))

        let noProfile = archive(profile: nil, checkIns: [], sessions: []).summary
        #expect(noProfile.contains("0 check-ins"))
        #expect(!noProfile.contains("your profile"))
    }

    @Test("a future format version still decodes, so an old app can read a new file")
    func forwardCompatibleVersion() throws {
        var json = String(decoding: try archive().jsonData(), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        let decoded = try ExportArchive.decode(from: Data(json.utf8))
        #expect(decoded.formatVersion == 99)
    }
}
