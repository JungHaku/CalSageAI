import CalDesign
import CalKit
import SwiftUI

/// Plays a flattened `ExerciseTimeline`.
///
/// Timing comes from a monotonic `ContinuousClock` compared against a start
/// instant, not from accumulating a per-tick delta. Accumulating drifts, and drift
/// in a breath pacer is the one bug a user feels immediately.
@Observable
@MainActor
final class ExercisePlayerModel {
    let exercise: Exercise
    let timeline: ExerciseTimeline

    private(set) var elapsed: TimeInterval = 0
    private(set) var beat: ExerciseTimeline.Beat?
    private(set) var isFinished = false

    private var task: Task<Void, Never>?
    private let haptics = BreathHaptics()

    init(exercise: Exercise) {
        self.exercise = exercise
        // A malformed script must not take down a check-in. `timeline()` throws
        // only on authored-content errors, which are caught in tests — but if one
        // reaches a device, an empty timeline finishes immediately and the user
        // gets on with re-rating rather than hitting a dead end.
        self.timeline = (try? exercise.script.timeline()) ?? .empty
        self.beat = timeline.beats.first
    }

    var progress: Double { timeline.progress(at: elapsed) }
    var totalDuration: TimeInterval { timeline.totalDuration }

    /// 0…1 through the current beat — drives the breathing ring.
    var beatProgress: Double {
        guard let beat, beat.duration > 0 else { return 0 }
        return min(1, max(0, (elapsed - beat.start) / beat.duration))
    }

    func start(hapticsEnabled: Bool) {
        guard task == nil else { return }
        haptics.setEnabled(hapticsEnabled)

        // An empty or already-finished timeline shouldn't spin up a loop.
        guard totalDuration > 0 else {
            isFinished = true
            return
        }

        if let first = beat { haptics.fire(for: first.phase) }

        task = Task { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now

            while !Task.isCancelled {
                guard let self else { return }
                let now = Self.seconds(clock.now - started)

                self.elapsed = now
                let current = self.timeline.beat(at: now)

                if current?.id != self.beat?.id {
                    self.beat = current
                    if let current { self.haptics.fire(for: current.phase) }
                }

                if current == nil {
                    self.isFinished = true
                    return
                }
                // ~30Hz: smooth enough for the ring, cheap enough not to matter.
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

struct ExercisePlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ExercisePlayerModel

    let onFinished: () -> Void
    /// Carries the progress reached, so an abandoned run is recorded with how far
    /// it got — that's the signal that says whether a practice is mistimed.
    let onSkip: (Double) -> Void

    init(
        exercise: Exercise,
        onFinished: @escaping () -> Void,
        onSkip: @escaping (Double) -> Void
    ) {
        self._model = State(initialValue: ExercisePlayerModel(exercise: exercise))
        self.onFinished = onFinished
        self.onSkip = onSkip
    }

    var body: some View {
        // Scrollable, and only bounces when the content genuinely overflows. The
        // ring plus cue plus controls exceed a short viewport — a small device at
        // accessibility text sizes — and a fixed VStack would push the "Not right
        // now" button off screen, which is the one control that must always be
        // reachable.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(spacing: 32) {
            header

            Spacer(minLength: 12)

            breathRing

            VStack(spacing: 6) {
                Text(model.beat?.text ?? "")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("exercise-cue")
                    // Announce each new instruction so the exercise is followable
                    // with the screen off or with VoiceOver.
                    .accessibilityAddTraits(.updatesFrequently)

                if let beat = model.beat, let cycle = beat.cycle, let total = beat.cycleCount {
                    Text("Breath \(cycle) of \(total)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 72)

            Spacer(minLength: 12)

            ProgressView(value: model.progress)
                .tint(.accentColor)
                .accessibilityLabel("Exercise progress")

            Button("Not right now") { onSkip(model.progress) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("skip-exercise")
        }
        .padding(24)
        .task {
            // Reduce Motion is also the signal for "don't surprise me with
            // sensation" — users who enable it generally don't want the buzzing.
            model.start(hapticsEnabled: !reduceMotion)
        }
        .onDisappear { model.stop() }
        .onChange(of: model.isFinished) { _, finished in
            if finished { onFinished() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.exercise.title)
                .font(.headline)
            Text(Duration.seconds(model.totalDuration).formatted(.time(pattern: .minuteSecond)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Cal sits **inside** the ring, and deliberately does not breathe with it.
    ///
    /// The ring's scale is the instruction — it is how the exercise is followed
    /// without reading — so it has to stay the only thing on screen that moves.
    /// Scaling Cal too would give the eye a second moving target and blur which
    /// one is the pacing signal. He is a still point at the centre instead, which
    /// is also what the pose is of.
    ///
    /// Nothing here touches the timing: the `scaleEffect` and its animation are
    /// unchanged and still apply only to the circle.
    private var breathRing: some View {
        let phase = model.beat?.phase ?? .cue
        return ZStack {
            Circle()
                .fill(CoherenceScale.tint(for: .high).opacity(0.18))
                .overlay(Circle().strokeBorder(CoherenceScale.tint(for: .high), lineWidth: 3))
                .frame(width: 220, height: 220)
                .scaleEffect(reduceMotion ? 0.85 : scale(for: phase))
                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: model.elapsed)

            // Fixed at 96pt, so he stays clear of the ring even at its smallest
            // (0.6 x 220 = 132pt).
            CalAvatar(.card)
        }
        .accessibilityHidden(true)
    }

    /// The ring is the visual half of the pacing: it grows through the inhale,
    /// holds, and shrinks through the exhale, so the shape itself is the instruction.
    private func scale(for phase: BreathPhase) -> Double {
        switch phase {
        case .inhale: 0.6 + 0.4 * model.beatProgress
        case .hold:   1.0
        case .exhale: 1.0 - 0.4 * model.beatProgress
        case .cue:    0.8
        }
    }
}

#Preview("breathwork") {
    ExercisePlayerView(exercise: .placeholder, onFinished: {}, onSkip: { _ in })
}

// No Reduce Motion preview: `accessibilityReduceMotion` is a read-only environment
// value, so it can't be injected. Toggle it in the simulator's
// Settings › Accessibility › Motion to check the static-ring path.
