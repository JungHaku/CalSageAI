import CalKit
import SwiftUI

/// Visual treatment for the three response bands.
///
/// Colours are placeholders until Dr. Mia's brand assets arrive. They are defined
/// once, here, so swapping them later is a single edit rather than a hunt through
/// feature code.
public enum CoherenceScale {
    public static func tint(for band: CoherenceBand) -> Color {
        switch band {
        case .low:      Color(red: 0.85, green: 0.45, blue: 0.35)
        case .moderate: Color(red: 0.90, green: 0.72, blue: 0.35)
        case .high:     Color(red: 0.35, green: 0.70, blue: 0.55)
        }
    }

    public static func tint(for score: Score) -> Color {
        tint(for: CoherenceBand(score))
    }
}

/// A 0–10 rating control — the single most-used component in the app.
///
/// Accessibility is not a polish item here: `accessibilityValue` is what makes the
/// scale usable with VoiceOver, and a rating scale that a screen reader can't
/// operate makes the whole check-in inaccessible.
public struct ScoreScale: View {
    @Binding private var score: Score
    private let onChange: ((Score) -> Void)?

    public init(score: Binding<Score>, onChange: ((Score) -> Void)? = nil) {
        self._score = score
        self.onChange = onChange
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(score.description)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(CoherenceScale.tint(for: score))
                .contentTransition(.numericText())
                .animation(.snappy, value: score.value)

            Slider(
                value: Binding(
                    get: { Double(score.value) },
                    set: { newValue in
                        let updated = Score(clamping: Int(newValue.rounded()))
                        if updated != score {
                            score = updated
                            onChange?(updated)
                        }
                    }
                ),
                in: Double(Score.validRange.lowerBound)...Double(Score.validRange.upperBound),
                step: 1
            )
            .tint(CoherenceScale.tint(for: score))
            .accessibilityLabel("Rating")
            .accessibilityValue("\(score.value) out of \(Score.validRange.upperBound)")
        }
    }
}

#Preview("0 · low") {
    @Previewable @State var score = Score(clamping: 0)
    ScoreScale(score: $score).padding()
}

#Preview("5 · the divergent threshold") {
    @Previewable @State var score = Score(clamping: 5)
    ScoreScale(score: $score).padding()
}

#Preview("9 · high") {
    @Previewable @State var score = Score(clamping: 9)
    ScoreScale(score: $score).padding()
}

#Preview("dark") {
    @Previewable @State var score = Score(clamping: 3)
    ScoreScale(score: $score).padding().preferredColorScheme(.dark)
}

#Preview("accessibility XXXL") {
    @Previewable @State var score = Score(clamping: 7)
    ScoreScale(score: $score).padding().dynamicTypeSize(.accessibility3)
}
