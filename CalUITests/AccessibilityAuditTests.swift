import XCTest

/// Apple's own accessibility audit, run over every screen.
///
/// `performAccessibilityAudit` (iOS 17+) is the only genuinely automated
/// accessibility check available: it walks the real accessibility tree of the
/// running app and reports contrast failures, unlabelled elements, clipped text
/// at large Dynamic Type sizes, undersized hit regions, and wrong traits. It is
/// not a substitute for someone actually driving the app with VoiceOver — it
/// cannot tell you the labels make *sense* — but it catches the mechanical
/// failures, and it catches them on every commit.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func launch(entitlement: String = "plus", scenario: String = "day30Streak") -> XCUIApplication {
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

    /// Audits the current screen and returns a readable list of what it found.
    ///
    /// Returning `true` from the handler tells XCTest we've dealt with the issue,
    /// so nothing is recorded as a failure — which is what makes this usable as a
    /// survey. The asserting version is `assertNoIssues`.
    @discardableResult
    private func survey(
        _ app: XCUIApplication,
        _ screen: String,
        types: XCUIAccessibilityAuditType = .all
    ) -> [String] {
        // A reference-type collector rather than capturing a local `var`: the
        // handler is `@Sendable` under Swift 6, so an inout capture of a local
        // array is a data-race error even though the callback is synchronous and
        // non-escaping.
        let found = IssueCollector()
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                let element = issue.element?.description ?? "—"
                let compact = element
                    .split(separator: "\n").first.map(String.init) ?? element
                found.append("[\(screen)] \(issue.auditType): \(issue.compactDescription) → \(compact)")
                return true
            }
        } catch {
            found.append("[\(screen)] audit failed to run: \(error)")
        }
        return found.all
    }

    /// The full sweep. Prints a consolidated report so a run tells you everything
    /// at once rather than one failure at a time.
    func testAccessibilitySurveyAcrossEveryScreen() {
        let app = launch()
        var all: [String] = []

        // Home
        XCTAssertTrue(element(app, "dest-history").waitForExistence(timeout: 15))
        all += survey(app, "Home")

        // Each destination off Home.
        let destinations = [
            ("dest-progress", "Progress"),
            ("dest-practices", "Practices"),
            ("dest-history", "History"),
            ("dest-study", "Study"),
            ("dest-settings", "Settings"),
        ]
        for (identifier, name) in destinations {
            let row = element(app, identifier)
            guard row.waitForExistence(timeout: 10) else {
                all.append("[\(name)] could not reach screen")
                continue
            }
            row.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            all += survey(app, name)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // The other tabs.
        for tab in ["Check-In", "Navigate", "Planner"] {
            app.tabBars.buttons[tab].tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            all += survey(app, tab)
        }

        // Emergency — the screen that matters most and is reached by sheet.
        app.tabBars.buttons["Home"].tap()
        let emergency = app.buttons["emergency-button"]
        if emergency.waitForExistence(timeout: 10) {
            emergency.tap()
            _ = app.buttons["emergency-988-call"].waitForExistence(timeout: 10)
            all += survey(app, "Emergency")
        }

        let report = all.isEmpty
            ? "No accessibility issues found."
            : "\(all.count) accessibility issues:\n" + all.joined(separator: "\n")
        print("\n===== ACCESSIBILITY SURVEY =====\n\(report)\n===== END =====\n")

        let attachment = XCTAttachment(string: report)
        attachment.name = "accessibility-survey"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The audit types this project trusts enough to fail a build on.
    ///
    /// **Contrast is deliberately excluded, and not because it is inconvenient.**
    /// It was measured and found unreliable here: with the Home destination
    /// subtitles set to pure black on the light card — 18.57:1, an order of
    /// magnitude above the 4.5:1 requirement — the audit still reported "Contrast
    /// failed" for them. It cannot resolve the effective background behind these
    /// rows, so its verdict does not track the colours actually drawn. Contrast is
    /// instead verified by computation in `CalDesign`'s `ContrastTests`, which
    /// measures the exact values the app renders and is strictly more trustworthy.
    ///
    /// **Dynamic Type and text clipping are excluded** for a duller reason: what
    /// remains is system chrome — a `List` section footer, a toolbar "Done", the
    /// `.searchable` field — where the font is Apple's, not ours. The behavioural
    /// question those audits are proxies for is answered directly by
    /// `DynamicTypeTests`, which drives the app at AX5 and asserts the controls are
    /// still hittable.
    private static let enforced: XCUIAccessibilityAuditType = [
        .hitRegion,
        .sufficientElementDescription,
        .trait,
    ]

    /// The regression guard. Everything here is unambiguous, attributable to our
    /// own code, and currently clean — so a new failure means someone broke it.
    func testNoRegressionsInTheEnforcedAuditCategories() {
        let app = launch()
        XCTAssertTrue(element(app, "dest-history").waitForExistence(timeout: 15))

        var found = survey(app, "Home", types: Self.enforced)

        for (identifier, name) in [("dest-progress", "Progress"), ("dest-practices", "Practices"),
                                   ("dest-history", "History"), ("dest-settings", "Settings")] {
            let row = element(app, identifier)
            guard row.waitForExistence(timeout: 10) else { continue }
            row.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            found += survey(app, name, types: Self.enforced)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        for tab in ["Check-In", "Navigate", "Planner"] {
            app.tabBars.buttons[tab].tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            found += survey(app, tab, types: Self.enforced)
        }

        XCTAssertTrue(
            found.isEmpty,
            "\(found.count) accessibility regressions:\n" + found.joined(separator: "\n")
        )
    }

    /// The paywall's controls, where the undersized hit targets were found.
    func testPaywallHasNoEnforcedAuditIssues() {
        let app = launch(entitlement: "free")
        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 15))
        upgrade.tap()
        XCTAssertTrue(element(app, "paywall-header").waitForExistence(timeout: 10))

        let found = survey(app, "Paywall", types: Self.enforced)
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    /// The paywall, audited on the free tier where it is actually reachable.
    func testAccessibilitySurveyOfThePaywall() {
        let app = launch(entitlement: "free")
        let upgrade = element(app, "dest-premium")
        XCTAssertTrue(upgrade.waitForExistence(timeout: 15))
        upgrade.tap()
        XCTAssertTrue(element(app, "paywall-header").waitForExistence(timeout: 10))

        let issues = survey(app, "Paywall")
        let report = issues.isEmpty ? "No accessibility issues found." : issues.joined(separator: "\n")
        print("\n===== PAYWALL AUDIT =====\n\(report)\n===== END =====\n")

        let attachment = XCTAttachment(string: report)
        attachment.name = "paywall-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Thread-safe accumulator for audit issues.
private final class IssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [String] = []

    func append(_ issue: String) {
        lock.withLock { issues.append(issue) }
    }

    var all: [String] { lock.withLock { issues } }
}
