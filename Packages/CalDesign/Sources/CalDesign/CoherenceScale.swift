import CalKit
import SwiftUI

/// Visual treatment for the three response bands.
///
/// Colours are placeholders until Dr. Mia's brand assets arrive. Defined once,
/// here, so swapping them later is a single edit rather than a hunt through
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

    private var tint: Color {
        score.map(CoherenceScale.tint(for:)) ?? CoherenceScale.unsetTint
    }

    public var body: some View {
        VStack(spacing: 12) {
            // A bare dash reads as a divider rather than "not answered yet", so the
            // unset state says so in words. It also keeps the vertical space
            // reserved, so committing a score doesn't shift the layout.
            Group {
                if let score {
                    Text(score.description)
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                } else {
                    Text("Choose a number")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 68)
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
