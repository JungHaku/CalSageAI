import CalDesign
import CalKit
import SwiftUI
import Testing
import UIKit

@testable import Cal

/// Layout regression tests, by measurement rather than by pixels.
///
/// ## Why not image snapshots
///
/// `swift-snapshot-testing` was investigated and declined — but not for the
/// reason first reported. An initial finding claimed achromatic SwiftUI snapshots
/// were broken by an upstream grayscale bug. Re-testing refuted that: the failing
/// cases were views with **no explicit size**, where the library records its own
/// error placeholder image and then compares against it. Sized views round-trip
/// correctly, on 1.19.2 and 1.19.4 alike. Image snapshots work.
///
/// What actually rules them out here is the CI:
///
/// 1. **Xcode Cloud has no source tree at test time**, so file-based baselines
///    have nowhere to live.
/// 2. **Its toolchain trails this machine's**, so baselines recorded locally would
///    fail remotely for reasons unrelated to the code.
///
/// `UIHostingController.sizeThatFits(in:)` sidesteps both: deterministic, no
/// baseline files, milliseconds per case. It also earned its place immediately by
/// catching a real bug — `ScoreScale` held its numeral in a fixed-height frame, so
/// the figure scaled and was then clipped by its own container.
@Suite("Layout regression")
@MainActor
struct LayoutRegressionTests {

    /// The narrowest screen this app supports. iPhone SE (3rd generation) at
    /// iOS 18 is 375pt; anything that overflows here overflows for real people.
    static let narrowestWidth: CGFloat = 375

    private func measure(
        _ view: some View,
        width: CGFloat = narrowestWidth,
        typeSize: DynamicTypeSize = .large
    ) -> CGSize {
        let controller = UIHostingController(rootView: AnyView(view.dynamicTypeSize(typeSize)))
        controller.view.backgroundColor = .clear
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    // MARK: The scale — the most-used control in the app

    @Test("the rating scale fits the narrowest supported screen")
    func scaleFitsNarrowScreen() {
        @State var score: Score? = Score(clamping: 7)
        let size = measure(ScoreScale(score: .constant(Score(clamping: 7))))

        #expect(size.width <= Self.narrowestWidth, "the scale is \(size.width)pt wide on a 375pt screen")
        #expect(size.height > 0)
    }

    /// The direct test of the `DisplayNumeral` fix. Before it, this numeral was
    /// `.font(.system(size: 56))` and did not grow at all — the assertion below
    /// would have failed with the two heights equal.
    @Test("the scale's numeral actually grows with Dynamic Type")
    func scaleGrowsWithTypeSize() {
        let standard = measure(ScoreScale(score: .constant(Score(clamping: 7))))
        let accessible = measure(
            ScoreScale(score: .constant(Score(clamping: 7))),
            typeSize: .accessibility5
        )

        #expect(
            accessible.height > standard.height,
            "the scale did not grow at AX5 (\(standard.height) → \(accessible.height)) — a fixed font size has crept back in"
        )
    }

    @Test("the scale still fits the narrowest screen at every Dynamic Type size",
          arguments: DynamicTypeSize.allCases)
    func scaleFitsAtEverySize(typeSize: DynamicTypeSize) {
        let size = measure(ScoreScale(score: .constant(Score(clamping: 3))), typeSize: typeSize)
        #expect(
            size.width <= Self.narrowestWidth + 1,
            "at \(typeSize) the scale is \(size.width)pt wide, overflowing a 375pt screen"
        )
    }

    // MARK: The display modifiers themselves

    @Test("displayNumeral scales, where a bare system font size does not")
    func displayNumeralScales() {
        let scaled = measure(Text("+2.0").displayNumeral(size: 52))
        let scaledLarge = measure(Text("+2.0").displayNumeral(size: 52), typeSize: .accessibility5)
        #expect(scaledLarge.height > scaled.height, "displayNumeral is not scaling")

        // The counterexample, asserted so the difference is documented in code:
        // this is what the app used to do everywhere.
        let fixed = measure(Text("+2.0").font(.system(size: 52)))
        let fixedLarge = measure(Text("+2.0").font(.system(size: 52)), typeSize: .accessibility5)
        #expect(
            fixedLarge.height == fixed.height,
            "a bare .system(size:) unexpectedly scaled — if SwiftUI changed this, displayNumeral may be redundant"
        )
    }

    /// Shrink-to-fit is part of `DisplayNumeral`'s contract: a figure that scales
    /// correctly and then clips has not been fixed.
    @Test("a long figure at AX5 still fits within the screen width")
    func longNumeralDoesNotOverflow() {
        let size = measure(Text("-10.0").displayNumeral(size: 56), typeSize: .accessibility5)
        #expect(size.width <= Self.narrowestWidth + 1, "numeral is \(size.width)pt wide")
    }

    @Test("a decorative glyph grows too, so it doesn't shrink against the text")
    func glyphScales() {
        let standard = measure(Image(systemName: "checkmark.seal.fill").displayGlyph(size: 52))
        let large = measure(
            Image(systemName: "checkmark.seal.fill").displayGlyph(size: 52),
            typeSize: .accessibility5
        )
        #expect(large.height > standard.height)
    }
}
