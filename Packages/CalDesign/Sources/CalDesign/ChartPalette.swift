import SwiftUI

/// Colours for charts, separate from `CoherenceScale`.
///
/// The band tints (red/amber/green) that colour a *single* score are wrong inside
/// a chart of many categories: colouring each bar by its own value double-encodes
/// bar length as hue, spending the only free channel on information the bar
/// already shows. So charts use one hue, and magnitude is carried by position.
///
/// Values are sage and bronze, not a blue ramp — the ordinal pair is on-brand
/// on the light field. Light and dark keys match the product's single look.
public enum ChartPalette {
    /// The measured value — sage, the emphasis shade.
    public static let primary = Color(light: 0x3F6F58, dark: 0x3F6F58)
    /// The paired "before" shade — bronze-gold, for the dumbbell.
    public static let secondary = Color(light: 0xB8954A, dark: 0xB8954A)

    /// Recessive chrome. Gridlines are solid hairlines one shade off the surface —
    /// never dashed, which reads as "threshold" when it's just a grid.
    public static let gridline = Color(light: 0xE4DFD6, dark: 0xE4DFD6)
    public static let axis = Color(light: 0xC9C2B6, dark: 0xC9C2B6)
    /// Gridline-adjacent muted ink. Fine for non-text chrome — WCAG exempts
    /// gridlines from the contrast requirement — but NOT for labels.
    public static let mutedInk = Color(light: 0x6E857A, dark: 0x6E857A)

    /// Axis tick labels. These are *text*, so they need 4.5:1 under WCAG 1.4.3.
    /// Same ink as `Surface.inkSecondary`, measured in `ContrastTests`.
    public static let axisLabel = Color(light: Surface.inkSecondaryLight, dark: Surface.inkSecondaryDark)

    /// Improvement. Paired with an arrow glyph and a label, never colour alone.
    public static let improvement = Color(light: 0x2E7A58, dark: 0x2E7A58)
}

extension Color {
    /// Two deliberately-chosen steps rather than one colour dimmed for dark mode.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(
            uiColor: UIColor { traits in
                UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
        #else
        self.init(rgb: light)
        #endif
    }

    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

#if canImport(UIKit)
extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
