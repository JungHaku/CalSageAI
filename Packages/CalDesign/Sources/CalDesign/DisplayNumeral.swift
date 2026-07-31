import SwiftUI

/// A large display figure — a hero number, a countdown, a chosen score — that
/// still honours Dynamic Type.
///
/// ## Why this exists
///
/// `.font(.system(size: 52))` looks like it scales and does not. Apple's own
/// accessibility audit reports it as *"Dynamic Type font sizes are unsupported"*,
/// and the app had six of them: the Progress hero delta, the check-in result, the
/// study countdown, and the coherence scale's own numeral. Someone running at an
/// accessibility text size got a 52pt number frozen at 52pt while everything
/// around it grew.
///
/// `@ScaledMetric` is the fix — it scales a raw point size against a text style
/// the same way the system scales the style itself.
///
/// The single-line shrink-to-fit is part of the contract rather than a caller's
/// afterthought: at AX5 a 52pt numeral becomes well over 100pt, and a figure that
/// scales correctly and then clips is no better than one that never scaled.
public struct DisplayNumeral: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    public init(
        size: CGFloat,
        weight: Font.Weight = .semibold,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .largeTitle
    ) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    public func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: design))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }
}

extension View {
    /// See `DisplayNumeral`. Use for figures, not for body copy — body copy should
    /// use a text style directly.
    public func displayNumeral(
        size: CGFloat,
        weight: Font.Weight = .semibold,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .largeTitle
    ) -> some View {
        modifier(DisplayNumeral(size: size, weight: weight, design: design, relativeTo: textStyle))
    }

    /// A decorative glyph that grows with the text around it.
    ///
    /// Separate from `displayNumeral` because it must *not* get the shrink-to-fit
    /// treatment — an SF Symbol has no text to shrink, and `minimumScaleFactor` on
    /// one silently does nothing.
    public func displayGlyph(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .largeTitle
    ) -> some View {
        modifier(DisplayGlyph(size: size, relativeTo: textStyle))
    }
}

public struct DisplayGlyph: ViewModifier {
    @ScaledMetric private var size: CGFloat

    public init(size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: size))
    }
}
