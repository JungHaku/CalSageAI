import XCTest

/// Captures App Store screenshots as test attachments.
///
/// Not a test — it asserts almost nothing and exists to produce artefacts. Kept
/// in the UI test target because that is the only place a real device frame can
/// be rendered and captured.
///
/// Run against an **iPhone 17 Pro Max** simulator: 6.9" is the only display size
/// App Store Connect still requires, and everything else is auto-scaled from it
/// (`docs/APP-STORE.md` §3).
///
///     xcodebuild test -project CalSageAI.xcodeproj -scheme Cal \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///       -only-testing:CalUITests/ScreenshotTests
///
/// Then export with:
///
///     xcrun xcresulttool export attachments --path <result>.xcresult --output-path ./shots
///
/// Screenshots go out with a seeded 30-day history and a pinned date, so the
/// numbers on them are stable and honest — a screenshot showing a streak nobody
/// could have earned is the kind of small dishonesty that ends up in review notes.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(entitlement: String = "plus") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalScenario", "day30Streak",
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

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureStoreScreenshots() {
        let app = launch()

        // 1 — Today, the daily loop in one glance.
        SageUI.openTab(app, .today, timeout: 20)
        capture(app, "01-today")

        // 2 — Progress (YOU).
        SageUI.openTab(app, .you, timeout: 20)
        let progress = element(app, "dest-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        progress.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "02-progress")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 3 — Tools hub.
        SageUI.openTab(app, .tools, timeout: 20)
        capture(app, "03-tools")

        // 4 — The practice library.
        let practices = element(app, "dest-practices")
        XCTAssertTrue(practices.waitForExistence(timeout: 15))
        practices.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "04-practices")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 5 — Study Mode.
        let study = element(app, "dest-study")
        XCTAssertTrue(study.waitForExistence(timeout: 15))
        study.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "05-study")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 6 — Settings.
        SageUI.openTab(app, .you, timeout: 20)
        let settings = element(app, "dest-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "06-settings")
    }

    /// The paywall, captured separately because it needs the free tier to render.
    /// Useful for review notes even though it is not a store screenshot.
    func testCapturePaywall() {
        let app = launch(entitlement: "free")
        SageUI.openTab(app, .you, timeout: 20)
        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 20))
        upgrade.tap()
        XCTAssertTrue(element(app, "paywall-header").waitForExistence(timeout: 15))
        capture(app, "07-paywall")
    }
}
