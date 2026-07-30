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

    func testScoreScaleDrivesTheBandResponse() {
        let app = launch()
        app.tabBars.buttons["Check-In"].tap()

        let response = app.staticTexts["band-response"]
        XCTAssertTrue(response.waitForExistence(timeout: 10))

        // Seeded at 7 → the moderate band's copy.
        XCTAssertEqual(response.label, "You seem a little stressed today. Let's stay aware.")

        // Drag to the bottom of the scale; the low-band copy should replace it.
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(
            app.staticTexts["band-response"].label,
            "I've got you. Let's take one minute together."
        )
    }
}
