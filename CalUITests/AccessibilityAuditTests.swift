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
        SageUI.element(app, identifier)
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

        SageUI.waitForHome(app)
        all += survey(app, "Cal")

        let destinations = [
            ("dest-settings", "Settings"),
            ("dest-practices", "Practices"),
            ("dest-study", "Study"),
            ("dest-map", "Campus map"),
        ]
        for (identifier, name) in destinations {
            SageUI.open(app, identifier)
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            all += survey(app, name)
            SageUI.pop(app)
        }

        SageUI.waitForHome(app)
        let emergency = SageUI.emergency(app)
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
    /// It was measured and found unreliable here: with destination subtitles set
    /// to pure black on the light card — 18.57:1, an order of magnitude above the
    /// 4.5:1 requirement — the audit still reported "Contrast failed" for them. It
    /// cannot resolve the effective background behind these rows, so its verdict
    /// does not track the colours actually drawn. Contrast is instead verified by
    /// computation in `CalDesign`'s `ContrastTests`.
    ///
    /// **Dynamic Type and text clipping are excluded** for a duller reason: what
    /// remains is system chrome — a `List` section footer, a toolbar "Done", the
    /// `.searchable` field — where the font is Apple's, not ours. The behavioural
    /// question those audits are proxies for is answered directly by
    /// `DynamicTypeTests`.
    private static let enforced: XCUIAccessibilityAuditType = [
        .hitRegion,
        .sufficientElementDescription,
        .trait,
    ]

    /// The regression guard. Everything here is unambiguous, attributable to our
    /// own code, and currently clean — so a new failure means someone broke it.
    func testNoRegressionsInTheEnforcedAuditCategories() {
        let app = launch()
        SageUI.waitForHome(app)

        var found = survey(app, "Cal", types: Self.enforced)

        for (identifier, name) in [
            ("dest-settings", "Settings"), ("dest-practices", "Practices"),
            ("dest-map", "Campus map"),
        ] {
            SageUI.open(app, identifier)
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
            found += survey(app, name, types: Self.enforced)
            SageUI.pop(app)
        }

        XCTAssertTrue(
            found.isEmpty,
            "\(found.count) accessibility regressions:\n" + found.joined(separator: "\n")
        )
    }

    /// The paywall's controls, where the undersized hit targets were found.
    func testPaywallHasNoEnforcedAuditIssues() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
    }

    func testAccessibilitySurveyOfThePaywall() throws {
        throw XCTSkip("Paywall is unreachable while the demo has no premium gating.")
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
