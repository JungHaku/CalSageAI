import SwiftUI

/// Colours for charts, separate from `CoherenceScale`.
///
/// The band tints (red/amber/green) that colour a *single* score are wrong inside
/// a chart of many categories: colouring each bar by its own value double-encodes
/// bar length as hue, spending the only free channel on information the bar
/// already shows. So charts use one hue, and magnitude is carried by position.
///
/// Values are validated steps of a single blue ramp, not eyeballed — the ordinal
/// pair clears monotone lightness, step separation, and surface contrast in both
/// light and dark (light end 2.06:1 light / 2.15:1 dark against the chart
/// surface). Both modes are chosen deliberately; dark is not an automatic flip.
public enum ChartPalette {
    /// The measured value — the emphasis shade.
    public static let primary = Color(light: 0x2A78D6, dark: 0x3987E5)
    /// The paired "before" shade of the same hue, for the dumbbell.
    public static let secondary = Color(light: 0x86B6EF, dark: 0x184F95)

    /// Recessive chrome. Gridlines are solid hairlines one shade off the surface —
    /// never dashed, which reads as "threshold" when it's just a grid.
    public static let gridline = Color(light: 0xE1E0D9, dark: 0x2C2C2A)
    public static let axis = Color(light: 0xC3C2B7, dark: 0x383835)
    /// Gridline-adjacent muted ink. Fine for non-text chrome — WCAG exempts
    /// gridlines from the contrast requirement — but NOT for labels.
    public static let mutedInk = Color(light: 0x898781, dark: 0x898781)

    /// Axis tick labels. These are *text*, so they need 4.5:1 under WCAG 1.4.3.
    /// The muted ink measures only 3.50:1 on the light surface and fails; the
    /// secondary ink clears it in both modes (7.73:1 light, 9.72:1 dark).
    public static let axisLabel = Color(light: 0x52514E, dark: 0xC3C2B7)

    /// Improvement. Paired with an arrow glyph and a label, never colour alone.
    public static let improvement = Color(light: 0x006300, dark: 0x0CA30C)
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
