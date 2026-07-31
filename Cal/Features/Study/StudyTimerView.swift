import CalContent
import CalDesign
import CalKit
import Combine
import SwiftUI

/// Study Mode (`SPEC-free.md` §5): a 25 / 50 / 90 minute focus block that always
/// ends in Dr. Mia's 30-second reset.
///
/// The reset is authored content (`study-reset`), not UI copy, so it plays through
/// the same timeline machinery as every other guided practice — and her wording
/// stays editable in one place.
struct StudyTimerView: View {
    @Environment(AppContainer.self) private var container
    @State private var session: StudySession?
    @State private var length: StudySession.Length = .short
    @State private var now = Date()
    @State private var resetExercise: Exercise?

    /// Drives the countdown. One second is enough for a mm:ss label; the ring
    /// interpolates between ticks with its own animation.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 32) {
            if let session {
                running(session)
            } else {
                idle
            }
        }
        .padding()
        .navigationTitle("Study")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
        .task {
            if resetExercise == nil {
                resetExercise = try? await container.content.exercise(slug: "study-reset")
            }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("How long?")
                .font(.title2.weight(.semibold))

            Picker("Length", selection: $length) {
                ForEach(StudySession.Length.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("length-picker")

            Text("Every session ends with a 30-second reset.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                // The REAL clock, not `container.dates`. That provider exists for
                // calendar-day reasoning — streaks, `local_date` — and under test
                // it is deliberately frozen. Measuring elapsed time against a
                // frozen clock made the session finish the instant the first tick
                // arrived. Same rule the breathwork player follows.
                now = Date()
                session = StudySession(length: length, startedAt: now)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("start-study")

            Spacer()
        }
    }

    // MARK: Running

    @ViewBuilder
    private func running(_ session: StudySession) -> some View {
        switch session.phase(at: now) {
        case .focus:
            focus(session)
        case .reset:
            // Her reset, played by the same component as every other practice.
            if let resetExercise {
                ExercisePlayerView(
                    exercise: resetExercise,
                    onFinished: { finish() },
                    onSkip: { _ in finish() }
                )
            } else {
                ProgressView().task { finish() }
            }
        case .finished:
            finished
        }
    }

    private func focus(_ session: StudySession) -> some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(ChartPalette.gridline, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: session.focusProgress(at: now))
                    .stroke(ChartPalette.primary, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: session.focusProgress(at: now))

                VStack(spacing: 4) {
                    Text(session.remainingLabel(at: now))
                        .displayNumeral(size: 52)
                        .monospacedDigit()
                        .accessibilityIdentifier("study-remaining")
                    Text("\(session.length.minutes) min block")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240, height: 240)
            // Combining discards the children's identifiers, so the identifier
            // belongs on the merged element (ARCHITECTURE.md §11).
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("study-timer")
            .accessibilityLabel("Time remaining")
            .accessibilityValue(session.remainingLabel(at: now))

            Spacer()

            Button("End session", role: .destructive) { self.session = nil }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("end-study")
        }
    }

    private var finished: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .displayGlyph(size: 52)
                .foregroundStyle(ChartPalette.improvement)
            Text("Back to work.")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("study-complete")
            Button("New session") { session = nil }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private func finish() {
        // Jump the clock past the reset so the view lands on `.finished` rather
        // than waiting for the next tick — the player has already ended.
        guard let session else { return }
        now = session.startedAt.addingTimeInterval(
            session.length.duration + StudySession.resetDuration
        )
    }
}

#Preview("study") {
    NavigationStack { StudyTimerView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
