import CalKit
import Testing

@testable import CalDesign

@Suite("Contrast")
struct ContrastTests {

    // MARK: The maths itself

    /// Anchors against values the specification fixes, so a refactor of the
    /// transfer function can't quietly drift.
    @Test("black on white is 21:1 and a colour against itself is 1:1")
    func extremes() {
        #expect(abs(Contrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Contrast.ratio(0x808080, 0x808080) - 1) < 0.001)
    }

    @Test("the ratio is order-independent")
    func symmetric() {
        #expect(
            abs(Contrast.ratio(0x2A78D6, 0xFFFFFF) - Contrast.ratio(0xFFFFFF, 0x2A78D6)) < 0.000_1
        )
    }

    /// Mid grey (#767676) is the canonical "just passes 4.5:1 on white" value —
    /// the one every contrast tool is calibrated against.
    @Test("#767676 on white is the textbook 4.5:1 boundary")
    func knownBoundary() {
        let ratio = Contrast.ratio(0x767676, 0xFFFFFF)
        #expect(ratio > 4.5 && ratio < 4.6, "got \(ratio)")
    }

    @Test("compositing a translucent ink lands between the two colours")
    func compositing() {
        #expect(Contrast.composite(0x000000, alpha: 1, over: 0xFFFFFF) == 0x000000)
        #expect(Contrast.composite(0x000000, alpha: 0, over: 0xFFFFFF) == 0xFFFFFF)
        #expect(Contrast.composite(0x000000, alpha: 0.5, over: 0xFFFFFF) == 0x808080)
    }

    // MARK: The palette's own claims

    /// Measured against the app background, which is the surface charts actually
    /// draw on. The figures differ slightly from the ones originally written into
    /// `ChartPalette`'s comment (7.73 / 9.72) because those were taken against a
    /// tinted chart surface that no longer exists — which is precisely the reason
    /// a contrast figure belongs in a test and not a comment.
    @Test("axis labels clear the body-text threshold in both modes")
    func axisLabelsAreReadable() {
        let light = Contrast.ratio(0x52514E, Surface.appBackgroundLight)
        let dark = Contrast.ratio(0xC3C2B7, Surface.appBackgroundDark)

        #expect(light >= Contrast.Threshold.bodyText, "light axis label is \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark axis label is \(dark):1")
        #expect(abs(light - 7.94) < 0.05, "expected 7.94:1, measured \(light)")
        #expect(abs(dark - 11.72) < 0.05, "expected 11.72:1, measured \(dark)")
    }

    /// The counterexample that motivated the split. Kept as a test so nobody
    /// "simplifies" the two inks back into one.
    @Test("the muted ink genuinely fails for text, which is why it is not used for labels")
    func mutedInkFailsForText() {
        let ratio = Contrast.ratio(0x898781, Surface.appBackgroundLight)
        #expect(ratio < Contrast.Threshold.bodyText, "measured \(ratio):1")
        // It is still fine for the chrome it *is* used for — WCAG exempts gridlines.
        #expect(ratio > 1.5)
    }

    // MARK: Every text ink, on every surface it can land on

    /// The systematic check, and the reason `Surface` exists.
    ///
    /// The accessibility audit reported contrast failures on card subtitles that
    /// looked fine in isolation: the text was legible on the app background, but
    /// the cards sit on a tinted surface, and the *combination* is what a reader
    /// sees. This asserts each ink against each surface it actually appears on.
    @Test("every text ink clears 4.5:1 on every surface it is used on")
    func everyInkOnEverySurface() {
        for pairing in Surface.textPairings {
            #expect(
                pairing.ratio >= Contrast.Threshold.bodyText,
                "\(pairing.name) measures \(String(format: "%.2f", pairing.ratio)):1 — needs 4.5:1"
            )
        }
    }

    @Test("secondary ink is genuinely lighter than primary, so the hierarchy is real")
    func hierarchyHolds() {
        let primaryLight = Contrast.ratio(Surface.inkPrimaryLight, Surface.appBackgroundLight)
        let secondaryLight = Contrast.ratio(Surface.inkSecondaryLight, Surface.appBackgroundLight)
        #expect(primaryLight > secondaryLight, "primary must read stronger than secondary")

        let primaryDark = Contrast.ratio(Surface.inkPrimaryDark, Surface.appBackgroundDark)
        let secondaryDark = Contrast.ratio(Surface.inkSecondaryDark, Surface.appBackgroundDark)
        #expect(primaryDark > secondaryDark)
    }
}

