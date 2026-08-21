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

    /// Measured against the app background — the surface charts draw on.
    @Test("axis labels clear the body-text threshold on the field")
    func axisLabelsAreReadable() {
        let light = Contrast.ratio(Surface.inkSecondaryLight, Surface.appBackgroundLight)
        let dark = Contrast.ratio(Surface.inkSecondaryDark, Surface.appBackgroundDark)

        #expect(light >= Contrast.Threshold.bodyText, "light axis label is \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark axis label is \(dark):1")
    }

    /// The counterexample that motivated the muted/axis split. Kept so nobody
    /// "simplifies" the two inks back into one.
    @Test("the muted ink genuinely fails for text, which is why it is not used for labels")
    func mutedInkFailsForText() {
        let ratio = Contrast.ratio(0x6E857A, Surface.appBackgroundLight)
        #expect(ratio < Contrast.Threshold.bodyText, "measured \(ratio):1")
        // It is still fine for the chrome it *is* used for — WCAG exempts gridlines.
        #expect(ratio > 1.5)
    }

    // MARK: Every text ink, on every surface it can land on

    /// The systematic check, and the reason `Surface` exists.
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

    @Test("light and dark surface tokens converge on the product field")
    func singleProductLook() {
        #expect(Surface.appBackgroundLight == Surface.appBackgroundDark)
        #expect(Surface.cardLight == Surface.cardDark)
        #expect(Surface.inkPrimaryLight == Surface.inkPrimaryDark)
        #expect(Surface.inkSecondaryLight == Surface.inkSecondaryDark)
    }
}

@Suite("Brand")
struct BrandContrastTests {

    /// On the light field, deep sage action is distinct from the high band fill.
    @Test("the action colour is not identical to any coherence band fill")
    func accentIsNotABandSwatch() {
        for fill in CoherenceScale.Band.allFills {
            #expect(
                Brand.actionLight != fill,
                "action matches band fill #\(String(fill, radix: 16)) — a button would read as a score"
            )
            #expect(Brand.actionDark != fill)
        }
    }

    /// The action fill carries a label, so the pair has to clear 4.5:1.
    @Test("a label on the action fill is legible")
    func actionCarriesItsLabel() {
        let light = Contrast.ratio(Brand.onActionLight, Brand.actionLight)
        let dark = Contrast.ratio(Brand.onActionDark, Brand.actionDark)
        #expect(light >= Contrast.Threshold.bodyText, "light measures \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark measures \(dark):1")
    }

    /// Why filled controls use `onAction` (cream) rather than leaving the label
    /// to chance. Cream and white both clear 4.5:1 on the deep sage — the pair
    /// is still named so a future lighter action cannot quietly lose its label.
    @Test("cream and white are legible on action, which is why onAction is light")
    func lightLabelsPassOnAction() {
        for ink in [0xFFFFFF as UInt32, 0xF4F0E6] {
            let ratio = Contrast.ratio(ink, Brand.actionLight)
            #expect(ratio >= Contrast.Threshold.bodyText, "#\(String(ink, radix: 16)) measures \(ratio):1")
        }
    }

    @Test("a label on a slate fill is legible")
    func filledSlateCarriesItsLabel() {
        let light = Contrast.ratio(Brand.onSlateLight, Brand.slateLight)
        let dark = Contrast.ratio(Brand.onSlateDark, Brand.slateDark)

        #expect(light >= Contrast.Threshold.bodyText, "light mode measures \(light):1")
        #expect(dark >= Contrast.Threshold.bodyText, "dark mode measures \(dark):1")
    }

    @Test("plain white is a safe label on slate — onSlate is the paired cream token")
    func whiteIsSafeOnSlate() {
        let naive = Contrast.ratio(0xFFFFFF, Brand.slateDark)
        #expect(
            naive >= Contrast.Threshold.bodyText,
            "white on slate measures \(naive):1 — onSlate stays the named pair"
        )
    }

    /// Bronze stays near the moderate band fill it must not replace.
    @Test("the brand hues genuinely collide with the bands they are kept away from")
    func theCollisionIsReal() {
        #expect(Contrast.ratio(Brand.goldLight, CoherenceScale.Band.moderateFill) < 1.6)
    }

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

    /// Bronze is decorative by policy — kept out of `meaningfulFills` so nobody
    /// paints a score with it.
    @Test("decorative bronze is excluded from meaningful fills")
    func goldIsDecorativeOnly() {
        #expect(!Brand.meaningfulFills.contains(where: { $0.name == "gold" }))
        #expect(Brand.goldLight == 0xB8954A)
    }

    @Test("sage and gold tokens converge across appearances on the field")
    func tokensConvergeOnTheField() {
        #expect(Brand.sageLight == Brand.sageDark)
        #expect(Brand.sageInkLight == Brand.sageInkDark)
        #expect(Brand.goldLight == Brand.goldDark)
        #expect(Brand.goldInkLight == Brand.goldInkDark)
        #expect(Brand.actionLight == Brand.actionDark)
    }

    /// Primary ink is dark slate on the light field — not logo cream.
    @Test("the primary ink is dark, not a cream page")
    func creamIsNotTheReadingInk() {
        let logoCream: UInt32 = 0xF7F4EC
        let creamOnField = Contrast.ratio(logoCream, Surface.appBackgroundLight)
        #expect(creamOnField < 1.2, "measured \(creamOnField):1 — cream would vanish on the page")
        #expect(Surface.inkPrimaryLight != logoCream)
        #expect(Surface.cardLight != Surface.inkPrimaryLight)
    }
}

@Suite("Band tints")
struct BandTintContrastTests {

    /// On the cream page the fills failed as text; they still do on grey-white.
    /// The split exists so feature code never paints a numeral with a swatch —
    /// `textTint` is the reading path regardless.
    @Test("text tints exist as a separate path from fills")
    func textTintsAreNotJustTheFills() {
        for (fill, text) in zip(
            CoherenceScale.Band.allFills,
            CoherenceScale.Band.allTextDark
        ) {
            #expect(fill != text, "fill #\(String(fill, radix: 16)) was reused as text")
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
    /// word. Recorded here because it is the reason green chrome elsewhere is
    /// survivable on a green field.
    @Test("band meaning does not depend on colour alone")
    func colourIsNeverTheOnlySignal() {
        for band in CoherenceBand.allCases {
            #expect(!band.quickCheckInResponse.isEmpty, "\(band) has no words to carry its meaning")
            #expect(!band.rawValue.isEmpty)
        }
    }
}
