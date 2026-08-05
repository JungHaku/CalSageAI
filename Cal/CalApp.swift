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
    /// Sign-in and the session token. An account on its own changes nothing
    /// about what leaves the device — that needs `memoryConsent` as well.
    let auth: AuthSession

    /// Whether Cal may keep what the student types. Defaults to no, is a
    /// separate decision from signing in, and is the single gate on sending a
    /// bearer token at all (`MemoryConsent`).
    private(set) var memoryConsent: MemoryConsent

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
        auth: AuthSession,
        memoryConsent: MemoryConsent = .notGranted,
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
        self.auth = auth
        self.memoryConsent = memoryConsent
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

    // MARK: Memory consent

    nonisolated private static let consentDefaultsKey = "cal.memoryConsent"

    /// Records the decision, with the timestamp and the disclosure version it was
    /// given against — see `MemoryConsent` for why the version matters.
    func setMemoryConsent(_ granted: Bool) {
        memoryConsent = granted ? .granted(at: dates.now) : .notGranted
        if let encoded = try? JSONEncoder().encode(memoryConsent) {
            UserDefaults.standard.set(encoded, forKey: Self.consentDefaultsKey)
        }
    }

    /// `nonisolated` so the coach client's token closure can read it off the
    /// main actor on every request. `UserDefaults` is thread-safe, and reading
    /// the current value is the whole point — a captured copy would let a
    /// revoked consent keep sending a token until the app relaunched.
    nonisolated static func loadMemoryConsent() -> MemoryConsent {
        guard let data = UserDefaults.standard.data(forKey: consentDefaultsKey),
              let decoded = try? JSONDecoder().decode(MemoryConsent.self, from: data)
        else { return .notGranted }
        return decoded
    }

    /// Who decides what is unlocked.
    ///
    /// Three cases, in order:
    ///
    /// 1. **`-CalEntitlement` was passed** — honour it exactly. This is how a demo
    ///    shows the paid app, and how a UI test asserts both sides of the paywall
    ///    without a sandbox account and a system sheet XCUITest cannot drive.
    /// 2. **A UI test with no tier pinned** — free, deterministically.
    /// 3. **Anything else** — real StoreKit.
    ///
    /// In `DEBUG` the third case defaults to `plus` instead. Running from Xcode is
    /// nearly always either development or a demonstration, and in both the
    /// interesting screens are the paid ones. **Release is untouched**, so a
    /// TestFlight build still shows the free tier and still has to be bought —
    /// giving away the subscription in a shipped binary is not a default anyone
    /// should be able to reach by accident.
    private static func entitlementProvider(
        pinned: Entitlement?, isUITesting: Bool
    ) -> any EntitlementProviding {
        if let pinned { return MockEntitlementProvider(entitlement: pinned) }
        if isUITesting { return MockEntitlementProvider(entitlement: .free) }
        #if DEBUG
        return MockEntitlementProvider(entitlement: .plus)
        #else
        return StoreKitEntitlementProvider()
        #endif
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
    ///   `-CalLiveCoach 1`       point at the LOCAL Edge Functions (`supabase functions
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
        // `-CalEntitlement` deliberately does NOT imply test mode.
        //
        // It used to, and that made it useless for the thing it is most wanted
        // for: showing the paid app to someone. Test mode swaps in the in-memory
        // store and the *local* backend, so a demo pinned to `plus` lost its data
        // on every launch and its chat pointed at a stack that was not running.
        //
        // Every UI test passes `-CalScenario` and `-CalUseMockCoach 1` as well, so
        // dropping the tier from this expression changes nothing for them.
        let isUITesting =
            value(for: "-CalUseMockCoach") == "1" || scenarioName != nil

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

        // The hosted project when `Info.plist` names one, the local stack when it
        // does not. Neither value is a secret: the publishable key identifies the
        // project and every row it can reach is governed by RLS. The key that *is*
        // secret is the OpenAI one, and it is not in this binary at all — it lives
        // in the Edge Function (§8.1).
        //
        // UI tests stay on the local stack whatever the plist says. A test suite
        // that creates accounts against the real project would fill it with
        // rubbish and cost money on every run.
        let backend = BackendConfiguration.resolve(isUITesting: isUITesting)
        let auth = AuthSession(
            baseURL: backend.url,
            anonKey: backend.anonKey,
            store: isUITesting ? InMemoryTokenStore() : KeychainTokenStore()
        )
        let consent = isUITesting ? MemoryConsent.notGranted : loadMemoryConsent()

        // Cal now talks to the real model by default.
        //
        // The old default was the mock, opted out of with `-CalLiveCoach 1`. That
        // was right while the proxy was unproven — a default that reaches a paid
        // model is a default that bills you for running the test suite. It is
        // wrong once the app ships, because it means every student gets canned
        // replies from a fixture.
        //
        // So the polarity is inverted, and the protection moves to the one flag
        // that was always the real guard: `-CalUseMockCoach 1`. Every UI test and
        // every preview already passes it, so nothing automated can reach the
        // network or spend money.
        //
        // Deliberately NOT keyed on `isUITesting`: `-CalScenario` sets that to get
        // the seeded in-memory store, and a demo wants exactly that *plus* a real
        // model. Keying off it would make the two mutually exclusive.
        //
        // There is still no API key in this binary. The function holds it (§8.1).
        let useMockCoach = value(for: "-CalUseMockCoach") == "1"

        // `-CalLiveCoach 1` no longer means "use a real model" — it now means
        // "point at the LOCAL Edge Functions" for development against
        // `supabase functions serve`.
        let useLocalFunctions = value(for: "-CalLiveCoach") == "1"
        let functionsBackend = useLocalFunctions ? BackendConfiguration.local : backend

        return AppContainer(
            dates: dates,
            store: store,
            coach: useMockCoach
                ? MockCoachClient()
                : LiveCoachClient(
                    endpoint: functionsBackend.coachEndpoint,
                    // The consent gate, and the only one. A signed-in student who
                    // has not opted in sends no token, so the server sees an
                    // anonymous request and personal memory never engages —
                    // enforced by withholding the credential rather than by a
                    // check somewhere that could be forgotten.
                    // Consent is re-read on every request rather than captured.
                    // A student turning it off has to take effect on the next
                    // message they send, not at the next launch.
                    bearerToken: { [auth] in
                        guard loadMemoryConsent().permitsRemoteMemory else { return nil }
                        return await auth.accessToken()
                    }
                  ),
            content: BundledContentRepository(),
            // Semantic place search stays OPT-IN, unlike the coach, and the reason
            // is not caution — it is that the `places` function is not deployed and
            // its retrieval needs a `CHROMA_URL` the hosted project does not set.
            // Turning it on by default would trade working offline substring search
            // for a 404. Navigate finds places by name without it; only phrasing a
            // question needs the endpoint.
            placeSearch: useLocalFunctions && !useMockCoach
                ? SemanticPlaceSearch.local()
                : LocalPlaceSearch(),
            auth: auth,
            memoryConsent: consent,
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
            premium: PremiumStore(provider: Self.entitlementProvider(pinned: pinnedTier, isUITesting: isUITesting)),
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
