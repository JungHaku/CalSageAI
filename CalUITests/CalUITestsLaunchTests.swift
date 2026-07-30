import XCTest

/// Captures a launch screenshot into the `.xcresult` bundle for each target UI
/// configuration. Useful as a cheap visual record on CI before real snapshot
/// coverage lands in Phase 1 (ARCHITECTURE.md §11.3).
///
/// Note `attachment.lifetime = .keepAlways`: Xcode deletes attachments from
/// *passing* tests by default, which is the usual cause of a silently empty
/// `.xcresult`.
final class CalUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool { true }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchScreenshot() throws {
        let app = XCUIApplication()
        // Seeded so the screenshot is identical run to run — an unseeded launch
        // would vary with the real date and make the record useless for comparison.
        app.launchArguments = [
            "-CalScenario", "day30Streak",
            "-CalUseMockCoach", "1",
            "-CalFixedDate", "2026-07-29",
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "app did not reach the tab shell")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
