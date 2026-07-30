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
    public var reminder: ReminderSchedule
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
        reminder: ReminderSchedule = .default,
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
        self.reminder = reminder
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
    /// The message for a given day.
    ///
    /// A **rotation**, not a hash. Deriving the pick from the date means the same
    /// message shows all day, survives a relaunch, needs no storage, and keeps
    /// previews and snapshot tests stable — but a hash would collide, and with a
    /// pool this small a collision means the same line two days running. Stepping
    /// through a deterministically shuffled order guarantees every message is used
    /// once before any repeats.
    ///
    /// The pool is shuffled rather than used in file order so the sequence doesn't
    /// read as a list, and seeded so it's identical on every device.
    ///
    /// ⚠️ Dr. Mia has supplied five lines, so the cycle is five days long. That is
    /// short enough to be noticeable — see ARCHITECTURE.md §17.
    public static func forDay(
        _ day: LocalDate,
        from pool: [Motivation],
        calendar: Calendar
    ) -> Motivation? {
        guard !pool.isEmpty else { return nil }
        let ordered = rotationOrder(pool)
        let index = day.dayNumber(in: calendar) %% ordered.count
        return ordered[index]
    }

    /// Stable shuffle: sort by a seeded hash of the id, so the order is the same
    /// everywhere and doesn't depend on how the content file happens to be written.
    static func rotationOrder(_ pool: [Motivation]) -> [Motivation] {
        pool
            .map { (key: seededHash($0.id), motivation: $0) }
            .sorted { ($0.key, $0.motivation.id) < ($1.key, $1.motivation.id) }
            .map(\.motivation)
    }

    private static func seededHash(_ string: String) -> UInt64 {
        // FNV-1a. `String.hashValue` is seeded per-process and would reshuffle the
        // rotation on every launch.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

infix operator %%: MultiplicationPrecedence

/// Modulo that is always non-negative, so dates before the epoch don't index
/// backwards off the front of the array.
func %% (lhs: Int, rhs: Int) -> Int {
    let r = lhs % rhs
    return r < 0 ? r + rhs : r
}
