import CalAI
import CalContent
import CalData
import CalKit
import SwiftUI

@main
struct CalApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
        }
    }
}

/// Dependency container. Every dependency is a protocol, resolved once here and
/// read from the SwiftUI environment — so previews, unit tests, and UI tests can
/// substitute mocks without feature code knowing (ARCHITECTURE.md §4).
@Observable
final class AppContainer {
    let dates: any DateProvider
    let store: any CoherenceStoring
    let coach: any CoachClient
    /// Authored content — bundled in the MVP, remote at Phase B (§2, §6).
    let content: any ContentRepository
    /// Who the data belongs to. No accounts in the MVP (§2).
    let identity: any IdentityProviding
    /// Inert in the MVP, but real enough to report what exists only on this phone.
    let sync: any SyncEngine
    let profiles: any ProfileStoring
    /// Guided-practice runs, including abandoned ones (§ PracticeSession).
    let practiceSessions: any PracticeSessionStoring
    /// Local notification scheduling. Mocked under test so a system permission
    /// alert can never block a UI-test run.
    let reminders: any ReminderScheduling
    /// The student's own iOS calendars. Mocked under test — a system permission
    /// alert would block the run.
    let calendars: any CalendarAccess
    /// Export and delete. One type owns both so they can't disagree about what
    /// "everything" means.
    let personalData: PersonalDataService
    /// True when launched by XCUITest with seeded state (§11.4).
    let isUITesting: Bool
    /// True when nothing written this session survives relaunch — either a UI-test
    /// run, or the on-disk container failed to open.
    let storeIsEphemeral: Bool

    init(
        dates: any DateProvider,
        store: any CoherenceStoring,
        coach: any CoachClient,
        content: any ContentRepository,
        identity: any IdentityProviding,
        sync: any SyncEngine,
        profiles: any ProfileStoring,
        practiceSessions: any PracticeSessionStoring,
        reminders: any ReminderScheduling,
        calendars: any CalendarAccess,
        personalData: PersonalDataService,
        isUITesting: Bool = false,
        storeIsEphemeral: Bool = true
    ) {
        self.dates = dates
        self.store = store
        self.coach = coach
        self.content = content
        self.identity = identity
        self.sync = sync
        self.profiles = profiles
        self.practiceSessions = practiceSessions
        self.reminders = reminders
        self.calendars = calendars
        self.personalData = personalData
        self.isUITesting = isUITesting
        self.storeIsEphemeral = storeIsEphemeral
    }

    /// Resolves dependencies from launch arguments, so a UI test can pin the app
    /// to a deterministic state instead of driving five screens to reach one (§11.4).
    ///
    /// Recognised arguments:
    ///   `-CalScenario <name>`   seeded history: `empty`, `lowCoherenceDay`, `day30Streak`
    ///   `-CalUseMockCoach 1`    never reach a real model — no cost, no network, no flake
    ///   `-CalFixedDate <iso>`   freeze the clock so streak assertions are stable
    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppContainer {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let scenarioName = value(for: "-CalScenario")
        let isUITesting = value(for: "-CalUseMockCoach") == "1" || scenarioName != nil

        let dates: any DateProvider =
            if let iso = value(for: "-CalFixedDate"), let day = LocalDate(iso: iso) {
                FixedDateProvider(day: day)
            } else {
                SystemDateProvider()
            }

        let seeded = Scenario(rawValue: scenarioName ?? "")?
            .history(today: dates.today, calendar: dates.calendar) ?? []

        // UI tests and previews get the in-memory store: seeded, deterministic,
        // and thrown away between runs. Real launches persist to disk (§7).
        //
        // The fallback matters: if the on-disk container can't open, an in-memory
        // store lets the user still complete a check-in rather than facing a launch
        // crash. That trades durability for availability, which is the right way
        // round here — but it must be visible, hence `storeIsEphemeral`.
        var store: any CoherenceStoring = InMemoryCoherenceStore(seeded)
        var profiles: any ProfileStoring = InMemoryProfileStore()
        var practiceSessions: any PracticeSessionStoring = InMemoryPracticeSessionStore()
        var ephemeral = true
        if !isUITesting {
            if let container = try? SwiftDataCoherenceStore.container() {
                // One container for both stores, so they share a schema and a
                // migration story (§5).
                store = SwiftDataCoherenceStore(modelContainer: container)
                profiles = SwiftDataProfileStore(modelContainer: container)
                practiceSessions = SwiftDataPracticeSessionStore(modelContainer: container)
                ephemeral = false
            }
        }

        // The three Phase B seams (§2), wired inert. They exist now so callers are
        // written against them from day one — retrofitting is what turns a swap
        // into a rewrite.
        let sync = NoOpSyncEngine { [store] in
            // Only the SwiftData store tracks an outbox; the in-memory one has
            // nothing to sync by definition.
            guard let tracked = store as? SwiftDataCoherenceStore else { return 0 }
            return try await tracked.pendingSyncCount()
        }

        // The real CoachClient needs the key-holder proxy to exist (§10), so the
        // mock remains the only implementation — which is also why no API key
        // appears anywhere in this binary.
        return AppContainer(
            dates: dates,
            store: store,
            coach: MockCoachClient(),
            content: BundledContentRepository(),
            identity: LocalIdentity(profiles: profiles),
            sync: sync,
            profiles: profiles,
            practiceSessions: practiceSessions,
            reminders: isUITesting ? MockReminderScheduler() : NotificationReminderScheduler(),
            calendars: isUITesting ? MockCalendarAccess() : EventKitCalendarAccess(),
            personalData: PersonalDataService(
                checkIns: store, profiles: profiles, sessions: practiceSessions
            ),
            isUITesting: isUITesting,
            storeIsEphemeral: ephemeral
        )
    }
}

/// Seeded launch states, shared by UI tests and previews so they can't disagree.
enum Scenario: String, CaseIterable {
    case empty
    case lowCoherenceDay
    case day30Streak

    func history(today: LocalDate, calendar: Calendar) -> [CheckIn] {
        switch self {
        case .empty:
            []
        case .lowCoherenceDay:
            [CheckIn.fixture(band: .low, on: today, regulated: false)]
        case .day30Streak:
            CheckIn.syntheticHistory(days: 30, endingOn: today, calendar: calendar)
        }
    }
}
