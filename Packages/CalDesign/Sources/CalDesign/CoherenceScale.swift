import CalKit
import SwiftUI

/// Visual treatment for the three response bands.
///
/// Colours are placeholders until Dr. Mia's brand assets arrive. Defined once,
/// here, so swapping them later is a single edit rather than a hunt through
/// feature code.
public enum CoherenceScale {
    /// The **fill** tint — swatches, dots, and filled shapes.
    ///
    /// Not safe as a text colour, and that is not a subtlety: measured against the
    /// app background these are 3.21:1, 1.85:1 and 2.57:1, where text needs 4.5:1.
    /// Use `textTint(for:)` for anything a person reads. `ContrastTests` asserts
    /// both facts so the two cannot be quietly merged back together.
    public static func tint(for band: CoherenceBand) -> Color {
        switch band {
        case .low:      Color(rgb: Band.lowFill)
        case .moderate: Color(rgb: Band.moderateFill)
        case .high:     Color(rgb: Band.highFill)
        }
    }

    /// The same three hues, darkened (or lightened, in dark mode) until they clear
    /// 4.5:1 against **both** the app background and the card surface.
    ///
    /// Hue and saturation are preserved — only lightness moved — so the bands still
    /// read as the same three colours, just legibly.
    public static func textTint(for band: CoherenceBand) -> Color {
        switch band {
        case .low:      Color(light: Band.lowTextLight, dark: Band.lowTextDark)
        case .moderate: Color(light: Band.moderateTextLight, dark: Band.moderateTextDark)
        case .high:     Color(light: Band.highTextLight, dark: Band.highTextDark)
        }
    }

    /// Raw values, exposed so `Contrast` can measure exactly what is drawn.
    public enum Band {
        public static let lowFill: UInt32 = 0xD97359
        public static let moderateFill: UInt32 = 0xE6B859
        public static let highFill: UInt32 = 0x59B28C

        // Chosen to sit at *separated* contrast ratios — roughly 9.0, 6.4 and 4.6
        // against the card — rather than all pushed to the 4.5:1 minimum.
        //
        // The first attempt did exactly that, and a test caught it: three colours
        // tuned to the same threshold end up at the same luminance, so they are
        // distinguishable only by hue. That is precisely the case a red-green
        // colourblind reader, a greyscale screenshot, and a printed page all fail.
        // Spreading the luminance costs nothing and fixes all three.
        public static let lowTextLight: UInt32 = 0x712B1A
        public static let lowTextDark: UInt32 = 0xE9AFA0
        public static let moderateTextLight: UInt32 = 0x715111
        public static let moderateTextDark: UInt32 = 0xCD9420
        public static let highTextLight: UInt32 = 0x38785D
        public static let highTextDark: UInt32 = 0x449371

        public static let allFills: [UInt32] = [lowFill, moderateFill, highFill]
        public static let allTextLight: [UInt32] = [lowTextLight, moderateTextLight, highTextLight]
        public static let allTextDark: [UInt32] = [lowTextDark, moderateTextDark, highTextDark]
    }

    public static func tint(for score: Score) -> Color {
        tint(for: CoherenceBand(score))
    }

    public static func textTint(for score: Score) -> Color {
        textTint(for: CoherenceBand(score))
    }

    /// Shown before the student has answered. Deliberately neutral — a coloured
    /// unset scale would imply a reading that hasn't been given.
    public static let unsetTint = Color.secondary
}

/// A 0–10 rating control — the single most-used component in the app.
///
/// **Starts unset** (ARCHITECTURE.md §7). A pre-filled value anchors a self-report
/// scale, and the obvious default — 5 — is *exactly* the premium regulation
/// threshold, so anyone tapping straight through would be recorded as low and
/// routed into an exercise. That would inflate both the regulation rate and the
/// mean before→after delta, which is the number Dr. Mia reads as evidence the
/// method works.
///
/// The slider sits at the midpoint so the thumb is reachable in either direction,
/// but reports no value until touched.
public struct ScoreScale: View {
    @Binding private var score: Score?
    private let onChange: ((Score) -> Void)?

    public init(score: Binding<Score?>, onChange: ((Score) -> Void)? = nil) {
        self._score = score
        self.onChange = onChange
    }

    private var midpoint: Double {
        Double(Score.validRange.lowerBound + Score.validRange.upperBound) / 2
    }

    /// The slider's control tint — a fill, so the fill palette is correct here.
    private var tint: Color {
        score.map(CoherenceScale.tint(for:)) ?? CoherenceScale.unsetTint
    }

    /// The numeral is read, not just seen, so it takes the measured text palette.
    private var numeralTint: Color {
        score.map(CoherenceScale.textTint(for:)) ?? CoherenceScale.unsetTint
    }

    /// Reserved height for the numeral row.
    ///
    /// Scaled, and a *minimum* rather than a fixed height. It was `.frame(height: 68)`,
    /// which held the row at 68pt however large the type got — so the numeral scaled
    /// correctly and was then clipped by its own container. A layout test caught it
    /// by measuring that the control's height did not change at AX5.
    @ScaledMetric(relativeTo: .largeTitle) private var reservedHeight: CGFloat = 68

    public var body: some View {
        VStack(spacing: 12) {
            // A bare dash reads as a divider rather than "not answered yet", so the
            // unset state says so in words. It also keeps the vertical space
            // reserved, so committing a score doesn't shift the layout.
            Group {
                if let score {
                    Text(score.description)
                        .displayNumeral(size: 56, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(numeralTint)
                        .contentTransition(.numericText())
                } else {
                    Text("Choose a number")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: reservedHeight)
            .animation(.snappy, value: score?.value)
            .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { Double(score?.value ?? Int(midpoint)) },
                    set: { newValue in
                        let updated = Score(clamping: Int(newValue.rounded()))
                        // Assign even when the number is unchanged: the first touch
                        // at the midpoint has to commit 5, or the scale would look
                        // answered while still reporting nil.
                        if updated != score {
                            score = updated
                            onChange?(updated)
                        }
                    }
                ),
                in: Double(Score.validRange.lowerBound)...Double(Score.validRange.upperBound),
                step: 1
            )
            .tint(tint)
            .accessibilityLabel("Rating")
            .accessibilityValue(
                score.map { "\($0.value) out of \(Score.validRange.upperBound)" } ?? "Not answered yet"
            )
        }
    }
}

#Preview("unset · the default") {
    @Previewable @State var score: Score?
    ScoreScale(score: $score).padding()
}

#Preview("0 · low") {
    @Previewable @State var score: Score? = Score(clamping: 0)
    ScoreScale(score: $score).padding()
}

#Preview("5 · the divergent threshold") {
    @Previewable @State var score: Score? = Score(clamping: 5)
    ScoreScale(score: $score).padding()
}

#Preview("9 · high") {
    @Previewable @State var score: Score? = Score(clamping: 9)
    ScoreScale(score: $score).padding()
}

#Preview("dark") {
    @Previewable @State var score: Score? = Score(clamping: 3)
    ScoreScale(score: $score).padding().preferredColorScheme(.dark)
}

#Preview("accessibility XXXL") {
    @Previewable @State var score: Score? = Score(clamping: 7)
    ScoreScale(score: $score).padding().dynamicTypeSize(.accessibility3)
}
