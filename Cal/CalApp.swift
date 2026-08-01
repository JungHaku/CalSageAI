import CalAI
import CalContent
import CalData
import CalKit
import CalStore
import SwiftUI

@main
struct CalApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                // At the root, not inside a gated screen: the transaction listener
                // has to be running whether or not anyone visits the paywall.
                .task { await container.premium.start() }
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
    /// Campus place lookup. Substring matching offline, semantic when the local
    /// functions are running — see `-CalLiveCoach`.
    let placeSearch: any PlaceSearching
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
    /// What the person has paid for, and the only thing any view should ask about
    /// gating (§2). Observable, so a purchase or a lapse re-renders the app.
    let premium: PremiumStore
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
        placeSearch: any PlaceSearching,
        identity: any IdentityProviding,
        sync: any SyncEngine,
        profiles: any ProfileStoring,
        practiceSessions: any PracticeSessionStoring,
        reminders: any ReminderScheduling,
        calendars: any CalendarAccess,
        personalData: PersonalDataService,
        premium: PremiumStore,
        isUITesting: Bool = false,
        storeIsEphemeral: Bool = true
    ) {
        self.dates = dates
        self.store = store
        self.coach = coach
        self.content = content
        self.placeSearch = placeSearch
        self.identity = identity
        self.sync = sync
        self.profiles = profiles
        self.practiceSessions = practiceSessions
        self.reminders = reminders
        self.calendars = calendars
        self.personalData = personalData
        self.premium = premium
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
    ///   `-CalEntitlement <tier>` `free` or `plus`, so a UI test can assert both
    ///                            sides of the paywall without a sandbox account
    ///   `-CalLiveCoach 1`       use the local Edge Functions (`supabase functions
    ///                            serve`) — both the coach and semantic place
    ///                            search. Opt-in, because the default must never
    ///                            spend money, or depend on a server, by accident.
    ///                            Navigate still finds places by name without it;
    ///                            only phrasing queries need the endpoint.
    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppContainer {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let scenarioName = value(for: "-CalScenario")
        let pinnedTier = value(for: "-CalEntitlement").flatMap(Entitlement.init(rawValue:))
        let isUITesting =
            value(for: "-CalUseMockCoach") == "1" || scenarioName != nil || pinnedTier != nil

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

        // The proxy now exists, so a real client is possible — but the mock stays
        // the default. Opting in with `-CalLiveCoach 1` is deliberate: a default
        // that reaches a paid model is a default that bills you for running the
        // test suite. Still no API key in this binary; the function holds it.
        return AppContainer(
            dates: dates,
            store: store,
            // Gated on the explicit mock flag rather than on `isUITesting`.
            // `-CalScenario` sets `isUITesting` to get the seeded in-memory store,
            // and a demo wants exactly that *plus* a real model — so keying off it
            // here would make the two mutually exclusive. UI tests always pass
            // `-CalUseMockCoach 1`, which still wins.
            coach: value(for: "-CalLiveCoach") == "1" && value(for: "-CalUseMockCoach") != "1"
                ? LiveCoachClient.local()
                : MockCoachClient(),
            content: BundledContentRepository(),
            // Same gate as the coach: `-CalLiveCoach 1` means "use the local
            // Edge Functions". Semantic search costs one embedding rather than a
            // completion, but the default still must not reach the network —
            // a UI test that searches should not depend on a server being up.
            placeSearch: value(for: "-CalLiveCoach") == "1" && value(for: "-CalUseMockCoach") != "1"
                ? SemanticPlaceSearch.local()
                : LocalPlaceSearch(),
            identity: LocalIdentity(profiles: profiles),
            sync: sync,
            profiles: profiles,
            practiceSessions: practiceSessions,
            reminders: isUITesting ? MockReminderScheduler() : NotificationReminderScheduler(),
            calendars: isUITesting ? MockCalendarAccess() : EventKitCalendarAccess(),
            personalData: PersonalDataService(
                checkIns: store, profiles: profiles, sessions: practiceSessions
            ),
            // A real StoreKit purchase needs a sandbox account and a system sheet
            // XCUITest can't drive, so tests pin the tier instead and assert the
            // app's own behaviour on each side of it (§11.2).
            premium: PremiumStore(
                provider: isUITesting
                    ? MockEntitlementProvider(entitlement: pinnedTier ?? .free)
                    : StoreKitEntitlementProvider()
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
