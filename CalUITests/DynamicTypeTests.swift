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
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The one that matters most. Someone in distress at AX5 must still reach 988.
    func testEmergencyHelpIsUsableAtTheLargestTextSize() {
        let app = launch()
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 20))
        emergency.tap()

        let call = app.buttons["emergency-988-call"]
        XCTAssertTrue(call.waitForExistence(timeout: 15), "988 unreachable at AX5")
        XCTAssertTrue(call.isHittable, "988 is present but cannot be tapped at AX5")
    }

    /// A control that exists but sits off-screen passes `exists` and fails the
    /// person using it, so this asserts `isHittable` throughout.
    func testTheCheckInIsCompletableAtTheLargestTextSize() {
        let app = launch(scenario: "empty")
        app.tabBars.buttons["Check-In"].tap()

        XCTAssertTrue(
            element(app, "question-prompt").waitForExistence(timeout: 20),
            "the check-in question does not render at AX5"
        )

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "the rating scale is missing at AX5")
        XCTAssertTrue(slider.isHittable, "the rating scale is not reachable at AX5")
        slider.adjust(toNormalizedSliderPosition: 0.9)

        let cont = element(app, "continue-button")
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        XCTAssertTrue(cont.isHittable, "Continue is off-screen at AX5 — the check-in cannot be finished")
    }

    /// Every tab has to still be reachable; the tab bar is the app's spine.
    func testEveryTabIsStillReachableAtTheLargestTextSize() {
        let app = launch()
        for title in ["Home", "Check-In", "Navigate", "Planner", "Chat with Cal"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 20), "tab \(title) missing at AX5")
            tab.tap()
        }
    }

    /// The subscription's way out. An auto-renewal statute asks for cancellation
    /// to be available "at will" — a link that has slid off the screen is not.
    func testTheCancellationPathSurvivesTheLargestTextSize() {
        let app = launch()
        let settings = element(app, "dest-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()

        let manage = element(app, "manage-subscription")
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "no way to manage the subscription at AX5")
        XCTAssertTrue(manage.isHittable, "manage/cancel is present but unreachable at AX5")
    }

    /// The paywall carries legally required disclosures. If they scroll away into
    /// a clipped container at AX5, they are not disclosed.
    func testPaywallDisclosuresSurviveTheLargestTextSize() {
        let app = launch(entitlement: "free")
        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 20))
        upgrade.tap()

        XCTAssertTrue(element(app, "paywall-header").waitForExistence(timeout: 15))
        for required in ["paywall-renewal-terms", "paywall-restore", "paywall-terms-link"] {
            let control = element(app, required)
            XCTAssertTrue(control.waitForExistence(timeout: 10), "\(required) missing at AX5")
        }
    }

    /// The smallest size is the other end of the range and gets forgotten; a
    /// layout tuned for large text can collapse here.
    func testHomeStillRendersAtTheSmallestTextSize() {
        let app = launch(size: "UICTContentSizeCategoryExtraSmall")
        XCTAssertTrue(element(app, "dest-history").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["emergency-button"].exists)
    }
}
