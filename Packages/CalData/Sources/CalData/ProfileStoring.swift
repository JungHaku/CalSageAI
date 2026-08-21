import CalKit
import Foundation
import SwiftData

/// Persistence for the student's profile.
///
/// Singular by design in the MVP — `current()` returns the one local profile. The
/// protocol is written so Phase B can add a second implementation that scopes by
/// `auth.uid()` without changing callers.
public protocol ProfileStoring: Sendable {
    func current() async throws -> Profile?
    func save(_ profile: Profile) async throws
    func purge() async throws
}

@Model
public final class StoredProfile {
    public var id: UUID = UUID()

    public var displayName: String?
    public var major: String?
    public var gradYear: Int?
    public var goals: String?
    public var interests: [String] = []
    public var favoriteSpotSlugs: [String] = []
    public var timeZoneIdentifier: String = "America/Los_Angeles"
    public var onboardedAt: Date?
    public var reminderEnabled: Bool = false
    public var reminderHour: Int = ReminderSchedule.defaultHour
    public var reminderMinute: Int = ReminderSchedule.defaultMinute
    public var createdAt: Date = Date(timeIntervalSince1970: 0)

    // Same sync bookkeeping as StoredCheckIn (§2). The profile is the row that
    // becomes `public.profiles` at claim time, so it has to be pushable too.
    public var updatedAt: Date = Date(timeIntervalSince1970: 0)
    public var isDirty: Bool = true

    public init(
        id: UUID,
        displayName: String?,
        major: String?,
        gradYear: Int?,
        goals: String?,
        interests: [String],
        favoriteSpotSlugs: [String],
        timeZoneIdentifier: String,
        onboardedAt: Date?,
        reminder: ReminderSchedule,
        createdAt: Date,
        updatedAt: Date,
        isDirty: Bool
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
        self.reminderEnabled = reminder.isEnabled
        self.reminderHour = reminder.hour
        self.reminderMinute = reminder.minute
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
    }

    func toDomain() -> Profile {
        Profile(
            id: id,
            displayName: displayName,
            major: major,
            gradYear: gradYear,
            goals: goals,
            interests: interests,
            favoriteSpotSlugs: favoriteSpotSlugs,
            timeZoneIdentifier: timeZoneIdentifier,
            onboardedAt: onboardedAt,
            reminder: ReminderSchedule(
                isEnabled: reminderEnabled, hour: reminderHour, minute: reminderMinute
            ),
            createdAt: createdAt
        )
    }
}

@ModelActor
public actor SwiftDataProfileStore: ProfileStoring {
    public func current() async throws -> Profile? {
        // Oldest first: if a bug ever produced two, the original wins rather than
        // whichever the database happened to return.
        let descriptor = FetchDescriptor<StoredProfile>(sortBy: [SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func save(_ profile: Profile) async throws {
        let id = profile.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredProfile>(predicate: #Predicate { $0.id == id })
        ).first

        if let existing {
            existing.displayName = profile.displayName
            existing.major = profile.major
            existing.gradYear = profile.gradYear
            existing.goals = profile.goals
            existing.interests = profile.interests
            existing.favoriteSpotSlugs = profile.favoriteSpotSlugs
            existing.timeZoneIdentifier = profile.timeZoneIdentifier
            existing.onboardedAt = profile.onboardedAt
            existing.reminderEnabled = profile.reminder.isEnabled
            existing.reminderHour = profile.reminder.hour
            existing.reminderMinute = profile.reminder.minute
            existing.updatedAt = Date()
            existing.isDirty = true
        } else {
            modelContext.insert(
                StoredProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    major: profile.major,
                    gradYear: profile.gradYear,
                    goals: profile.goals,
                    interests: profile.interests,
                    favoriteSpotSlugs: profile.favoriteSpotSlugs,
                    timeZoneIdentifier: profile.timeZoneIdentifier,
                    onboardedAt: profile.onboardedAt,
                    reminder: profile.reminder,
                    createdAt: profile.createdAt,
                    updatedAt: Date(),
                    isDirty: true
                )
            )
        }
        try modelContext.save()
    }

    /// Hard delete — the profile is identity, so "delete my data" must actually
    /// remove it rather than tombstone it.
    public func purge() async throws {
        try modelContext.delete(model: StoredProfile.self)
        try modelContext.save()
    }
}

/// In-memory store for tests and previews.
public actor InMemoryProfileStore: ProfileStoring {
    private var stored: Profile?

    public init(_ profile: Profile? = nil) { self.stored = profile }

    public func current() async throws -> Profile? { stored }
    public func save(_ profile: Profile) async throws { stored = profile }
    public func purge() async throws { stored = nil }
}
