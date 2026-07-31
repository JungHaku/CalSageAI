import Foundation

/// WCAG contrast, computed.
///
/// Every contrast figure in this package is produced by this code and asserted in
/// a test, rather than written into a comment and believed. That distinction has
/// already earned its keep once: the chart axis labels were shipped in a muted ink
/// that *looked* fine and measured 3.50:1, below the 4.5:1 that WCAG 1.4.3 asks of
/// text. Nobody spots that by eye.
///
/// Deliberately plain arithmetic on sRGB values — no UIKit, no `Color` — so it
/// runs in `swift test` in milliseconds with no simulator.
public enum Contrast {

    /// WCAG 2.x relative luminance of an sRGB colour.
    ///
    /// The piecewise transfer function is the specification's, not an
    /// approximation: the linear segment below 0.03928 matters for exactly the
    /// near-black inks this palette uses.
    public static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = channel((rgb >> 16) & 0xFF)
        let green = channel((rgb >> 8) & 0xFF)
        let blue = channel(rgb & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Contrast ratio between two colours, from 1:1 to 21:1. Order-independent.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let lighter = max(relativeLuminance(a), relativeLuminance(b))
        let darker = min(relativeLuminance(a), relativeLuminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The thresholds. Named rather than sprinkled as magic numbers, because which
    /// one applies depends on the *size* of the text and that is the part people
    /// get wrong.
    public enum Threshold {
        /// WCAG 1.4.3 for body text — anything below 18pt, or below 14pt bold.
        public static let bodyText = 4.5
        /// WCAG 1.4.3 for large text — 18pt and up, or 14pt bold and up.
        public static let largeText = 3.0
        /// WCAG 1.4.11 for interactive controls and meaningful graphics.
        /// Gridlines and decorative chrome are exempt.
        public static let nonText = 3.0
    }

    /// Composites a partially transparent ink over an opaque background.
    ///
    /// Needed because SwiftUI's `.secondary` and `.quaternary` are *alpha* styles,
    /// not colours: their real contrast depends on what they land on, which is why
    /// secondary text over a tinted card measures worse than the same text on the
    /// plain background.
    public static func composite(_ foreground: UInt32, alpha: Double, over background: UInt32) -> UInt32 {
        func blend(_ shift: UInt32) -> UInt32 {
            let front = Double((foreground >> shift) & 0xFF)
            let back = Double((background >> shift) & 0xFF)
            return UInt32((front * alpha + back * (1 - alpha)).rounded())
        }
        return (blend(16) << 16) | (blend(8) << 8) | blend(0)
    }
}
