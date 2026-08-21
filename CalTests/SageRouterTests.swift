import CalContent
import CalKit
import CalVoice
import Foundation
import Testing

@testable import Cal

@Suite("SageRouter")
@MainActor
struct SageRouterTests {

    private func router(
        practices: PracticeRunCoordinator = PracticeRunCoordinator()
    ) -> SageRouter {
        SageRouter(
            content: BundledContentRepository(),
            placeSearch: LocalPlaceSearch(),
            practices: practices
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("with no history, Cal is told to start the spoken check-in")
    func statusWhenEmpty() async {
        let result = await router().perform(.todayStatus)
        #expect(!result.isError)
        #expect(result.text.contains("have not finished a check-in"))
        #expect(result.text.contains("start_check_in"))
    }

    @Test("reading the status never navigates")
    func statusDoesNotNavigate() async {
        let router = router()
        #expect(router.path.isEmpty)
        _ = await router.perform(.todayStatus)
        #expect(router.path.isEmpty, "grounding must not push off Cal")
    }

    @Test("start_check_in returns the first spoken question without a screen")
    func startsSpokenCheckIn() async {
        let router = router()
        let result = await router.perform(.startCheckIn)
        #expect(!result.isError)
        #expect(router.path.isEmpty)
        #expect(router.checkInPrompt != nil)
        #expect(result.text.contains("How safe does your body feel"))
    }

    @Test("five high scores complete the spoken check-in")
    func spokenCheckInCompletes() async {
        let router = router()
        _ = await router.perform(.startCheckIn)
        for _ in 0..<5 {
            let result = await router.perform(.recordScore(value: 9))
            #expect(!result.isError)
        }
        #expect(router.checkInFlow == nil)
        #expect(router.checkInPrompt == nil)
    }

    @Test("practice then map push on the same path")
    func practiceAndMapSharePath() async {
        let practices = PracticeRunCoordinator()
        let router = router(practices: practices)
        let play = Task { await router.perform(.playPractice(slug: "microcosm-macrocosm-breath")) }
        #expect(await waitUntil { practices.isRunning })
        #expect(router.path == [
            .practice(slug: "microcosm-macrocosm-breath", autoStart: true),
        ])
        practices.resolve(.completed)
        _ = await play.value
    }

    @Test("practices, map, and study push in order")
    func catalogRoutes() async {
        let router = router()
        _ = await router.perform(.openScreen(.practices))
        #expect(router.path == [.practices])

        _ = await router.perform(.openScreen(.map))
        #expect(router.path.last == .navigate(query: ""))

        router.open(.study)
        #expect(router.path.last == .study)
    }

    @Test("settings and premium push in order")
    func youRoutes() async {
        let router = router()
        _ = await router.perform(.openScreen(.settings))
        #expect(router.path == [.settings])

        router.open(.premium)
        #expect(router.path.last == .premium)
    }

    @Test("every screen Cal can name maps to a route", arguments: CalScreen.allCases)
    func openScreen(_ screen: CalScreen) async {
        let router = router()
        let result = await router.perform(.openScreen(screen))
        #expect(!result.isError)
        #expect(router.path.count == 1)
        #expect(router.path.last != nil)
    }

    @Test("asking twice does not stack the same screen twice")
    func pushDeduplicates() async {
        let router = router()
        _ = await router.perform(.openScreen(.settings))
        _ = await router.perform(.openScreen(.settings))
        #expect(router.path == [.settings])
    }

    @Test("open_screen leaves Cal as the root")
    func openScreenKeepsCalRoot() async {
        let router = router()
        #expect(router.path.isEmpty)
        let result = await router.perform(.openScreen(.study))
        #expect(!result.isError)
        #expect(router.path == [.study])
    }

