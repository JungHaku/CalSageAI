import SwiftUI

/// Surfaces and text inks, as explicit colours with measured contrast.
///
/// ## Why these exist rather than SwiftUI's `.secondary` and `.quaternary`
///
/// Apple's hierarchical styles are *alpha* values, not colours. `.secondary` text
/// is legible on a plain background and measurably worse on a tinted card, because
/// what a reader actually sees is the composite. The accessibility audit found
/// exactly that: card subtitles reported "Contrast failed" while the same ink
/// elsewhere passed. Naming the surface and the ink separately, and asserting the
/// pairing, is the only way to know — see `ContrastTests`.
///
/// ## The light field
///
/// Cal's page is a soft grey-white with bronze-gold chrome. Light and dark raw
/// values match so a missed `preferredColorScheme` cannot flash a forest page.
/// Cards lift as white slabs; ink is dark slate, not cream.
public enum Surface {

    // MARK: Raw values
    //
    // `UInt32` rather than `Color` so `Contrast` can measure them. The `Color`
    // tokens below are built from these, so what is tested is what is drawn.

    /// Warm grey-white. Same in both appearances — this is the product's field.
    public static let appBackgroundLight: UInt32 = 0xF3F1ED
    public static let appBackgroundDark: UInt32 = 0xF3F1ED

    /// White lift so cards read as raised, not as another grey.
    public static let cardLight: UInt32 = 0xFFFFFF
    public static let cardDark: UInt32 = 0xFFFFFF

    /// Near-black slate — primary reading ink on the light field.
    public static let inkPrimaryLight: UInt32 = 0x1C2420
    public static let inkPrimaryDark: UInt32 = 0x1C2420

    /// Muted sage-slate. Lighter hierarchy than primary, still above 4.5:1.
    public static let inkSecondaryLight: UInt32 = 0x5A655E
    public static let inkSecondaryDark: UInt32 = 0x5A655E

    // MARK: Tokens

    public static let appBackground = Color(light: appBackgroundLight, dark: appBackgroundDark)
    public static let card = Color(light: cardLight, dark: cardDark)
    public static let inkPrimary = Color(light: inkPrimaryLight, dark: inkPrimaryDark)
    public static let inkSecondary = Color(light: inkSecondaryLight, dark: inkSecondaryDark)

    // MARK: Validation

    public struct Pairing: Sendable {
        public let name: String
        public let ink: UInt32
        public let background: UInt32
        public var ratio: Double { Contrast.ratio(ink, background) }
    }

    /// Every neutral ink/surface combination the app renders. If a new surface is
    /// introduced, add it here — the test iterates `allTextPairings`, so an
    /// unlisted pairing is an unmeasured one.
    public static let textPairings: [Pairing] = [
        Pairing(name: "primary ink on app background (light)", ink: inkPrimaryLight, background: appBackgroundLight),
        Pairing(name: "primary ink on card (light)", ink: inkPrimaryLight, background: cardLight),
        Pairing(name: "secondary ink on app background (light)", ink: inkSecondaryLight, background: appBackgroundLight),
        Pairing(name: "secondary ink on card (light)", ink: inkSecondaryLight, background: cardLight),
        Pairing(name: "primary ink on app background (dark)", ink: inkPrimaryDark, background: appBackgroundDark),
        Pairing(name: "primary ink on card (dark)", ink: inkPrimaryDark, background: cardDark),
        Pairing(name: "secondary ink on app background (dark)", ink: inkSecondaryDark, background: appBackgroundDark),
        Pairing(name: "secondary ink on card (dark)", ink: inkSecondaryDark, background: cardDark),
        Pairing(name: "chart axis label on app background (light)", ink: inkSecondaryLight, background: appBackgroundLight),
        Pairing(name: "chart axis label on app background (dark)", ink: inkSecondaryDark, background: appBackgroundDark),
    ]

    /// What the test actually iterates: the neutral inks above plus the brand
    /// ones. Two lists rather than one because they are owned by different files
    /// and have different reasons to change, but a single entry point so there
    /// is still only one thing to forget to add to — and adding to either is
    /// enough.
    public static let allTextPairings: [Pairing] = textPairings + Brand.textPairings
}
