import SwiftUI

/// The WholeLife Ministries palette — sage, bronze-gold, and slate — on the
/// light grey-white field.
///
/// ## The green, and the scale it has to coexist with
///
/// `CoherenceScale` is not decoration. Green means *high coherence*, amber means
/// *moderate*, red means *low*, and a student learns that scale in their first
/// week. The brand is sage green and bronze-gold. Action is deep sage chrome, not
/// a score; band meaning stays on **word + glyph** (`colourIsNeverTheOnlySignal`).
///
/// - **`action` is deep sage `#3F6F58`.** Filled controls on the light field;
///   `onAction` is cream so the label clears 4.5:1.
/// - **`gold` is bronze `#B8954A`, decorative only** — orb rings, haloes, hairlines.
///   It is kept out of `meaningfulFills` so it never carries a shape that means
///   something.
/// - **`goldInk` is readable bronze `#7A5A18`** when gold has to be letters.
///
/// ## Fill versus ink
///
/// Same split as `CoherenceScale`, for the same reason: a colour that is legible
/// as a shape is often illegible as a letter. Every token below states which it
/// is, and `BrandContrastTests` asserts it.
public enum Brand {

    // MARK: Raw values
    //
    // `UInt32` rather than `Color` so `Contrast` can measure them. The `Color`
    // tokens below are built from these, so what is tested is what is drawn.

    /// **The primary action colour.** Deep sage on the light field.
    public static let actionLight: UInt32 = 0x3F6F58
    public static let actionDark: UInt32 = 0x3F6F58

    /// What is legible **on** an action fill.
    public static let onActionLight: UInt32 = 0xF7F4EC
    public static let onActionDark: UInt32 = 0xF7F4EC

    /// **Secondary / chrome.** Logo slate, dark enough to read on the field.
    public static let slateLight: UInt32 = 0x4A5560
    public static let slateDark: UInt32 = 0x4A5560

    /// What is legible **on top of** a slate fill.
    public static let onSlateLight: UInt32 = 0xF7F4EC
    public static let onSlateDark: UInt32 = 0xF7F4EC

    /// **Fill only** — meaningful graphics and shapes, never letters.
    public static let sageLight: UInt32 = 0x3F6F58
    public static let sageDark: UInt32 = 0x3F6F58

    /// **Text-safe sage.** Section headers, wordmarks.
    public static let sageInkLight: UInt32 = 0x2F5A45
    public static let sageInkDark: UInt32 = 0x2F5A45

    /// Deep forest used inside the orb so it stays a sphere on the light page,
    /// not a washed-out disc of card white.
    public static let orbCoreLight: UInt32 = 0x1A2F26
    public static let orbCoreDark: UInt32 = 0x1A2F26

    /// **Decorative only.** Bronze-gold for haloes and hairlines — thin accent,
    /// never body text or filled controls that mean something.
    public static let goldLight: UInt32 = 0xB8954A
    public static let goldDark: UInt32 = 0xB8954A

    /// **Text-safe gold.** When bronze has to be read as letters.
    public static let goldInkLight: UInt32 = 0x7A5A18
    public static let goldInkDark: UInt32 = 0x7A5A18

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
    public static let orbCore = Color(light: orbCoreLight, dark: orbCoreDark)

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
        Pairing(name: "action on app background (dark)", ink: actionDark, background: Surface.appBackgroundDark),
        Pairing(name: "action on card (dark)", ink: actionDark, background: Surface.cardDark),

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
    /// `gold` is deliberately absent — decorative only, even when it clears the
    /// threshold on a given field.
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