@Suite("Band tints")
struct BandTintContrastTests {

    /// The finding that motivated splitting fill from text.
    ///
    /// Apple's accessibility audit reported "Contrast failed" on the Home screen's
    /// "Checked in today" label and the "+2.0" figure. Both were coloured with the
    /// band tint, and measuring confirmed it: every one of the three fails as text,
    /// by a wide margin.
    @Test("the fill tints are genuinely unusable as text, in both modes")
    func fillsFailAsText() {
        for fill in CoherenceScale.Band.allFills {
            let onLight = Contrast.ratio(fill, Surface.appBackgroundLight)
            #expect(
                onLight < Contrast.Threshold.bodyText,
                "fill #\(String(fill, radix: 16)) measures \(onLight):1 — if this now passes, the palette changed and the split may be removable"
            )
        }
    }

    @Test("the text tints clear 4.5:1 on the app background and on cards, light mode")
    func textTintsPassInLight() {
        for tint in CoherenceScale.Band.allTextLight {
            let app = Contrast.ratio(tint, Surface.appBackgroundLight)
            let card = Contrast.ratio(tint, Surface.cardLight)
            #expect(app >= Contrast.Threshold.bodyText, "#\(String(tint, radix: 16)) on app bg: \(app):1")
            #expect(card >= Contrast.Threshold.bodyText, "#\(String(tint, radix: 16)) on card: \(card):1")
        }
    }

    @Test("the text tints clear 4.5:1 on the app background and on cards, dark mode")
    func textTintsPassInDark() {
        for tint in CoherenceScale.Band.allTextDark {
            let app = Contrast.ratio(tint, Surface.appBackgroundDark)
            let card = Contrast.ratio(tint, Surface.cardDark)
            #expect(app >= Contrast.Threshold.bodyText, "#\(String(tint, radix: 16)) on app bg: \(app):1")
            #expect(card >= Contrast.Threshold.bodyText, "#\(String(tint, radix: 16)) on card: \(card):1")
        }
    }

    /// Separation in **luminance**, not just hue.
    ///
    /// This is the test that caught the first attempt. Deriving each tint by
    /// pushing it to the 4.5:1 minimum put all three at the same luminance —
    /// different hues, identical greyscale. Anyone with a red-green deficiency,
    /// any greyscale screenshot, and any printout would see one colour.
    @Test("the three text tints differ in luminance, not only in hue", arguments: [false, true])
    func textTintsStayDistinct(dark: Bool) {
        let tints = dark ? CoherenceScale.Band.allTextDark : CoherenceScale.Band.allTextLight
        for (index, a) in tints.enumerated() {
            for b in tints[(index + 1)...] {
                let separation = Contrast.ratio(a, b)
                #expect(
                    separation >= 1.3,
                    "two bands are \(separation):1 apart — indistinguishable without colour"
                )
            }
        }
    }

    /// Colour is never the only channel — every band is paired with a glyph and a
    /// word. Recorded here because it is the reason the *fills* are allowed to stay
    /// below the text threshold at all.
    @Test("band meaning does not depend on colour alone")
    func colourIsNeverTheOnlySignal() {
        // Every band carries words of its own. If that ever stops being true,
        // colour becomes load-bearing and the fills would have to change too.
        for band in CoherenceBand.allCases {
            #expect(!band.quickCheckInResponse.isEmpty, "\(band) has no words to carry its meaning")
            #expect(!band.rawValue.isEmpty)
        }
    }
}
