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

        SageUI.waitForHome(app, timeout: 20)
        capture(app, "01-home")

        SageUI.open(app, "dest-map", timeout: 20)
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "02-map")
        SageUI.pop(app)

        SageUI.open(app, "dest-practices", timeout: 20)
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "03-practices")
        SageUI.pop(app)

        SageUI.open(app, "dest-study", timeout: 20)
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "04-study")
        SageUI.pop(app)

        SageUI.open(app, "dest-practices", timeout: 20)
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "05-practices-again")
        SageUI.pop(app)

        SageUI.openMenu(app)
        if app.buttons["start-checkin"].waitForExistence(timeout: 5) {
            SageUI.tap(app.buttons["start-checkin"])
            _ = SageUI.element(app, "question-prompt").waitForExistence(timeout: 10)
            capture(app, "05-checkin")
            if app.buttons["checkin-dismiss"].waitForExistence(timeout: 3) {
                SageUI.tap(app.buttons["checkin-dismiss"])
            }
        }

        SageUI.open(app, "dest-settings", timeout: 20)
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        capture(app, "06-settings")
    }

    /// The paywall, captured separately because it needs the free tier to render.
    /// Useful for review notes even though it is not a store screenshot.
    func testCapturePaywall() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
    }
}