    @Test("play_practice returns the spoken script without waiting for the player")
    func playsRealPractice() async {
        let practices = PracticeRunCoordinator()
        let router = router(practices: practices)
        let play = Task {
            await router.perform(.playPractice(slug: "microcosm-macrocosm-breath"))
        }
        #expect(await waitUntil { practices.isRunning })
        #expect(router.path == [
            .practice(slug: "microcosm-macrocosm-breath", autoStart: true)
        ])
        let result = await play.value
        #expect(!result.isError)
        #expect(result.text.contains("Speak this script"))
        #expect(result.text.contains("Close your eyes"))
        #expect(practices.isRunning)
        practices.resolve(.completed)
        #expect(await waitUntil { !practices.isRunning })
        #expect(await waitUntil { router.path.isEmpty })
        #expect(router.path.isEmpty, "completed practice pops so Cal is showing again")
    }

    @Test("resolve is idempotent — a second finish does not resume twice")
    func resolveIdempotent() async {
        let practices = PracticeRunCoordinator()
        let begin = Task { await practices.begin(slug: "study-reset") }
        #expect(await waitUntil { practices.isRunning })
        practices.resolve(.completed)
        practices.resolve(.stopped)
        let outcome = await begin.value
        #expect(outcome == .completed)
    }

    @Test("an invented practice fails without moving the screen")
    func unknownPractice() async {
        let router = router()
        let result = await router.perform(.playPractice(slug: "not-a-real-practice"))
        #expect(result.isError)
        #expect(result.text.contains("not-a-real-practice"))
        #expect(router.path.isEmpty, "a failed tool must not push")
    }

    @Test("stopping a practice that is not running fails honestly")
    func stopWithNothingRunning() async {
        let router = router()
        let result = await router.perform(.stopPractice)
        #expect(result.isError)
    }

    @Test("stop_practice resolves the awaited play_practice as stopped")
    func stopPopsPractice() async {
        let practices = PracticeRunCoordinator()
        let router = router(practices: practices)
        _ = await router.perform(.openScreen(.study))
        let play = Task { await router.perform(.playPractice(slug: "study-reset")) }
        #expect(await waitUntil { practices.isRunning })
        #expect(router.path.last == .practice(slug: "study-reset", autoStart: true))

        let stop = await router.perform(.stopPractice)
        #expect(!stop.isError)
        #expect(stop.text.contains("Stopped"))
        let playResult = await play.value
        #expect(!playResult.isError)
        #expect(playResult.text.contains("Speak this script"))
        #expect(await waitUntil { router.path == [.study] })
        #expect(router.path == [.study], "stopping the practice must not drop study under it")
    }

    @Test("a building by name opens the map with the search already run")
    func showsPlace() async {
        let router = router()
        let result = await router.perform(.showPlace(query: "Wheeler"))
        #expect(!result.isError)
        #expect(router.path == [.navigate(query: "Wheeler")])
    }

    @Test("asking for the map itself opens campus, not a failed search", arguments: [
        "map", "the map", "campus map", "berkeley",
    ])
    func showsBareMap(_ query: String) async {
        let router = router()
        let result = await router.perform(.showPlace(query: query))
        #expect(!result.isError)
        #expect(router.path == [.navigate(query: "")])
    }

    @Test("open_screen map opens the bare campus view")
    func openMapScreen() async {
        let router = router()
        let result = await router.perform(.openScreen(.map))
        #expect(!result.isError)
        #expect(router.path == [.navigate(query: "")])
    }

    @Test("clinic symptom routes to Breathe Health Center once")
    func clinicOncePerDay() async {
        let router = router()
        let first = await router.perform(.showPlace(query: "I have a headache"))
        #expect(!first.isError)
        #expect(router.path == [.navigate(query: "Breathe Health Center")])
        let second = await router.perform(.showPlace(query: "anxiety"))
        #expect(!second.isError)
        #expect(second.text.contains("already suggested"))
    }

    @Test("nothing matching fails rather than opening an empty map")
    func showsNoPlace() async {
        let router = router()
        let result = await router.perform(.showPlace(query: "zzzzzzz"))
        #expect(result.isError)
        #expect(router.path.isEmpty)
    }
}

@Suite("Voice scripts resolve against real content")
@MainActor
struct VoiceScriptTests {

    @Test("every slug in every script exists", arguments: VoiceScript.allCases)
    func slugsResolve(_ script: VoiceScript) async throws {
        let content = BundledContentRepository()
        for beat in script.beats {
            guard case .calls(let call) = beat,
                  let tool = try? CalTool(call),
                  case .playPractice(let slug) = tool
            else { continue }
            let exercise = try await content.exercise(slug: slug)
            #expect(exercise != nil, "'\(script.rawValue)' plays '\(slug)', which does not exist")
        }
    }
}
