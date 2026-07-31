import XCTest

/// Gating, from the outside.
///
/// A real StoreKit purchase is a system sheet XCUITest can't drive and needs a
/// sandbox account, so these tests pin the tier with `-CalEntitlement` and assert
/// the app's own behaviour on each side of it. What StoreKit itself does is
/// covered by `CalStoreTests` against the seam (ARCHITECTURE.md §11.2).
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
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: Free

    func testFreeTierSeesLockedProgressAndCanReachThePaywall() {
        let app = launch(entitlement: "free")

        let progress = element(app, "dest-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.tap()

        let locked = element(app, "premium-locked-coherenceAnalytics")
        XCTAssertTrue(
            locked.waitForExistence(timeout: 10),
            "free tier must see the locked state, not the analytics"
        )

        app.buttons["locked-upgrade"].tap()
        XCTAssertTrue(
            element(app, "paywall-header").waitForExistence(timeout: 10),
            "the locked state must lead somewhere"
        )
    }

    func testFreeTierSeesLockedPracticeLibrary() {
        let app = launch(entitlement: "free")

        let practices = element(app, "dest-practices")
        XCTAssertTrue(practices.waitForExistence(timeout: 10))
        practices.tap()

        XCTAssertTrue(
            element(app, "premium-locked-practiceLibrary").waitForExistence(timeout: 10)
        )
    }

    /// The free tier is not a demo. Dr. Mia's goal for it is that a student who
    /// needs help opens Cal — so the check-in has to work without paying.
    func testFreeTierCanStillCheckIn() {
        let app = launch(entitlement: "free", scenario: "empty")

        app.tabBars.buttons["Check-In"].tap()
        // The free flow is the single `.overall` question, so the scale is present
        // and the ten-category framework is not.
        XCTAssertTrue(
            element(app, "question-prompt").waitForExistence(timeout: 10),
            "the free check-in must be usable"
        )
    }

    /// The standing constraint from `PremiumFeature.neverGated`, asserted where it
    /// can actually be broken: a refactor that gates a screen must not take the
    /// emergency affordance with it.
    func testEmergencyHelpIsReachableOnTheFreeTier() {
        let app = launch(entitlement: "free")
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 10))
        emergency.tap()
        XCTAssertTrue(app.buttons["emergency-988-call"].waitForExistence(timeout: 10))
    }

    /// Their own data, never gated — including after a subscription lapses.
    func testHistoryIsNeverGated() {
        let app = launch(entitlement: "free")

        let history = element(app, "dest-history")
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()

        XCTAssertFalse(
            element(app, "premium-locked-coherenceAnalytics").waitForExistence(timeout: 2),
            "a person's own check-ins must not sit behind a paywall"
        )
    }

    // MARK: Paid

    func testSubscriberSeesProgressAndPractices() {
        let app = launch(entitlement: "plus")

        let progress = element(app, "dest-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.tap()
        XCTAssertFalse(
            element(app, "premium-locked-coherenceAnalytics").waitForExistence(timeout: 2),
            "a subscriber must not see a locked screen"
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()

        let practices = element(app, "dest-practices")
        XCTAssertTrue(practices.waitForExistence(timeout: 10))
        practices.tap()
        XCTAssertFalse(
            element(app, "premium-locked-practiceLibrary").waitForExistence(timeout: 2)
        )
    }

    /// Advertising an upgrade to someone who already bought it is just noise.
    func testSubscriberIsNotSoldTheUpgradeAgain() {
        let app = launch(entitlement: "plus")
        XCTAssertTrue(element(app, "dest-history").waitForExistence(timeout: 10))
        XCTAssertFalse(
            element(app, "dest-premium").exists,
            "the upgrade row must not show to an existing subscriber"
        )
    }

    // MARK: The paywall's required disclosures

    /// Schedule 2 §3.8(b) of the Developer Program License Agreement plus Apple's
    /// subscription sign-up-screen list. Asserted here rather than trusted, because
    /// every one of these is a rejection if a layout change drops it.
    func testPaywallCarriesTheRequiredDisclosures() {
        let app = launch(entitlement: "free")

        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        upgrade.tap()

        XCTAssertTrue(
            element(app, "paywall-header").waitForExistence(timeout: 10),
            "paywall did not open"
        )

        // A restore affordance must be on the sign-up screen itself.
        XCTAssertTrue(
            element(app, "paywall-restore").exists,
            "missing restore — Apple's sign-up screen list requires it"
        )
        // Renewal terms: that it recurs, and how to stop it.
        XCTAssertTrue(element(app, "paywall-renewal-terms").exists)
        // Both links must be present and must resolve before submission.
        XCTAssertTrue(element(app, "paywall-terms-link").exists)
        XCTAssertTrue(element(app, "paywall-privacy-link").exists)
    }

    /// The honesty guard. `SPEC-premium.md` promises an AI coach, an AI journal, a
    /// daily action plan, a weekly review and community sessions — none built. If
    /// any of them appear on the paywall, this app is selling something it does not
    /// have, which is a 2.3.1 removal offence as well as a lie.
    func testPaywallDoesNotAdvertiseUnbuiltFeatures() {
        let app = launch(entitlement: "free")

        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        upgrade.tap()
        XCTAssertTrue(element(app, "paywall-header").waitForExistence(timeout: 10))

        let forbidden = ["AI Journal", "Action Plan", "Weekly Coherence Review",
                         "Community", "Sacred Care Fund", "Coherence Coach"]
        let page = app.descendants(matching: .staticText).allElementsBoundByIndex
            .compactMap { $0.exists ? $0.label : nil }
            .joined(separator: " ")

        for claim in forbidden {
            XCTAssertFalse(
                page.localizedCaseInsensitiveContains(claim),
                "paywall advertises \(claim), which is not built"
            )
        }
    }
}
