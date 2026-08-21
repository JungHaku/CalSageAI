import XCTest

/// UI tests stay in XCTest: Swift Testing cannot drive `XCUIApplication`, and that
/// is a permanent split rather than a pending migration (ARCHITECTURE.md §11.2).
///
/// Every test launches with seeded state and a mock coach, so nothing here spends
/// money, touches the network, or depends on a real model's wording (§11.4).
///
/// Navigation is the voice home: orb plus menu catalog. Destinations push.
final class CalUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches as a **subscriber** by default.
    ///
    /// This suite is about whether the features themselves work — practices,
    /// check-in, campus tools, settings — after sign-in. Gating itself, and
    /// everything the free tier does and doesn't get, is `PremiumUITests`.
    private func launch(
        scenario: String = "empty",
        entitlement: String = "plus",
        extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalScenario", scenario,
            "-CalUseMockCoach", "1",
            "-CalFixedDate", "2026-07-29",
            "-CalEntitlement", entitlement,
        ] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        SageUI.element(app, identifier)
    }

    func testHomeOffersTheCatalogCalCanOpen() {
        let app = launch()
        XCTAssertTrue(SageUI.waitForHome(app), "voice home did not appear")

        XCTAssertTrue(app.buttons["home-menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["emergency-button"].waitForExistence(timeout: 10))

        SageUI.openMenu(app)
        for identifier in [
            "type-instead", "dest-practices", "quick-reset", "dest-study",
            "dest-map", "start-checkin", "dest-settings",
        ] {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: 10),
                "missing menu control: \(identifier)"
            )
        }
        XCTAssertFalse(element(app, "sage-bar").exists)
        XCTAssertFalse(app.buttons["dismiss-cal"].exists)
    }

    /// §9.2 Layer D: reachable in one tap from the voice home *and* a pushed screen.
    func testEmergencyHelpIsOneTapFromHomeAndAPushedScreen() {
        let app = launch()

        let homeEmergency = SageUI.emergency(app)
        XCTAssertTrue(homeEmergency.waitForExistence(timeout: 10), "no emergency on Cal")
        SageUI.tap(homeEmergency)
        XCTAssertTrue(app.buttons["emergency-988-call"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        SageUI.open(app, "dest-practices")
        let pushed = SageUI.emergency(app)
        XCTAssertTrue(pushed.waitForExistence(timeout: 10), "no emergency on a pushed screen")
        SageUI.tap(pushed)
        XCTAssertTrue(
            app.buttons["emergency-988-call"].waitForExistence(timeout: 10),
            "988 not offered from a pushed screen"
        )
        app.buttons["Done"].tap()
    }

    // MARK: Today and the retention loop (MVP-3)

    func testHomeOffersQuickReset() {
        let app = launch()
        XCTAssertTrue(SageUI.waitForHome(app))

        SageUI.openMenu(app)
        XCTAssertTrue(element(app, "quick-reset").exists, "menu should offer Quick Reset")
        XCTAssertTrue(app.buttons["start-checkin"].exists)
    }

    func testCheckInOpensOnTheFirstOfFiveQuestions() {
        let app = launch()
        SageUI.open(app, "start-checkin")

        let prompt = SageUI.element(app, "question-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(
            prompt.label.contains("safe") || prompt.label.contains("How safe"),
            "expected safety prompt, got: \(prompt.label)"
        )
        XCTAssertTrue(
            SageUI.element(app, "score-chips").waitForExistence(timeout: 5),
            "spoken check-in should offer 0–10 chips"
        )
    }

    /// The reminder toggle must never reach the real notification centre in a test
    /// — a system permission alert would block the run with no useful failure.
    func testReminderToggleSchedulesWithoutASystemPrompt() {
        let app = launch()
        SageUI.open(app, "dest-settings")

        let toggle = app.switches["reminder-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "the reminder is off until asked for")

        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()

        wait(
            for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)],
            timeout: 10
        )
        XCTAssertTrue(
            element(app, "reminder-time").waitForExistence(timeout: 5),
            "enabling should reveal the time picker"
        )
    }

    // MARK: Profile, export, delete (MVP-6)

    func testProfileFieldsAreOptionalAndEditable() {
        let app = launch()
        SageUI.open(app, "dest-settings")
        element(app, "open-profile").tap()

        let name = element(app, "profile-name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Sam")
        XCTAssertEqual(name.value as? String, "Sam")
    }

    /// Deleting is irreversible with no server-side copy, so it must confirm —
    /// and the confirmation must name what actually goes, not just "are you sure?".
    func testDeleteAsksBeforeErasingEverything() {
        let app = launch(scenario: "day30Streak")
        SageUI.open(app, "dest-settings")

        let delete = element(app, "delete-data")
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()

        XCTAssertTrue(
            app.staticTexts["Delete everything?"].waitForExistence(timeout: 10),
            "a destructive action must confirm"
        )
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "can't be undone")
        ).firstMatch
        XCTAssertTrue(message.exists, "the dialog must say the deletion is irreversible")
        XCTAssertTrue(element(app, "confirm-delete").exists)
    }

    func testDeleteRemovesTheHistory() {
        let app = launch(scenario: "day30Streak")
        SageUI.open(app, "dest-settings")
        element(app, "delete-data").tap()

        XCTAssertTrue(app.staticTexts["Delete everything?"].waitForExistence(timeout: 10))
        element(app, "confirm-delete").tap()

        SageUI.pop(app)
        XCTAssertTrue(app.buttons["home-menu"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "stat-consistency").exists)
    }

    // MARK: Campus / Tools (MVP-5)

    func testNavigateListsCampusPlacesAndFilters() {
        let app = launch()
        SageUI.open(app, "dest-map")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Doe")

        XCTAssertTrue(
            app.buttons["place-doe-memorial-library"].waitForExistence(timeout: 10),
            "search should find the seeded campus places"
        )
    }

    func testStudyTimerRunsAndCanBeEnded() {
        let app = launch()
        SageUI.open(app, "dest-study")

        XCTAssertTrue(element(app, "length-picker").waitForExistence(timeout: 10))
        app.buttons["50 min"].tap()
        app.buttons["start-study"].tap()

        let timer = element(app, "study-timer")
        XCTAssertTrue(timer.waitForExistence(timeout: 10))
        let shown = (timer.value as? String) ?? timer.label
        XCTAssertTrue(
            shown.hasPrefix("49:") || shown.hasPrefix("50:"),
            "expected a 50-minute countdown, got: \(shown)"
        )

        app.buttons["end-study"].tap()
        XCTAssertTrue(app.buttons["start-study"].waitForExistence(timeout: 10))
    }

    // MARK: The practice library (MVP-2)

    func testPracticeLibraryListsDrMiasPractices() {
        let app = launch()
        SageUI.open(app, "dest-practices")
        XCTAssertTrue(
            app.staticTexts["Guided practices"].waitForExistence(timeout: 10),
            "practice library did not load"
        )

        for slug in [
            "microcosm-macrocosm-breath",
            "golden-spark-visualization",
            "presence-of-light",
            "solar-plexus-light",
            "sovereignty-reflection",
            "box-breath",
            "even-breath",
            "belly-breath",
            "four-seven-eight",
            "release-sigh",
        ] {
            XCTAssertTrue(
                SageUI.element(app, "practice-\(slug)").waitForExistence(timeout: 10),
                "library is missing \(slug)"
            )
        }

        XCTAssertFalse(app.buttons["practice-seed-placeholder"].exists)
    }

    func testPracticeDetailShowsHerPurposeAndCanBegin() {
        let app = launch()
        SageUI.open(app, "dest-practices")

        let row = SageUI.element(app, "practice-presence-of-light")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let purpose = element(app, "practice-purpose")
        XCTAssertTrue(purpose.waitForExistence(timeout: 10))
        XCTAssertEqual(purpose.label, "Cultivate presence and inner stillness.")

        app.buttons["begin-practice"].tap()

        let skip = app.buttons["skip-exercise"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "Begin should start playback")
        skip.tap()

        XCTAssertTrue(
            app.buttons["begin-practice"].waitForExistence(timeout: 10),
            "declining should return to the practice detail"
        )
    }
}
