import CalKit
import Foundation
import SwiftData

/// SwiftData is the source of truth for the UI; Supabase is the source of truth
/// for the account (ARCHITECTURE.md §7). These `@Model` classes are the local
/// mirror, deliberately kept separate from `CalKit`'s value types:
///
/// - `CalKit` stays platform-agnostic and dependency-free, so `swift test` runs in
///   ~2s with no simulator. Putting `@Model` on the domain types would drag
///   SwiftData into that package and end the fast loop.
/// - Persistence concerns (sync flags, tombstones, remote ids) don't belong in the
///   domain model. A `CheckIn` shouldn't know it's dirty.
///
/// The cost is a mapping layer, which is tested in both directions.

@Model
public final class StoredCheckIn {
    /// Local identity, and the same UUID the row carries in Postgres — so a
    /// re-sync can't duplicate a check-in that was already pushed.
    public var id: UUID = UUID()

    public var kindRaw: String = CheckInKind.full.rawValue
    /// Stored as the ISO day string, not a `Date`. A `Date` would reintroduce
    /// exactly the timezone ambiguity `LocalDate` exists to remove, and this column
    /// maps to a Postgres `date`.
    public var localDateISO: String = ""
    public var timeZoneIdentifier: String = ""
    public var completedAt: Date?

    // MARK: Sync bookkeeping (§7)
    public var updatedAt: Date = Date(timeIntervalSince1970: 0)
    public var isDirty: Bool = true
    /// Tombstone, so a delete propagates instead of the row reappearing on the
    /// next pull.
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \StoredCategoryScore.checkIn)
    public var scores: [StoredCategoryScore] = []

    public init(
        id: UUID,
        kindRaw: String,
        localDateISO: String,
        timeZoneIdentifier: String,
        completedAt: Date?,
        updatedAt: Date,
        isDirty: Bool
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.localDateISO = localDateISO
        self.timeZoneIdentifier = timeZoneIdentifier
        self.completedAt = completedAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }
}

@Model
public final class StoredCategoryScore {
    public var categoryRaw: String = CoherenceCategory.overall.rawValue
    public var scoreBefore: Int = 0
    public var scoreAfter: Int?
    public var exerciseSlug: String?
    public var answeredAt: Date = Date(timeIntervalSince1970: 0)

    public var checkIn: StoredCheckIn?

    public init(
        categoryRaw: String,
        scoreBefore: Int,
        scoreAfter: Int?,
        exerciseSlug: String?,
        answeredAt: Date
    ) {
        self.categoryRaw = categoryRaw
        self.scoreBefore = scoreBefore
        self.scoreAfter = scoreAfter
        self.exerciseSlug = exerciseSlug
        self.answeredAt = answeredAt
    }
}

// MARK: - Mapping

public enum StoreMappingError: Error, Equatable, Sendable {
    case unknownKind(String)
    case unknownCategory(String)
    case malformedLocalDate(String)
    case scoreOutOfRange(Int)
}

extension StoredCheckIn {
    /// Rehydrate the domain value.
    ///
    /// Throws rather than silently substituting defaults: a row with an
    /// unrecognised enum or an out-of-range score means the schema drifted, and
    /// coercing it would quietly corrupt the analytics that average these.
    public func toDomain() throws -> CheckIn {
        guard let kind = CheckInKind(rawValue: kindRaw) else {
            throw StoreMappingError.unknownKind(kindRaw)
        }
        guard let localDate = LocalDate(iso: localDateISO) else {
            throw StoreMappingError.malformedLocalDate(localDateISO)
        }

        // Sorted by the canonical question order, not insertion order, so the UI
        // and the analytics see categories in Dr. Mia's sequence.
        let order = kind.categories
        let mapped = try scores.map { try $0.toDomain() }
        let sorted = mapped.sorted {
            (order.firstIndex(of: $0.category) ?? .max) < (order.firstIndex(of: $1.category) ?? .max)
        }

        return CheckIn(
            id: id,
            kind: kind,
            localDate: localDate,
            timeZoneIdentifier: timeZoneIdentifier,
            scores: sorted,
            completedAt: completedAt
        )
    }
}

extension StoredCategoryScore {
    public func toDomain() throws -> CategoryScore {
        guard let category = CoherenceCategory(rawValue: categoryRaw) else {
            throw StoreMappingError.unknownCategory(categoryRaw)
        }
        guard let before = Score(scoreBefore) else {
            throw StoreMappingError.scoreOutOfRange(scoreBefore)
        }
        var after: Score?
        if let scoreAfter {
            guard let parsed = Score(scoreAfter) else {
                throw StoreMappingError.scoreOutOfRange(scoreAfter)
            }
            after = parsed
        }
        return CategoryScore(
            category: category, before: before, after: after, exerciseSlug: exerciseSlug
        )
    }
}

extension CheckIn {
    func toStored(updatedAt: Date, isDirty: Bool = true) -> StoredCheckIn {
        let stored = StoredCheckIn(
            id: id,
            kindRaw: kind.rawValue,
            localDateISO: localDate.iso,
            timeZoneIdentifier: timeZoneIdentifier,
            completedAt: completedAt,
            updatedAt: updatedAt,
            isDirty: isDirty
        )
        stored.scores = scores.map {
            StoredCategoryScore(
                categoryRaw: $0.category.rawValue,
                scoreBefore: $0.before.value,
                scoreAfter: $0.after?.value,
                exerciseSlug: $0.exerciseSlug,
                answeredAt: updatedAt
            )
        }
        return stored
    }
}
