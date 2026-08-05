import SwiftUI

/// The WholeLife Ministries palette — sage, gold, and slate.
///
/// ## The green, and the scale it has to coexist with
///
/// `CoherenceScale` is not decoration. Green means *high coherence*, amber means
/// *moderate*, red means *low*, and a student learns that scale in their first
/// week. The brand is sage green and gold — the same two hues.
///
/// The first version of this file made `slate` the interactive colour for exactly
/// that reason, and confined sage and gold to identity surfaces. The measurement
/// behind it still stands: the logo's own sage sits **1.23:1** from the high-band
/// fill and its gold **1.30:1** from the moderate one, which is to say they are
/// those colours.
///
/// That was overruled, correctly. An app built for a sage-and-gold brand that
/// renders as white and blue-grey is not that brand's app, and looking like the
/// client is a real requirement rather than a soft one.
///
/// What makes it safe is *which* green:
///
/// - **`action` is the deep sage `#45705C`,** not the logo's `#6B9B85`. Forced,
///   not chosen — a white label on the logo green is 3.16:1 and fails. The deep
///   one is 5.64:1, and it sits 2.19:1 from the high-band fill rather than
///   1.23:1: a different colour, not the same one.
/// - **`gold` still never carries meaning.** It measures 2.40:1 and fails even
///   the non-text threshold, so it stays on haloes and hairlines regardless of
///   what anyone wants it to do.
/// - **The bands never depend on colour alone.** Every one carries a word and a
///   glyph, asserted by `colourIsNeverTheOnlySignal`. That is what makes a green
///   button elsewhere survivable: hue is not load-bearing for the scale.
///
/// The three band hues are left exactly as they are. They are tuned to *separated*
/// luminance so they survive greyscale, print, and red-green colour deficiency;
/// nudging them to be more on-brand would undo that, and `BandTintContrastTests`
/// would catch it — correctly.
///
/// ## Why there is no `cream`
///
/// The logo's warm off-white is `#F7F4EC`. `Surface.cardLight` is already
/// `#F2F1EC`, and the two measure **1.029:1** apart — the same colour, by any
/// standard a person or a test can apply. The card surface was chosen warm for
/// the same reason the logo is. Adding a third near-identical off-white would be
/// palette weight with nothing behind it, so the existing token is the cream.
///
/// ## Fill versus ink
///
/// Same split as `CoherenceScale`, for the same reason: a colour that is legible
/// as a shape is often illegible as a letter. Every token below states which it
/// is, and `BrandContrastTests` asserts it — including the negative cases, so the
/// pairs cannot be quietly merged back together.
public enum Brand {

    // MARK: Raw values
    //
    // `UInt32` rather than `Color` so `Contrast` can measure them. The `Color`
    // tokens below are built from these, so what is tested is what is drawn.

    /// **The primary action colour.** Buttons, links, tab selection, the accent.
    ///
    /// This was `slate`, on the reasoning below, and it changed on the client's
    /// direction: an app for a sage-and-gold brand that renders almost entirely
    /// white and blue-grey does not look like the brand. That is a fair call and
    /// it outranks the tidiness of the original scheme.
    ///
    /// It is the *deep* sage rather than the logo's own `#6B9B85`, and that is
    /// forced rather than chosen. Two constraints pushed it darker, in order:
    ///
    /// 1. A white label on the logo green measures 3.16:1, under the 4.5:1 a
    ///    button label needs. This measures **7.03:1**.
    /// 2. `#45705C` cleared that but sat **1.76:1** from the *low* band — the
    ///    terracotta. Green against terracotta is a large hue difference and a
    ///    small luminance one, which is precisely the pair that red-green colour
    ///    deficiency collapses. A test caught it; the eye would not have.
    ///
    /// **What the original decision was protecting, and how it is handled now.**
    /// `CoherenceScale` uses green for high coherence, so a green button risks
    /// reading as a score. Two things keep that tolerable: this green clears 2.0:1
    /// against **all three** band fills — 2.19, 3.80 and 2.73 — where the logo
    /// green was 1.23:1 from the high band, and every band already carries a word
    /// and a glyph, which
    /// `colourIsNeverTheOnlySignal` asserts. Colour is not load-bearing for the
    /// scale, so a green elsewhere cannot destroy it.
    public static let actionLight: UInt32 = 0x38614E
    public static let actionDark: UInt32 = 0x8FBFA8

    /// What is legible **on** an action fill. Same trap as `onSlate` — see there.
    public static let onActionLight: UInt32 = 0xFFFFFF
    public static let onActionDark: UInt32 = 0x10201A

    /// **Secondary / chrome.** Still the logo's slate, still safe everywhere —
    /// 8.60:1 on the app background, 7.61:1 on a card — and still close to Cal's
    /// trousers. It keeps the neutral roles it always had; it is simply no longer
    /// what a primary button is painted with.
    public static let slateLight: UInt32 = 0x414D5C
    public static let slateDark: UInt32 = 0xA8B6C8

    /// What is legible **on top of** a slate fill.
    ///
    /// `slate` is an *ink* pair: dark in light mode, light in dark mode, so it
    /// reads against the page in both. Invert the relationship — put it behind a
    /// label instead of in one — and the dark-mode value stops working, because
    /// white on `#A8B6C8` measures **2.06:1**.
    ///
    /// That is not hypothetical. It shipped: the accent colour was set from
    /// `slate` alone, so every filled control inherited it, and the chat's user
    /// bubble drew `Color.white` on top. In light mode it was 8.60:1 and looked
    /// fine, which is exactly why nobody would have caught it by eye.
    ///
    /// So the fill takes an ink that flips with it: white in light mode, near-black
    /// in dark. `BrandContrastTests` asserts both directions.
    public static let onSlateLight: UInt32 = 0xFFFFFF
    public static let onSlateDark: UInt32 = 0x16202B

