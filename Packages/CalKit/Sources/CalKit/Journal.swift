import Foundation

/// One journal entry the student wrote.
///
/// Free text only in this pass — AI reflection is deferred (`PLAN-journal.md`).
/// Sync must never silently overwrite an unsynced local body (ARCHITECTURE.md §15);
/// the store upserts by id and leaves conflict policy to the sync engine.
public struct JournalEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let localDate: LocalDate
    public var body: String
    /// Seed prompt id when this started from a guided prompt; `nil` for free write.
    public var promptID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        localDate: LocalDate,
        body: String = "",
        promptID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.localDate = localDate
        self.body = body
        self.promptID = promptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First non-empty line, or a short preview of the body — for list rows.
    public var preview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty entry" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if firstLine.count <= 80 { return firstLine }
        return String(firstLine.prefix(77)) + "…"
    }
}

/// A guided reflection prompt.
///
/// Authored seed for now; a content-bundle version can replace this without
/// changing the entry model (`promptID` stays a stable string).
public struct JournalPrompt: Sendable, Equatable, Identifiable, Hashable, Codable {
    public let id: String
    public let title: String
    public let body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

extension JournalPrompt {
    /// Dr. Mia's daily question plus a few companions. Wording is provisional.
    public static let seed: [JournalPrompt] = [
        JournalPrompt(
            id: "what-happened",
            title: "What happened today?",
            body: "Write what stood out — moments, feelings, or anything you want to keep."
        ),
        JournalPrompt(
            id: "what-helped",
            title: "What helped?",
            body: "Name one thing that settled you, even a little — a breath, a person, a place."
        ),
        JournalPrompt(
            id: "still-carrying",
            title: "What are you still carrying?",
            body: "Anything unfinished or heavy that you want to set down in words."
        ),
        JournalPrompt(
            id: "grateful-for",
            title: "One thing you're grateful for",
            body: "Small is fine. Specific is better."
        ),
    ]

    public static func seed(id: String) -> JournalPrompt? {
        seed.first { $0.id == id }
    }
}
