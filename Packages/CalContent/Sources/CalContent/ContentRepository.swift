import CalKit
import Foundation

/// Everything Dr. Mia authors, in one payload.
///
/// Deliberately the same shape as the future `exercises` / `motivations` rows, so
/// Phase B moves content from bundle to database without a translation layer
/// (ARCHITECTURE.md §6).
public struct ContentBundle: Codable, Sendable, Equatable {
    /// Bumped whenever the payload changes. `RemoteContentRepository` will use this
    /// to decide whether the server's copy supersedes the bundled one.
    public let version: Int
    public let questions: [CoherenceQuestion]
    public let motivations: [Motivation]
    public let exercises: [Exercise]

    public init(
        version: Int,
        questions: [CoherenceQuestion],
        motivations: [Motivation],
        exercises: [Exercise]
    ) {
        self.version = version
        self.questions = questions
        self.motivations = motivations
        self.exercises = exercises
    }

    public static let empty = ContentBundle(version: 0, questions: [], motivations: [], exercises: [])
}

/// The content seam (ARCHITECTURE.md §2).
///
/// MVP: `BundledContentRepository`, reading JSON compiled into the app.
/// Phase B: `RemoteContentRepository`, which fetches a newer `ContentBundle` and
/// falls back to the bundled one — so the offline path stays the *primary* path
/// rather than degrading into a fallback. Consumers never change.
public protocol ContentRepository: Sendable {
    func bundle() async throws -> ContentBundle

    func exercise(slug: String) async throws -> Exercise?
    /// The regulation exercise for a category, if one has been authored yet.
    func exercise(for category: CoherenceCategory) async throws -> Exercise?
    func exercises(tier: ContentTier?) async throws -> [Exercise]
    func question(for category: CoherenceCategory) async throws -> CoherenceQuestion
    func questions() async throws -> [CoherenceCategory: CoherenceQuestion]
    func motivations() async throws -> [Motivation]
}

public enum ContentError: Error, Equatable, Sendable {
    case resourceMissing(String)
}

/// Reads the content compiled into `CalContent`.
///
/// The decode happens once and is cached: it's a few hundred kilobytes of JSON
/// that never changes during a run, and the check-in asks for a question on every
/// step.
public actor BundledContentRepository: ContentRepository {
    private var cached: ContentBundle?
    private let resourceBundle: Bundle

    public init() {
        self.resourceBundle = .module
    }

    init(bundle: Bundle) {
        self.resourceBundle = bundle
    }

    public func bundle() async throws -> ContentBundle {
        if let cached { return cached }
        guard let url = resourceBundle.url(forResource: "content", withExtension: "json") else {
            throw ContentError.resourceMissing("content.json")
        }
        let decoded = try JSONDecoder().decode(ContentBundle.self, from: Data(contentsOf: url))
        cached = decoded
        return decoded
    }

    public func exercise(slug: String) async throws -> Exercise? {
        try await bundle().exercises.first { $0.slug == slug }
    }

    public func exercise(for category: CoherenceCategory) async throws -> Exercise? {
        try await bundle().exercises.first { $0.category == category }
    }

    public func exercises(tier: ContentTier? = nil) async throws -> [Exercise] {
        let all = try await bundle().exercises
        guard let tier else { return all }
        return all.filter { $0.tier == tier }
    }

    public func question(for category: CoherenceCategory) async throws -> CoherenceQuestion {
        // Falls back to the copy compiled into CalKit. That seed is tiny and
        // guarantees the check-in can never render an empty prompt, even if the
        // content payload is somehow unreadable. A test pins the two together so
        // they can't drift.
        try await questions()[category] ?? CoherenceQuestion.seeded(category)
    }

    public func questions() async throws -> [CoherenceCategory: CoherenceQuestion] {
        let list = try await bundle().questions
        return Dictionary(list.map { ($0.category, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func motivations() async throws -> [Motivation] {
        try await bundle().motivations
    }
}

/// In-memory repository for tests and previews.
public actor StaticContentRepository: ContentRepository {
    private let stored: ContentBundle

    public init(_ bundle: ContentBundle) { self.stored = bundle }

    public func bundle() async throws -> ContentBundle { stored }

    public func exercise(slug: String) async throws -> Exercise? {
        stored.exercises.first { $0.slug == slug }
    }

    public func exercise(for category: CoherenceCategory) async throws -> Exercise? {
        stored.exercises.first { $0.category == category }
    }

    public func exercises(tier: ContentTier? = nil) async throws -> [Exercise] {
        guard let tier else { return stored.exercises }
        return stored.exercises.filter { $0.tier == tier }
    }

    public func question(for category: CoherenceCategory) async throws -> CoherenceQuestion {
        try await questions()[category] ?? CoherenceQuestion.seeded(category)
    }

    public func questions() async throws -> [CoherenceCategory: CoherenceQuestion] {
        Dictionary(stored.questions.map { ($0.category, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func motivations() async throws -> [Motivation] { stored.motivations }
}
