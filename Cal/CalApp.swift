import CalAI
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
    /// True when launched by XCUITest with seeded state (§11.4).
    let isUITesting: Bool
    /// True when nothing written this session survives relaunch — either a UI-test
    /// run, or the on-disk container failed to open.
    let storeIsEphemeral: Bool

    init(
        dates: any DateProvider,
        store: any CoherenceStoring,
        coach: any CoachClient,
        isUITesting: Bool = false,
        storeIsEphemeral: Bool = true
    ) {
        self.dates = dates
        self.store = store
        self.coach = coach
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
        var ephemeral = true
        if !isUITesting {
            if let container = try? SwiftDataCoherenceStore.container() {
                store = SwiftDataCoherenceStore(modelContainer: container)
                ephemeral = false
            }
        }

        // Likewise the real CoachClient is a Phase 3 deliverable (§19): it needs
        // the Edge Function proxy to exist. Until then the mock is the only
        // implementation, which is also why no API key appears anywhere here.
        return AppContainer(
            dates: dates,
            store: store,
            coach: MockCoachClient(),
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
