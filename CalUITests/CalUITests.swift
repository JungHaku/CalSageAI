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

    /// SwiftUI decides whether a combined accessibility element surfaces as an
    /// `otherElement`, a `staticText`, or a `button`, and it isn't stable across
    /// layouts. Matching on identifier across any type avoids betting on it.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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

    // MARK: Home and the retention loop (MVP-3)

    func testHomeOffersACheckInAndTheDailyMotivation() {
        let app = launch()
        app.tabBars.buttons["Home"].tap()

        XCTAssertTrue(app.buttons["start-checkin"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "daily-motivation").exists, "home should show a daily message")
        // Empty history → no progress card claiming statistics we don't have.
        XCTAssertFalse(element(app, "stat-consistency").exists)
    }

    func testHomeLeadsWithConsistencyNotTheStreak() {
        let app = launch(scenario: "day30Streak")
        app.tabBars.buttons["Home"].tap()

        let consistency = element(app, "stat-consistency")
        XCTAssertTrue(consistency.waitForExistence(timeout: 10))
        XCTAssertTrue(consistency.label.contains("30"), "expected days-practised, got: \(consistency.label)")

        // The streak is shown in WEEKS, not days — 30 daily check-ins is 5 weeks.
        // A daily counter would mark most students as failing every week.
        let streak = element(app, "stat-streak")
        XCTAssertTrue(streak.exists)
        XCTAssertTrue(
            streak.label.contains("Weeks") && streak.label.contains("5"),
            "expected a weekly streak of 5, got: \(streak.label)"
        )

        // A seeded 30-day history has already checked in today, so the CTA is gone.
        XCTAssertTrue(element(app, "checked-in-today").exists)
    }

    func testHistoryListsPastCheckIns() {
        let app = launch(scenario: "day30Streak")
        app.tabBars.buttons["Home"].tap()

        element(app, "dest-history").tap()
        XCTAssertTrue(
            app.buttons["history-2026-07-29"].waitForExistence(timeout: 10),
            "history should list seeded days"
        )
    }

    /// The reminder toggle must never reach the real notification centre in a test
    /// — a system permission alert would block the run with no useful failure.
    func testReminderToggleSchedulesWithoutASystemPrompt() {
        let app = launch()
        app.tabBars.buttons["Home"].tap()
        element(app, "dest-settings").tap()

        let toggle = app.switches["reminder-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "the reminder is off until asked for")

        // A Form row exposes TWO switches: the full-width row, which carries the
        // identifier, and the actual control inside it. Tapping the row hits the
        // label and does nothing — the control has to be tapped directly.
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()

        // Enabling runs through authorization and a store write, so the value
        // changes asynchronously — asserting immediately races the Task.
        wait(
            for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)],
            timeout: 10
        )
        XCTAssertTrue(
            element(app, "reminder-time").waitForExistence(timeout: 5),
            "enabling should reveal the time picker"
        )
    }

    // MARK: The practice library (MVP-2)

    func testPracticeLibraryListsDrMiasPractices() {
        let app = launch()
        app.tabBars.buttons["Home"].tap()
        element(app, "dest-practices").tap()

        for slug in [
            "microcosm-macrocosm-breath",
            "golden-spark-visualization",
            "presence-of-light",
            "solar-plexus-light",
            "sovereignty-reflection",
        ] {
            XCTAssertTrue(
                app.buttons["practice-\(slug)"].waitForExistence(timeout: 10),
                "library is missing \(slug)"
            )
        }

        // The placeholder is scaffolding, not a practice — it must not be browsable.
        XCTAssertFalse(app.buttons["practice-seed-placeholder"].exists)
    }

    func testPracticeDetailShowsHerPurposeAndCanBegin() {
        let app = launch()
        app.tabBars.buttons["Home"].tap()
        element(app, "dest-practices").tap()

        let row = app.buttons["practice-presence-of-light"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let purpose = element(app, "practice-purpose")
        XCTAssertTrue(purpose.waitForExistence(timeout: 10))
        XCTAssertEqual(purpose.label, "Cultivate presence and inner stillness.")

        app.buttons["begin-practice"].tap()

        // The player opens full screen; declining returns to the detail screen.
        let skip = app.buttons["skip-exercise"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "Begin should start playback")
        skip.tap()

        XCTAssertTrue(
            app.buttons["begin-practice"].waitForExistence(timeout: 10),
            "declining should return to the practice detail"
        )
    }

    // MARK: The check-in flow (Phase 1)

    func testCheckInOpensOnTheFirstOfDrMiasTenQuestions() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()

        let prompt = app.staticTexts["question-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertEqual(prompt.label, "How safe does your body feel as a place to live right now?")
    }

    /// The scale starts unset on purpose (ARCHITECTURE.md §7): a pre-filled 5 is
    /// exactly the premium regulation threshold, so tapping straight through would
    /// record everyone as low and inflate the before→after delta.
    func testContinueIsDisabledUntilTheScaleIsTouched() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()

        let button = app.buttons["continue-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertFalse(button.isEnabled, "Continue must not be tappable before the student answers")

        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(button.isEnabled, "answering should enable Continue")
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
