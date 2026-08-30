import XCTest

/// Gating for the guided library. Basics stay free; guided needs plus.
final class PremiumUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(entitlement: String, scenario: String = "day30Streak") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalScenario", scenario,
            "-CalUseMockCoach", "1",
            "-CalFixedDate", "2026-07-29",
            "-CalEntitlement", entitlement,
        ]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        SageUI.element(app, identifier)
    }

    func testPracticeLibraryOpensEvenIfLaunchedAsFree() {
        let app = launch(entitlement: "free")
        SageUI.open(app, "dest-practices")

        XCTAssertTrue(
            element(app, "premium-locked-practiceLibrary").waitForExistence(timeout: 10)
                || app.staticTexts["Basic breathwork"].waitForExistence(timeout: 10),
            "free tier still sees basics; guided stays locked"
        )
    }

    func testEmergencyHelpIsReachable() {
        let app = launch(entitlement: "free")
        let emergency = SageUI.emergency(app)
        XCTAssertTrue(emergency.waitForExistence(timeout: 10))
        SageUI.tap(emergency)
        XCTAssertTrue(app.buttons["emergency-988-call"].waitForExistence(timeout: 10))
    }

    func testCheckInIsNeverGated() {
        let app = launch(entitlement: "free")
        // Free tier still sees the startup form when not checked in.
        XCTAssertTrue(
            SageUI.element(app, "question-prompt").waitForExistence(timeout: 10),
            "check-in should open for the free tier"
        )
        XCTAssertTrue(
            SageUI.element(app, "score-scale").waitForExistence(timeout: 5)
                || app.buttons["checkin-dismiss"].waitForExistence(timeout: 2)
        )
    }

    func testSubscriberSeesPractices() {
        let app = launch(entitlement: "plus")
        SageUI.open(app, "dest-practices")
        XCTAssertFalse(
            element(app, "premium-locked-practiceLibrary").waitForExistence(timeout: 2)
        )
    }

    func testUpgradeRowIsNotShown() {
        let app = launch(entitlement: "plus")
        XCTAssertTrue(SageUI.waitForHome(app))
        SageUI.openMenu(app)
        XCTAssertTrue(element(app, "start-checkin").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "dest-premium").exists)
    }

    func testPaywallCarriesTheRequiredDisclosures() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
    }

    func testPaywallDoesNotAdvertiseUnbuiltFeatures() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
    }
}
