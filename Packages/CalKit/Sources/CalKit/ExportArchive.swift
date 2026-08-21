import Foundation

/// Everything the app holds about one person, in one file.
///
/// Two rules shape this:
///
/// 1. **It must be complete.** An "export my data" that quietly omits practice
///    sessions is a false claim, not a simplification. Every store the app writes
///    to appears here, and there's a test asserting the archive's key set matches
///    the stores that exist.
/// 2. **It mirrors the database shape.** The same field names as the Postgres
///    tables in `supabase/migrations/`, so an export taken today is still
///    meaningful after Phase B — and so a future import path has something
///    predictable to read.
public struct ExportArchive: Codable, Sendable, Equatable {
    /// Bumped when the shape changes, so a reader can tell what it's holding.
    public let formatVersion: Int
    public let generatedAt: Date
    public let app: String

    public let profile: Profile?
    public let checkIns: [CheckIn]
    public let practiceSessions: [PracticeSession]
    public let journalEntries: [JournalEntry]

    /// v2 adds `journalEntries`. Readers must tolerate missing keys from v1 files.
    public static let currentFormatVersion = 2

    public init(
        generatedAt: Date,
        profile: Profile?,
        checkIns: [CheckIn],
        practiceSessions: [PracticeSession],
        journalEntries: [JournalEntry] = [],
        formatVersion: Int = ExportArchive.currentFormatVersion,
        app: String = "C.A.L Coherence"
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.app = app
        self.profile = profile
        // Oldest first, so the file reads chronologically rather than in
        // whatever order the store happened to return.
        self.checkIns = checkIns.sorted { $0.localDate < $1.localDate }
        self.practiceSessions = practiceSessions.sorted { $0.startedAt < $1.startedAt }
        self.journalEntries = journalEntries.sorted { $0.createdAt < $1.createdAt }
    }

    public var isEmpty: Bool {
        profile == nil
            && checkIns.isEmpty
            && practiceSessions.isEmpty
            && journalEntries.isEmpty
    }

    /// ISO-8601 **with fractional seconds** — millisecond precision.
    ///
    /// Foundation's stock `.iso8601` strategy truncates to whole seconds, which is
    /// a strange thing for a data export to do silently. Fractional seconds get
    /// this to milliseconds, which is the precision the archive guarantees.
    ///
    /// It is deliberately not exact: `Date` is finer than a millisecond, so a
    /// round trip is lossy in the last few digits. Encoding raw `Double`
    /// timestamps would be exact but unreadable, and nothing in this app resolves
    /// time below a millisecond — a readable file is worth more than the last
    /// three decimal places.
    /// Built per call rather than shared: `ISO8601DateFormatter` is a class and
    /// isn't `Sendable`, so a `static let` fails Swift 6 concurrency checking.
    /// Construction is cheap next to encoding an entire archive.
    static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Pretty-printed with sorted keys and ISO-8601 dates.
    ///
    /// All three matter for a file a person might actually open: pretty-printing
    /// makes it readable without tooling, sorted keys make two exports diffable,
    /// and ISO dates are unambiguous where a raw `Double` timestamp is not.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let formatter = Self.makeDateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> ExportArchive {
        let decoder = JSONDecoder()
        let formatter = makeDateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad date: \(text)")
                )
            }
            return date
        }
        return try decoder.decode(ExportArchive.self, from: data)
    }

    /// A dated, sortable filename with no characters that trip up Files, Mail or
    /// AirDrop.
    public func suggestedFilename(on day: LocalDate) -> String {
        "cal-coherence-export-\(day.iso).json"
    }

    /// A short human summary, for confirming what's about to be shared.
    public var summary: String {
        var parts: [String] = []
        parts.append("\(checkIns.count) check-in\(checkIns.count == 1 ? "" : "s")")
        parts.append("\(practiceSessions.count) practice session\(practiceSessions.count == 1 ? "" : "s")")
        parts.append("\(journalEntries.count) journal entr\(journalEntries.count == 1 ? "y" : "ies")")
        if profile != nil { parts.append("your profile") }
        return parts.formatted(.list(type: .and))
    }

    // v1 archives omit `journalEntries`. Treat a missing key as empty so an old
    // export still opens rather than failing the whole read.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, generatedAt, app, profile, checkIns, practiceSessions, journalEntries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        app = try container.decode(String.self, forKey: .app)
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile)
        checkIns = try container.decode([CheckIn].self, forKey: .checkIns)
        practiceSessions = try container.decode([PracticeSession].self, forKey: .practiceSessions)
        journalEntries = try container.decodeIfPresent([JournalEntry].self, forKey: .journalEntries) ?? []
    }
}
