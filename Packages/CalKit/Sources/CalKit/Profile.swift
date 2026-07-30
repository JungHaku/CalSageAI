import Foundation

/// The student's profile.
///
/// A real record with a stable UUID, deliberately **not** a bag of `UserDefaults`
/// keys (ARCHITECTURE.md §2). In the MVP there are no accounts, so this id *is*
/// the local identity; at Phase B first sign-in it becomes the `profiles` row and
/// the whole local history is claimed under the new `auth.uid()`. Loose defaults
/// keys would be orphaned by that migration.
public struct Profile: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var displayName: String?
    public var major: String?
    public var gradYear: Int?
    public var goals: String?
    public var interests: [String]
    public var favoriteSpotSlugs: [String]
    public var timeZoneIdentifier: String
    public var onboardedAt: Date?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        major: String? = nil,
        gradYear: Int? = nil,
        goals: String? = nil,
        interests: [String] = [],
        favoriteSpotSlugs: [String] = [],
        timeZoneIdentifier: String = "America/Los_Angeles",
        onboardedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.major = major
        self.gradYear = gradYear
        self.goals = goals
        self.interests = interests
        self.favoriteSpotSlugs = favoriteSpotSlugs
        self.timeZoneIdentifier = timeZoneIdentifier
        self.onboardedAt = onboardedAt
        self.createdAt = createdAt
    }

    public var isOnboarded: Bool { onboardedAt != nil }

    /// Grad year sanity, mirroring the Postgres `check (grad_year between 2020 and 2100)`.
    public static let validGradYears = 2020...2100
}

/// One line from the daily motivation pool.
public struct Motivation: Sendable, Equatable, Identifiable, Codable, Hashable {
    public let id: String
    public let body: String
    public var tags: [String]

    public init(id: String, body: String, tags: [String] = []) {
        self.id = id
        self.body = body
        self.tags = tags
    }
}

extension Motivation {
    /// Deterministic pick for a given day.
    ///
    /// Hashing the date rather than storing "today's pick" means the same message
    /// shows all day, survives a relaunch, and needs no persistence — and previews
    /// and snapshot tests of the home screen stay stable.
    ///
    /// `recentlyShown` lets the caller exclude the last few days so a small pool
    /// doesn't visibly cycle. With the pool Dr. Mia has supplied so far (five
    /// lines) it *will* still repeat weekly — see ARCHITECTURE.md §17.
    public static func forDay(
        _ day: LocalDate,
        from pool: [Motivation],
        excluding recentlyShown: [String] = []
    ) -> Motivation? {
        guard !pool.isEmpty else { return nil }
        let eligible = pool.filter { !recentlyShown.contains($0.id) }
        let candidates = eligible.isEmpty ? pool : eligible

        // Stable across processes and platforms — `hashValue` is not.
        var seed = UInt64(day.year) &* 10_000 &+ UInt64(day.month) &* 100 &+ UInt64(day.day)
        seed = seed &* 0x9E37_79B9_7F4A_7C15
        seed ^= seed >> 29
        return candidates[Int(seed % UInt64(candidates.count))]
    }
}
