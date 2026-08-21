import XCTest

/// The login gate is the same path as production: no stored session, login screen.
/// Other suites seed a dummy session; this one does not (`-CalForceLogin 1`).
final class LoginGateUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testLoginScreenIsTheFrontDoor() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalUseMockCoach", "1",
            "-CalForceLogin", "1",
        ]
        app.launch()

        XCTAssertTrue(
            app.textFields["signin-email"].waitForExistence(timeout: 15)
                || SageUI.element(app, "signin-email").waitForExistence(timeout: 2),
            "login gate should show the email field"
        )
        XCTAssertFalse(
            app.buttons["home-menu"].exists,
            "the orb home must not appear until there is a session"
        )
        XCTAssertTrue(
            SageUI.element(app, "login-crisis-line").waitForExistence(timeout: 5),
            "988 should be reachable from the login screen"
        )
        XCTAssertFalse(app.otherElements["welcome-page"].exists)
    }

    @MainActor
    func testFirstSessionWelcomeDescribesTheAppThenOpensCal() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CalUseMockCoach", "1",
            "-CalShowWelcome", "1",
        ]
        app.launch()

        XCTAssertTrue(
            SageUI.element(app, "welcome-page").waitForExistence(timeout: 15),
            "first session should open on the welcome page"
        )
        XCTAssertFalse(
            app.buttons["home-menu"].exists,
            "voice home must wait until Meet Cal"
        )
        XCTAssertTrue(app.staticTexts["Your personal coherence coach."].exists)
        XCTAssertTrue(app.staticTexts["C.A.L. is the name, coherence is the game."].exists)
        XCTAssertFalse(app.staticTexts["Welcome to Cal"].exists)
        XCTAssertFalse(app.staticTexts["Journal"].exists)
        XCTAssertFalse(app.staticTexts["Talk to Cal"].exists)
        SageUI.tap(SageUI.element(app, "welcome-continue"))
        XCTAssertTrue(
            SageUI.waitForHome(app),
            "Meet Cal should open the voice home"
        )
        XCTAssertFalse(SageUI.element(app, "welcome-page").exists)
    }
}
