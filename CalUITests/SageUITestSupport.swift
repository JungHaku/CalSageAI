import XCTest

/// Shared entry into the voice home. Launch *is* Cal: orb, menu, transcript.
/// Destinations push on one stack (`dest-*`). Catalog items live in the
/// top-right `home-menu`; emergency stays on the header.
enum SageUI {
    /// Destinations reached through the top-right menu (not header chrome).
    private static let catalogIdentifiers: Set<String> = [
        "type-instead", "dest-practices", "quick-reset", "dest-study",
        "dest-map", "start-checkin", "dest-settings",
    ]

    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    static func waitForHome(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        app.buttons["home-menu"].waitForExistence(timeout: timeout)
            || element(app, "home-menu").waitForExistence(timeout: 2)
            || element(app, "voice-state").waitForExistence(timeout: 2)
    }

    /// Open the catalog menu. Idempotent if it is already open.
    static func openMenu(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let menu = hittable(app.buttons.matching(identifier: "home-menu"))
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "missing home-menu")
        // If a catalog item is already visible, the menu is open.
        if catalogIdentifiers.contains(where: { app.buttons[$0].exists }) {
            return
        }
        tap(menu)
    }

    /// Tap a catalog item (opens the menu first). Emergency is header chrome.
    static func open(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval = 15,
        arrived: String? = nil
    ) {
        if catalogIdentifiers.contains(identifier) {
            openMenu(app, timeout: timeout)
        }
        let card = hittable(app.descendants(matching: .any).matching(identifier: identifier))
        XCTAssertTrue(
            card.waitForExistence(timeout: timeout),
            "missing card: \(identifier)"
        )
        tap(card)
        if let arrived {
            XCTAssertTrue(
                element(app, arrived).waitForExistence(timeout: timeout),
                "\(identifier) did not open \(arrived)"
            )
        }
    }

    static func pop(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: timeout) {
            tap(back)
        }
        XCTAssertTrue(waitForHome(app, timeout: timeout), "did not return to Cal")
    }

    /// The home header and pushed screens both use `emergency-button`. Prefer a
    /// hittable match so a buried duplicate is ignored.
    static func emergency(_ app: XCUIApplication) -> XCUIElement {
        hittable(app.buttons.matching(identifier: "emergency-button"))
    }

    /// Tap even when XCTest marks the control non-hittable (overlay remnants).
    static func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private static func hittable(_ query: XCUIElementQuery) -> XCUIElement {
        let count = query.count
        for index in 0..<count {
            let match = query.element(boundBy: index)
            if match.exists && match.isHittable { return match }
        }
        return query.firstMatch
    }
}
