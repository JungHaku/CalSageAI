import CalDesign
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
