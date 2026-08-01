import Foundation

/// Renders Cal's replies, which arrive as markdown.
///
/// SwiftUI will not do this for us, and the reason is easy to miss:
/// `Text("**bold**")` interprets markdown because a string *literal* becomes a
/// `LocalizedStringKey`, while `Text(someStringVariable)` resolves to the
/// `StringProtocol` overload, which does not. So a model that writes
/// `**Thursday**` puts the asterisks on screen.
///
/// Found on the first live end-to-end run rather than in review — the mock coach
/// replies in plain prose, so every test and every preview looked correct.
enum CoachMarkdown {

    /// Cal's text, with markdown interpreted.
    ///
    /// `.inlineOnlyPreservingWhitespace` is the load-bearing choice. The default
    /// `.full` parses block elements but **collapses newlines**, and Cal guides
    /// practices one line at a time — Dr. Mia's scripts are line-broken because
    /// the pacing is the practice. Running "Close your eyes. / Notice the
    /// stillness. / Imagine a tiny golden spark." into a single paragraph would
    /// lose the thing that makes it guidable.
    ///
    /// The cost of that choice, stated plainly: markdown *lists* are no longer
    /// parsed, so a `- item` keeps its dash. That is the better trade for this
    /// app — a stray dash is untidy, a collapsed breathing script is unusable.
    ///
    /// Malformed input falls back to the raw string rather than throwing. This
    /// matters more than it looks: during streaming the text is routinely
    /// half-written (`"...is on **Thu"`), so this runs against incomplete
    /// markdown on nearly every frame. Unclosed emphasis simply stays literal
    /// until the closing token arrives.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }

    /// The same text with the markup removed, for VoiceOver.
    ///
    /// Without this the accessibility label carries the raw string and the
    /// syntax is spoken aloud — "star star Thursday star star".
    static func plain(_ text: String) -> String {
        String(rendered(text).characters)
    }
}
