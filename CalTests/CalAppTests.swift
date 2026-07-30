import CalData
import CalContent
import CalKit
import Foundation
import Testing

@testable import Cal

/// Tests for app-target wiring. Domain logic is tested in `CalKit`, where it runs
/// without a simulator (ARCHITECTURE.md §11.2); what's left to verify here is that
/// launch arguments actually resolve, because the UI tests depend on it (§11.4).
///
/// These suites are `@MainActor` because the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Xcode 26's default for app
/// targets), so every type in the `Cal` module is implicitly main-actor isolated.
/// The `Packages/*` targets don't carry that setting, which is why `CalKit`'s
/// tests need no annotation — its types are `Sendable` and nonisolated by design.
@Suite("AppContainer launch arguments")
@MainActor
struct AppContainerTests {
    @Test("a plain launch uses the system clock and the persistent store")
    func defaults() {
        let container = AppContainer.live(arguments: [])
        #expect(!container.isUITesting)
        #expect(container.dates is SystemDateProvider)
        // Deliberately does NOT assert the store is empty: since Phase 1 a real
        // launch persists to disk, so its contents depend on whatever earlier runs
        // left in the simulator's container. Asserting emptiness here passed only
        // by accident when every configuration was in-memory.
        #expect(!container.storeIsEphemeral, "a real launch should persist check-ins")
    }

    @Test("a UI-test launch is ephemeral, so runs can't contaminate each other")
    func uiTestLaunchIsEphemeral() async throws {
        let container = AppContainer.live(arguments: ["-CalUseMockCoach", "1"])
        #expect(container.isUITesting)
        #expect(container.storeIsEphemeral)

        let today = container.dates.today
        #expect(try await container.store.checkIns(from: today, to: today).isEmpty)
    }

    @Test("-CalFixedDate freezes the clock so streak assertions are stable")
    func fixedDate() {
        let container = AppContainer.live(arguments: ["-CalFixedDate", "2026-07-29"])
        #expect(container.dates.today == LocalDate(iso: "2026-07-29"))
    }

    @Test("a malformed -CalFixedDate falls back to the system clock rather than crashing")
    func malformedFixedDate() {
        let container = AppContainer.live(arguments: ["-CalFixedDate", "not-a-date"])
        #expect(container.dates is SystemDateProvider)
    }

    @Test("a flag with no following value is ignored rather than crashing")
    func danglingFlag() {
        let container = AppContainer.live(arguments: ["-CalFixedDate"])
        #expect(container.dates is SystemDateProvider)
    }

    @Test("-CalScenario day30Streak seeds exactly 30 consecutive days")
    func seedsStreakScenario() async throws {
        let container = AppContainer.live(
            arguments: ["-CalScenario", "day30Streak", "-CalFixedDate", "2026-07-29"]
        )
        #expect(container.isUITesting)

        let today = container.dates.today
        let history = try await container.store.recent(
            days: 30, today: today, calendar: container.dates.calendar
        )
        #expect(history.count == 30)
        #expect(
            StreakCalculator().currentStreak(
                checkInDates: history.map(\.localDate), today: today, calendar: container.dates.calendar
            ) == 30
        )
    }

    @Test("-CalScenario lowCoherenceDay seeds one unregulated low-band check-in")
    func seedsLowScenario() async throws {
        let container = AppContainer.live(
            arguments: ["-CalScenario", "lowCoherenceDay", "-CalFixedDate", "2026-07-29"]
        )
        let today = container.dates.today
        let history = try await container.store.checkIns(from: today, to: today)

        #expect(history.count == 1)
        #expect(history.first?.regulatedCount == 0)
        #expect(history.first?.awaitingReRating.count == 10)
    }

    @Test("an unknown scenario name seeds nothing instead of failing to launch")
    func unknownScenario() async throws {
        let container = AppContainer.live(arguments: ["-CalScenario", "nonsense"])
        let today = container.dates.today
        #expect(try await container.store.checkIns(from: today, to: today).isEmpty)
    }

    @Test("every scenario resolves and is safe to launch", arguments: Scenario.allCases)
    func allScenariosResolve(_ scenario: Scenario) {
        let container = AppContainer.live(
            arguments: ["-CalScenario", scenario.rawValue, "-CalFixedDate", "2026-07-29"]
        )
        #expect(container.isUITesting)
    }
}

/// The Phase B seams (ARCHITECTURE.md §2), wired inert. These tests exist so the
/// wiring can't quietly rot before there's a backend to exercise it.
@Suite("Backend-ready seams")
@MainActor
struct SeamWiringTests {
    @Test("the container exposes content, identity, and sync")
    func seamsAreWired() async throws {
        let container = AppContainer.live(arguments: ["-CalUseMockCoach", "1"])
        #expect(try await container.content.bundle().version >= 1)
        #expect(await container.identity.isAuthenticated == false)
        #expect(try await container.sync.sync() == .notConfigured)
    }

    @Test("the identity is stable across calls — it becomes the server PK at Phase B")
    func identityIsStable() async throws {
        let container = AppContainer.live(arguments: ["-CalUseMockCoach", "1"])
        let first = try await container.identity.currentProfileID()
        let second = try await container.identity.currentProfileID()
        #expect(first == second)
        #expect(try await container.profiles.current()?.id == first)
    }

    @Test("authored content resolves through the repository, not just CalKit's seed")
    func contentResolves() async throws {
        let container = AppContainer.live(arguments: ["-CalUseMockCoach", "1"])
        let question = try await container.content.question(for: .safety)
        #expect(question.prompt == "How safe does your body feel as a place to live right now?")

        let practice = try await container.content.exercise(for: .presence)
        #expect(practice?.slug == "presence-of-light")
    }
}

@Suite("Emergency contacts")
@MainActor
struct EmergencyContactTests {
    // A malformed tel: URL makes the button silently do nothing, which on this
    // screen is the failure that matters most.
    @Test("every verified contact has a parseable URL")
    func urlsParse() {
        for contact in EmergencyContact.verified {
            #expect(URL(string: contact.urlString) != nil, "unparseable URL for \(contact.id)")
        }
    }

    @Test("988 call, text, and chat are all present, plus 911")
    func lifelineRoutesPresent() {
        let ids = Set(EmergencyContact.verified.map(\.id))
        #expect(ids.isSuperset(of: ["988-call", "988-text", "988-chat", "911"]))
    }

    // Guards §9.3: if someone pastes the disputed Berkeley digits in without
    // dialling them first, this fails — they have to promote the contact to
    // `verified` deliberately.
    @Test("contacts pending verification carry no dialable number")
    func pendingContactsHaveNoDigits() {
        for contact in EmergencyContact.pendingVerification {
            #expect(
                !contact.urlString.hasPrefix("tel:") && !contact.urlString.hasPrefix("sms:"),
                "\(contact.id) is dialable but still marked unverified — see §9.3"
            )
        }
    }

    @Test("contact ids are unique, since they double as accessibility identifiers")
    func idsAreUnique() {
        let all = EmergencyContact.verified + EmergencyContact.pendingVerification
        #expect(Set(all.map(\.id)).count == all.count)
    }
}
