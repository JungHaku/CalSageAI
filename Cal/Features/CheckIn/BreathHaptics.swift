import CalKit
import UIKit

/// Haptic pacing for breathwork.
///
/// This is not decoration. The point of the breath cues is that a user can close
/// their eyes — or put the phone face down with the audio running (§2) — and still
/// follow the rhythm. The taps are the interface at that point.
///
/// Intensities come from `BreathPhase.hapticIntensity` in `CalKit`, so the visual,
/// the haptic, and the VoiceOver announcement are all derived from one authored
/// definition rather than each guessing.
@MainActor
final class BreathHaptics {
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    private var isEnabled = true

    init() {
        generator.prepare()
    }

    /// Respect the system-wide reduce-motion preference: users who turn it on are
    /// often the ones most bothered by unexpected buzzing.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func fire(for phase: BreathPhase) {
        guard isEnabled, phase.hapticIntensity > 0 else { return }
        generator.impactOccurred(intensity: phase.hapticIntensity)
        // Re-arm immediately; the Taptic Engine goes idle otherwise and the next
        // tap arrives late, which is exactly the beat the user is pacing against.
        generator.prepare()
    }
}
