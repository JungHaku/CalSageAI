import XCTest

/// UI tests stay in XCTest: Swift Testing cannot drive `XCUIApplication`, and that
/// is a permanent split rather than a pending migration (ARCHITECTURE.md §11.2).
///
/// Every test launches with seeded state and a mock coach, so nothing here spends
/// money, touches the network, or depends on a real model's wording (§11.4).
final class CalUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(scenario: String = "empty", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalScenario", scenario,
            "-CalUseMockCoach", "1",
            "-CalFixedDate", "2026-07-29",
        ] + extra
        app.launch()
        return app
    }

    private let tabTitles = ["Home", "Check-In", "Navigate", "Planner", "Chat with Cal"]

    func testAllFiveTabsFromTheSpecArePresent() {
        let app = launch()
        for title in tabTitles {
            XCTAssertTrue(
                app.tabBars.buttons[title].waitForExistence(timeout: 10),
                "missing tab: \(title)"
            )
        }
    }

    /// §9.2 Layer D: reachable in one tap from *every* tab, not just Home.
    func testEmergencyHelpIsOneTapFromEveryTab() {
        let app = launch()
        for title in tabTitles {
            app.tabBars.buttons[title].tap()

            let emergency = app.buttons["emergency-button"]
            XCTAssertTrue(emergency.waitForExistence(timeout: 10), "no emergency button on \(title)")
            emergency.tap()

            XCTAssertTrue(
                app.buttons["emergency-988-call"].waitForExistence(timeout: 10),
                "988 not offered from \(title)"
            )
            app.buttons["Done"].tap()
        }
    }

    // MARK: The check-in flow (Phase 1)

    func testCheckInOpensOnTheFirstOfDrMiasTenQuestions() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()

        let prompt = app.staticTexts["question-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertEqual(prompt.label, "How safe does your body feel as a place to live right now?")
    }

    /// The spec's core loop: a low score routes into regulation **immediately**,
    /// before the next category, and the exercise is declinable.
    func testLowScoreRoutesIntoTheExerciseImmediately() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()
        XCTAssertTrue(app.staticTexts["question-prompt"].waitForExistence(timeout: 10))

        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0)
        app.buttons["continue-button"].tap()

        // The breathwork player, not the next question.
        //
        // Asserted on the skip button rather than on the cue text: the cue changes
        // every few seconds as the timeline advances, so matching it is a race the
        // test would sometimes lose. The button exists for the whole exercise.
        let skip = app.buttons["skip-exercise"]
        XCTAssertTrue(
            skip.waitForExistence(timeout: 10),
            "a low score should open the exercise before advancing"
        )
        XCTAssertTrue(
            app.staticTexts["One Minute Together (placeholder)"].exists,
            "the exercise player should show which exercise is running"
        )

        // Declining is always available — the framework is about restoring choice.
        skip.tap()

        let prompt = app.staticTexts["question-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertEqual(
            prompt.label,
            "How freely is your breath moving into your heart and belly right now?",
            "skipping should advance to the second category"
        )
    }

    func testHighScoresSkipRegulationAndCompleteTheCheckIn() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()

        for question in 1...10 {
            let button = app.buttons["continue-button"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "stalled at question \(question)")
            app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 1)
            button.tap()
            XCTAssertFalse(
                app.buttons["skip-exercise"].exists,
                "a high score must not open an exercise (question \(question))"
            )
        }

        XCTAssertTrue(
            app.staticTexts["checkin-complete"].waitForExistence(timeout: 10),
            "ten high scores should complete the check-in"
        )
    }
}
