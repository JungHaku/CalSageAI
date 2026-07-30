import Foundation
import Testing

@testable import CalKit

@Suite("CrisisDetector — Layer A")
struct CrisisDetectorTests {
    let detector = CrisisDetector()

    // The reviewed fixture set is the contract. Adding a case here is how the
    // detector is allowed to change (§9.4).
    @Test("reviewed fixture set", arguments: CrisisFixture.all)
    func fixtures(_ fixture: CrisisFixture) {
        let assessment = detector.evaluate(fixture.text)
        #expect(
            assessment.severity == fixture.expected,
            """
            "\(fixture.text)"
              expected \(fixture.expected), got \(assessment.severity) \
            (rule: \(assessment.matchedRule ?? "none"))
              rationale: \(fixture.rationale)
            """
        )
    }

    @Test("acute matches report which rule fired, for the safety_events audit trail")
    func reportsMatchedRule() {
        let assessment = detector.evaluate("I want to kill myself")
        #expect(assessment.severity == .acute)
        #expect(assessment.matchedRule == "kill myself")
    }

    @Test("detection is case- and punctuation-insensitive")
    func normalizationIsRobust() {
        for variant in [
            "I WANT TO KILL MYSELF",
            "i want to kill myself.",
            "I want to... kill myself!!!",
            "I  want   to\nkill\tmyself",
        ] {
            #expect(detector.evaluate(variant).severity == .acute, "missed: \(variant)")
        }
    }

    @Test("straight and curly apostrophes are treated identically")
    func apostropheVariants() {
        #expect(detector.evaluate("I don't want to be here anymore").severity == .acute)
        #expect(detector.evaluate("I don\u{2019}t want to be here anymore").severity == .acute)
        #expect(detector.evaluate("I dont want to be here anymore").severity == .acute)
    }

    @Test("acute outranks elevated when both appear")
    func acuteWins() {
        #expect(detector.evaluate("I've been hurting myself and I feel suicidal").severity == .acute)
    }

    // Word-boundary matching: substrings inside longer words must not fire, or the
    // detector cries wolf and users learn to dismiss the card.
    @Test("substrings inside unrelated words do not fire")
    func noSubstringFalsePositives() {
        for benign in [
            "the class is a suicidemission of a schedule",
            "I read about overdosespectroscopy",
        ] {
            #expect(detector.evaluate(benign).severity == .none, "false positive on: \(benign)")
        }
    }

    @Test("normalization pads and collapses so patterns match on word boundaries")
    func normalizeShape() {
        #expect(CrisisDetector.normalize("Hello, World!") == " hello world ")
        #expect(CrisisDetector.normalize("don't") == " dont ")
        #expect(CrisisDetector.normalize("   ") == " ")
        #expect(CrisisDetector.normalize("") == " ")
    }

    @Test("benign help-seeking phrases are stripped before matching")
    func benignPhraseStripping() {
        // The app's own crisis copy, quoted back, must not re-trigger.
        #expect(detector.evaluate("call the Suicide and Crisis Lifeline").severity == .none)
        #expect(detector.evaluate("is there a crisis text line?").severity == .none)
        // But a real disclosure alongside a benign phrase still fires.
        #expect(
            detector.evaluate("I know about the suicide prevention line but I feel suicidal").severity == .acute
        )
    }

    @Test("very long input is handled without pathological behaviour")
    func longInput() {
        let padding = String(repeating: "I am stressed about midterms. ", count: 500)
        #expect(detector.evaluate(padding).severity == .none)
        #expect(detector.evaluate(padding + "I want to kill myself").severity == .acute)
    }
}
