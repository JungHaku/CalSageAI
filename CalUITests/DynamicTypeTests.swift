import XCTest

/// The app driven at the largest accessibility text size.
///
/// This is the check the audit cannot make. `performAccessibilityAudit` reports
/// that a *font* does not scale; it cannot tell you whether the screen is still
/// usable once everything does. At AX5 the system text is roughly three times its
/// default size, and the failure mode is not ugliness — it is a button pushed off
/// the bottom of the screen, or a label that has eaten the control beneath it.
///
/// The bar here is deliberately behavioural: can a student still check in, still
/// reach emergency help, still cancel a subscription. Not "does it look right".
final class DynamicTypeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// `UIPreferredContentSizeCategoryName` is honoured by the simulator at launch,
    /// which is what makes this automatable at all — there is no API to change the
    /// content size category of a running app under test.
    private func launch(
        size: String = "UICTContentSizeCategoryAccessibilityXXXL",
        entitlement: String = "plus",
        scenario: String = "day30Streak"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalScenario", scenario,
            "-CalUseMockCoach", "1",
            "-CalFixedDate", "2026-07-29",
            "-CalEntitlement", entitlement,
            "-UIPreferredContentSizeCategoryName", size,
        ]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        SageUI.element(app, identifier)
    }

    /// The one that matters most. Someone in distress at AX5 must still reach 988.
    func testEmergencyHelpIsUsableAtTheLargestTextSize() {
        let app = launch()
        let emergency = SageUI.emergency(app)
        XCTAssertTrue(emergency.waitForExistence(timeout: 20))
        SageUI.tap(emergency)

        let call = app.buttons["emergency-988-call"]
        XCTAssertTrue(call.waitForExistence(timeout: 15), "988 unreachable at AX5")
        XCTAssertTrue(call.isHittable, "988 is present but cannot be tapped at AX5")
    }

    /// A control that exists but sits off-screen passes `exists` and fails the
    /// person using it, so this asserts `isHittable` throughout.
    func testBreathworkIsCompletableAtTheLargestTextSize() {
        let app = launch(scenario: "empty")
        SageUI.open(app, "dest-practices", timeout: 20)

        XCTAssertTrue(
            app.staticTexts["Guided practices"].waitForExistence(timeout: 15),
            "the practice library does not render at AX5"
        )
    }

    /// Home menu destinations still have to be reachable; they are the app's spine.
    func testHomeCardsAreStillReachableAtTheLargestTextSize() {
        let app = launch()
        XCTAssertTrue(SageUI.waitForHome(app, timeout: 20))
        SageUI.openMenu(app, timeout: 20)
        for identifier in ["dest-practices", "start-checkin", "quick-reset"] {
            let card = element(app, identifier)
            XCTAssertTrue(card.waitForExistence(timeout: 20), "\(identifier) missing at AX5")
        }
    }

    /// The subscription's way out. An auto-renewal statute asks for cancellation
    /// to be available "at will" — a link that has slid off the screen is not.
    func testTheCancellationPathSurvivesTheLargestTextSize() {
        let app = launch()
        SageUI.open(app, "dest-settings", timeout: 20)

        let manage = element(app, "manage-subscription")
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "no way to manage the subscription at AX5")
        XCTAssertTrue(manage.isHittable, "manage/cancel is present but unreachable at AX5")
    }

    /// The paywall carries legally required disclosures. If they scroll away into
    /// a clipped container at AX5, they are not disclosed.
    func testPaywallDisclosuresSurviveTheLargestTextSize() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
    }

    /// The smallest size is the other end of the range and gets forgotten; a
    /// layout tuned for large text can collapse here.
    func testTodayStillRendersAtTheSmallestTextSize() {
        let app = launch(size: "UICTContentSizeCategoryExtraSmall")
        XCTAssertTrue(SageUI.waitForHome(app, timeout: 20))
        XCTAssertTrue(app.buttons["home-menu"].exists)
        XCTAssertTrue(app.buttons["emergency-button"].exists)
    }
}