    /// **Fill only** — meaningful graphics and shapes, never letters. Darkened
    /// from the logo's own `#6B9B85`, which measured 2.79:1 on a card and so
    /// failed even the 3.0 that WCAG 1.4.11 asks of a meaningful graphic. This
    /// clears it on every surface with room to spare.
    public static let sageLight: UInt32 = 0x5C8A75
    public static let sageDark: UInt32 = 0x8FBFA8

    /// **Text-safe sage.** Section headers, wordmarks, anything read rather than
    /// seen. Hue and saturation are held; only lightness moved, so it still reads
    /// as the brand green.
    public static let sageInkLight: UInt32 = 0x45705C
    public static let sageInkDark: UInt32 = 0x8FBFA8

    /// **Decorative only.** The logo's gold, kept exact because this is the one
    /// place brand fidelity is worth more than contrast: haloes, hairline
    /// dividers, and illustration accents, all of which WCAG exempts.
    ///
    /// It measures 2.40:1 on the app background. That is below the *non-text*
    /// threshold, not merely the text one — so it must never carry a shape whose
    /// presence or boundary means something. `goldInk` exists for when gold has
    /// to be legible, and a test asserts this one is not.
    public static let goldLight: UInt32 = 0xC9A24B
    public static let goldDark: UInt32 = 0xD9B96B

    /// **Text-safe gold.** 5.75:1 on the app background. Dark mode can use the
    /// decorative gold directly — against black it already measures 11.10:1, so
    /// the split only bites in light mode.
    public static let goldInkLight: UInt32 = 0x7E6220
    public static let goldInkDark: UInt32 = 0xD9B96B

    // MARK: Tokens

    /// The accent. Also what `AccentColor` in the asset catalogue is set to, so an
    /// unstyled SwiftUI control picks up the brand rather than system blue.
    public static let action = Color(light: actionLight, dark: actionDark)
    /// The label colour for anything drawn on `action`. Always paired with it.
    public static let onAction = Color(light: onActionLight, dark: onActionDark)

    public static let slate = Color(light: slateLight, dark: slateDark)

    /// The label colour for anything drawn **on** `slate`. Always paired with it —
    /// a slate fill with a hardcoded `.white` label is the bug this exists to
    /// prevent.
    public static let onSlate = Color(light: onSlateLight, dark: onSlateDark)

    public static let sage = Color(light: sageLight, dark: sageDark)
    public static let sageInk = Color(light: sageInkLight, dark: sageInkDark)

    public static let gold = Color(light: goldLight, dark: goldDark)
    public static let goldInk = Color(light: goldInkLight, dark: goldInkDark)

    // MARK: Validation

    /// Brand inks against every surface they land on, in the shape
    /// `ContrastTests` already iterates. Text-safe tokens only — the fills are
    /// checked separately, against the lower non-text threshold, because holding
    /// them to 4.5:1 would be asserting something the design does not claim.
    public static let textPairings: [Surface.Pairing] = [
        Pairing(name: "action on app background (light)", ink: actionLight, background: Surface.appBackgroundLight),
        Pairing(name: "action on card (light)", ink: actionLight, background: Surface.cardLight),

        Pairing(name: "slate on app background (light)", ink: slateLight, background: Surface.appBackgroundLight),
        Pairing(name: "slate on card (light)", ink: slateLight, background: Surface.cardLight),
        Pairing(name: "slate on app background (dark)", ink: slateDark, background: Surface.appBackgroundDark),
        Pairing(name: "slate on card (dark)", ink: slateDark, background: Surface.cardDark),

        Pairing(name: "sage ink on app background (light)", ink: sageInkLight, background: Surface.appBackgroundLight),
        Pairing(name: "sage ink on card (light)", ink: sageInkLight, background: Surface.cardLight),
        Pairing(name: "sage ink on app background (dark)", ink: sageInkDark, background: Surface.appBackgroundDark),
        Pairing(name: "sage ink on card (dark)", ink: sageInkDark, background: Surface.cardDark),

        Pairing(name: "gold ink on app background (light)", ink: goldInkLight, background: Surface.appBackgroundLight),
        Pairing(name: "gold ink on card (light)", ink: goldInkLight, background: Surface.cardLight),
        Pairing(name: "gold ink on app background (dark)", ink: goldInkDark, background: Surface.appBackgroundDark),
        Pairing(name: "gold ink on card (dark)", ink: goldInkDark, background: Surface.cardDark),
    ]

    /// The fills that carry meaning, and therefore owe 3.0:1 under WCAG 1.4.11.
    /// `gold` is deliberately absent — it is decorative and does not clear it.
    public static let meaningfulFills: [(name: String, light: UInt32, dark: UInt32)] = [
        (name: "action", light: actionLight, dark: actionDark),
        (name: "sage", light: sageLight, dark: sageDark),
        (name: "slate", light: slateLight, dark: slateDark),
    ]
}

/// Shorthand so the pairing list above reads as a table rather than as a wall of
/// `Surface.Pairing(...)`.
private func Pairing(name: String, ink: UInt32, background: UInt32) -> Surface.Pairing {
    Surface.Pairing(name: name, ink: ink, background: background)
}
