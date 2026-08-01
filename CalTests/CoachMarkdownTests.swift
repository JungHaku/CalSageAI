import Foundation
import Testing

@testable import Cal

/// `@MainActor` because Xcode sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on
/// app targets, so everything in the `Cal` module is implicitly isolated to it
/// (ARCHITECTURE.md §4).
@Suite("Coach markdown")
@MainActor
struct CoachMarkdownTests {

    /// The defect this exists for. The live model replied "You said your
    /// chemistry midterm is on **Thursday**" and the screen showed the asterisks,
    /// because `Text(someString)` does not interpret markdown.
    @Test("emphasis is interpreted rather than shown as asterisks")
    func emphasisIsParsed() {
        let rendered = CoachMarkdown.rendered("your midterm is on **Thursday**")
        #expect(!String(rendered.characters).contains("*"))
        #expect(String(rendered.characters) == "your midterm is on Thursday")
    }

    /// The reason for `.inlineOnlyPreservingWhitespace`. Dr. Mia's scripts are
    /// line-broken because the pacing is the practice; the default `.full`
    /// syntax collapses these into one paragraph and the guidance stops being
    /// guidable.
    @Test("line breaks in a guided practice survive")
    func lineBreaksSurvive() {
        let script = """
        Close your eyes.
        Notice the stillness between each inhale and exhale.
        In the center of your heart, imagine a tiny golden spark.
        """
        let rendered = String(CoachMarkdown.rendered(script).characters)

        #expect(rendered.split(separator: "\n").count == 3, "got: \(rendered.debugDescription)")
        #expect(rendered.contains("Close your eyes."))
        #expect(rendered.contains("imagine a tiny golden spark."))
    }

    /// Runs on nearly every frame of a stream, against text that is by
    /// definition half-written. It must never lose what has arrived.
    @Test("half-written emphasis mid-stream keeps the text")
    func partialMarkdownIsSafe() {
        for partial in ["your midterm is on **Thu", "*", "**", "a **b"] {
            let rendered = String(CoachMarkdown.rendered(partial).characters)
            #expect(rendered.contains("Thu") || !partial.contains("Thu"))
            #expect(!rendered.isEmpty, "lost everything for \(partial.debugDescription)")
        }
    }

    @Test("plain text passes through unchanged")
    func plainTextUnchanged() {
        let text = "Let's take one slow breath together."
        #expect(String(CoachMarkdown.rendered(text).characters) == text)
    }

    @Test("the spoken label carries no markup")
    func plainStripsMarkup() {
        #expect(CoachMarkdown.plain("that is **really** heavy") == "that is really heavy")
    }

    @Test("an empty reply does not crash the renderer")
    func emptyIsSafe() {
        #expect(String(CoachMarkdown.rendered("").characters).isEmpty)
    }
}
