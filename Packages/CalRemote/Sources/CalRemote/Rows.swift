import CalKit
import Foundation

/// The wire shapes, one per table.
///
/// Deliberately separate types rather than making the `CalKit` models `Codable`
/// against Postgres directly. Three reasons, and each is a bug that would
/// otherwise be waiting:
///
/// 1. **Generated columns must never be written.** `checkin_scores.delta` and
///    `.regulated` are `generated always as ... stored`; including them in a
///    payload is an error from Postgres, not a no-op.
/// 2. **`updated_at` must never be written.** The server stamps it via trigger,
///    and it is the sync watermark. A client that sends its own — from a device
///    with a skewed clock, say — writes a row that a "changed since X" query may
///    never return again.
/// 3. **`columns=` is the union of all keys in the batch.** supabase-swift builds
///    that list from the encoded payload, so an optional that is `nil` on one row
///    and set on another still appears in `columns=` — and the rows where it is
///    absent get **overwritten with null**. Keeping the wire type flat, explicit,
///    and identical for every row is what makes a batch upsert safe.
///
/// The domain types stay clean; this file absorbs the database's opinions.

// MARK: Check-ins

struct CheckInRow: Codable, Hashable, Sendable {
    let id: UUID
    let user_id: UUID
    let kind: String
    let local_date: PostgresDate
    let timezone: String
    let completed_at: Date?
    let deleted_at: Date?

    /// `started_at` is absent on purpose. The column is `not null default now()`
    /// and `CalKit.CheckIn` does not carry one, so letting the default apply is
    /// honest; inventing a value here would fabricate data.
    init(_ checkIn: CheckIn, userID: UUID, deletedAt: Date? = nil) {
        self.id = checkIn.id
        self.user_id = userID
        self.kind = checkIn.kind.rawValue
        self.local_date = PostgresDate(checkIn.localDate)
        self.timezone = checkIn.timeZoneIdentifier
        self.completed_at = checkIn.completedAt
        self.deleted_at = deletedAt
    }

    /// Rebuilds the domain type. Scores arrive separately and are attached by the
    /// caller, because they live in their own table.
    func toDomain(scores: [CategoryScore]) throws -> CheckIn {
        guard let kind = CheckInKind(rawValue: kind) else {
            throw RemoteError.undecodableRow("checkins.kind = \(kind)")
        }
        return CheckIn(
            id: id,
            kind: kind,
            localDate: local_date.value,
            timeZoneIdentifier: timezone,
            scores: scores,
            completedAt: completed_at
        )
    }
}

// MARK: Scores

struct CheckInScoreRow: Codable, Hashable, Sendable {
    let id: UUID
    let checkin_id: UUID
    let user_id: UUID
    let category: String
    let score_before: Int
    let score_after: Int?
    let exercise_slug: String?

    /// Note what is missing: `delta` and `regulated`. Both are
    /// `generated always as ... stored`, so Postgres computes them and rejects any
    /// attempt to supply them. They are read back through `daily_coherence` rather
    /// than round-tripped.
    init(_ score: CategoryScore, checkInID: UUID, userID: UUID) {
        // A score row needs a stable id so a retried push updates rather than
        // duplicates. `CategoryScore` has no id of its own — its identity is
        // (check-in, category) — so the id is derived from exactly that, making
        // the push idempotent without adding a field to the domain type.
        self.id = Self.deterministicID(checkInID: checkInID, category: score.category)
        self.checkin_id = checkInID
        self.user_id = userID
        self.category = score.category.rawValue
        self.score_before = score.before.value
        self.score_after = score.after?.value
        self.exercise_slug = score.exerciseSlug
    }

    func toDomain() throws -> CategoryScore {
        guard let category = CoherenceCategory(rawValue: category) else {
            throw RemoteError.undecodableRow("checkin_scores.category = \(category)")
        }
        return CategoryScore(
            category: category,
            before: Score(clamping: score_before),
            after: score_after.map(Score.init(clamping:)),
            exerciseSlug: exercise_slug
        )
    }

    /// A UUIDv5-style derivation: same inputs, same id, on every device and every
    /// retry. Not a random UUID, because two devices pushing the same check-in
    /// must produce the same score rows rather than two sets.
    static func deterministicID(checkInID: UUID, category: CoherenceCategory) -> UUID {
        var bytes = withUnsafeBytes(of: checkInID.uuid) { Array($0) }
        let salt = Array(category.rawValue.utf8)
        for (index, byte) in salt.enumerated() {
            bytes[index % 16] ^= byte
        }
        // Keep it a valid v4-shaped UUID so nothing downstream objects.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: Practice sessions

struct PracticeSessionRow: Codable, Hashable, Sendable {
    let id: UUID
    let user_id: UUID
    let exercise_slug: String
    let local_date: PostgresDate
    let started_at: Date
    let completed_at: Date?
    let progress: Double
    let checkin_id: UUID?
    let deleted_at: Date?

    init(_ session: PracticeSession, userID: UUID, deletedAt: Date? = nil) {
        self.id = session.id
        self.user_id = userID
        self.exercise_slug = session.exerciseSlug
        self.local_date = PostgresDate(session.localDate)
        self.started_at = session.startedAt
        self.completed_at = session.completedAt
        self.progress = session.progress
        self.checkin_id = session.checkInID
        self.deleted_at = deletedAt
    }

    func toDomain() -> PracticeSession {
        PracticeSession(
            id: id,
            exerciseSlug: exercise_slug,
            localDate: local_date.value,
            startedAt: started_at,
            completedAt: completed_at,
            progress: progress,
            checkInID: checkin_id
        )
    }
}

// MARK: Profile

/// ⚠️ Two fields do **not** round-trip, and they are omitted rather than guessed at.
///
/// - `Profile.reminder` is a `ReminderSchedule` — the local notification time. It
///   has no column, and it should not: a reminder is a property of *this phone*,
///   not of the person. Syncing it would fire notifications on a device the
///   student set nothing up on.
/// - `Profile.favoriteSpotSlugs` is `[String]` while `profiles.favorite_spots` is
///   `uuid[]`. That is a genuine model/schema divergence, not a coding problem,
///   and writing slugs into a uuid column would fail at the database. Left unsynced
///   until one side is changed to match the other — recorded in ARCHITECTURE §15.
struct ProfileRow: Codable, Hashable, Sendable {
    let id: UUID
    let display_name: String?
    let major: String?
    let grad_year: Int?
    let goals: String?
    let interests: [String]
    let timezone: String
    let onboarded_at: Date?

    init(_ profile: Profile) {
        self.id = profile.id
        self.display_name = profile.displayName
        self.major = profile.major
        self.grad_year = profile.gradYear
        self.goals = profile.goals
        self.interests = profile.interests
        self.timezone = profile.timeZoneIdentifier
        self.onboarded_at = profile.onboardedAt
    }

    /// Merges server state onto a local profile, preserving the two device-local
    /// fields above.
    func merged(onto local: Profile) -> Profile {
        var merged = local
        merged.displayName = display_name
        merged.major = major
        merged.gradYear = grad_year
        merged.goals = goals
        merged.interests = interests
        merged.timeZoneIdentifier = timezone
        merged.onboardedAt = onboarded_at
        return merged
    }
}

public enum RemoteError: Error, Equatable, Sendable {
    case notAuthenticated
    case undecodableRow(String)
    case offline
}
