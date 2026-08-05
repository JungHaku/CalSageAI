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
        for pairing in Surface.allTextPairings {
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

@Suite("Brand")
struct BrandContrastTests {

    /// The constraint that survived the accent changing from slate to sage.
    ///
    /// The *rule* was never "the accent must not be green" — it was "the accent
    /// must not be mistakable for a coherence reading". Slate satisfied that by
    /// being a different hue; the deep sage satisfies it by being a different
    /// *value* of the same hue, 2.19:1 from the high band where the logo green
    /// was 1.23:1.
    ///
    /// So this still asserts the thing that matters, and it is what fails if
    /// anyone lightens `action` back toward the logo swatch.
    @Test("the action colour is separable from every coherence band")
    func accentDoesNotReadAsAReading() {
        for fill in CoherenceScale.Band.allFills {
            let separation = Contrast.ratio(Brand.actionLight, fill)
            #expect(
                separation >= 2.0,
                "action is \(separation):1 from band fill #\(String(fill, radix: 16)) — a button would read as a score"
            )
        }
    }

    /// The action fill carries a label, so the pair has to clear 4.5:1 — the same
    /// trap `onSlate` exists for, one token over.
    @Test("a label on the action fill is legible")
    func actionCarriesItsLabel() {
        let light = Contrast.ratio(Brand.onActionLight, Brand.actionLight)
        let dark = Contrast.ratio(Brand.onActionDark, Brand.actionDark)
        #expect(light >= Contrast.Threshold.bodyText, "light measures \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark measures \(dark):1")
    }

    /// Why `action` is not simply `Brand.sage`, recorded so nobody "simplifies"
    /// the two into one token and quietly drops every button below 4.5:1.
    @Test("the lighter sages cannot carry a white label, which is why action is darker")
    func lighterSagesFailAsButtons() {
        for tooLight in [0x6B9B85 as UInt32, Brand.sageLight] {
            let ratio = Contrast.ratio(0xFFFFFF, tooLight)
            #expect(ratio < Contrast.Threshold.bodyText, "#\(String(tooLight, radix: 16)) measures \(ratio):1")
        }
    }

    /// The regression test for a defect that shipped.
    ///
    /// `slate` is an ink pair — dark on light, light on dark — so it reads against
    /// the page. Used as a *fill* the relationship inverts, and the dark-mode
    /// value stops working: white on `#A8B6C8` is 2.06:1. Light mode measured
    /// 8.60:1 and looked perfectly fine, which is why this needs a number rather
    /// than an eye.
    @Test("a label on a slate fill is legible in both modes, not just the light one")
    func filledSlateCarriesItsLabel() {
        let light = Contrast.ratio(Brand.onSlateLight, Brand.slateLight)
        let dark = Contrast.ratio(Brand.onSlateDark, Brand.slateDark)

        #expect(light >= Contrast.Threshold.bodyText, "light mode measures \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark mode measures \(dark):1")
    }

    /// States the trap directly, so that reintroducing `.white` as the label on a
    /// slate fill is a failing test rather than a design review someone has to
    /// remember to do.
    @Test("plain white is NOT a safe label on slate — that is why onSlate exists")
    func whiteAloneIsNotEnough() {
        let naive = Contrast.ratio(0xFFFFFF, Brand.slateDark)
        #expect(
            naive < Contrast.Threshold.bodyText,
            "white on dark-mode slate now measures \(naive):1 — if this passes, the palette changed and onSlate may be collapsible"
        )
    }

    /// The measurement that motivated confining sage and gold to identity
    /// surfaces. Kept as a test so the rationale is checkable rather than merely
    /// asserted in prose.
    @Test("the brand hues genuinely collide with the bands they are kept away from")
    func theCollisionIsReal() {
        #expect(Contrast.ratio(Brand.sageLight, CoherenceScale.Band.highFill) < 1.6)
        #expect(Contrast.ratio(Brand.goldLight, CoherenceScale.Band.moderateFill) < 1.6)
    }

    /// Fills carry shapes, so WCAG 1.4.11 asks 3.0:1 — on both surfaces, in both
    /// modes. The logo's own `#6B9B85` measured 2.79:1 on a card and failed this;
    /// `Brand.sageLight` is the darkened value that passes.
    @Test("meaningful fills clear the non-text threshold on every surface")
    func fillsClearNonText() {
        for fill in Brand.meaningfulFills {
            let surfaces: [(String, UInt32, UInt32)] = [
                ("app background (light)", fill.light, Surface.appBackgroundLight),
                ("card (light)", fill.light, Surface.cardLight),
                ("app background (dark)", fill.dark, Surface.appBackgroundDark),
                ("card (dark)", fill.dark, Surface.cardDark),
            ]
            for (where_, ink, background) in surfaces {
                let ratio = Contrast.ratio(ink, background)
                #expect(
                    ratio >= Contrast.Threshold.nonText,
                    "\(fill.name) on \(where_) measures \(ratio):1 — needs 3.0:1"
                )
            }
        }
    }

    /// The counterexample, in the same spirit as `mutedInkFailsForText`.
    ///
    /// Gold is kept at the logo's exact value because haloes and hairlines are
    /// the one place brand fidelity outranks contrast — and WCAG exempts both.
    /// This asserts it is *below* the non-text threshold, so nobody can reach for
    /// it to fill a shape that means something and believe they are safe.
    @Test("decorative gold is not usable for meaningful graphics, which is why goldInk exists")
    func goldIsDecorativeOnly() {
        let ratio = Contrast.ratio(Brand.goldLight, Surface.appBackgroundLight)
        #expect(
            ratio < Contrast.Threshold.nonText,
            "gold now measures \(ratio):1 — if this passes, the value changed and the split may be removable"
        )
        #expect(ratio > 1.5)
    }

    /// Dark mode is chosen, not derived. Both sage tokens converge on one value
    /// there because the light-mode reason for splitting them — a fill too light
    /// to read against white — inverts and disappears against black.
    @Test("sage collapses to a single token in dark mode, deliberately")
    func sageIsOneColourInDarkMode() {
        #expect(Brand.sageDark == Brand.sageInkDark)
        #expect(Brand.goldDark == Brand.goldInkDark)
        // And they are genuinely different in light mode, which is the half that
        // matters.
        #expect(Brand.sageLight != Brand.sageInkLight)
        #expect(Brand.goldLight != Brand.goldInkLight)
    }

    /// The reason there is no `cream` token.
    @Test("the logo's off-white is the card surface already, not a new one")
    func creamWouldBeARedundantSurface() {
        let logoCream: UInt32 = 0xF7F4EC
        let separation = Contrast.ratio(logoCream, Surface.cardLight)
        #expect(separation < 1.1, "measured \(separation):1 — same colour, so one token is enough")
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
