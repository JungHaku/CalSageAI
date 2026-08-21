import CalContent
import CalData
import CalDesign
import CalKit
import SwiftUI

/// One practice: what it's for, how long it runs, and a way to begin.
struct PracticeDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(PracticeRunCoordinator.self) private var practices: PracticeRunCoordinator?
    @State private var exercise: Exercise?
    @State private var isPlaying = false
    @State private var lastCompleted = false

    let slug: String
    /// Begin as soon as the script has loaded, without waiting for a tap.
    ///
    /// Set when Cal opened this herself (`play_practice`). She has just said
    /// "let's breathe together" out loud, and a screen that then waits for a
    /// button makes her a liar. Still `false` for someone who navigated here
    /// themselves — they came to read what it is.
    var autoStart = false

    var body: some View {
        Group {
            if let exercise {
                content(exercise)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(exercise?.title ?? "Practice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if exercise == nil {
                exercise = try? await container.content.exercise(slug: slug)
            }
            // Only once, and only if the script actually loaded — auto-starting
            // an empty timeline would flash a player that immediately finishes.
            if autoStart, exercise != nil, !lastCompleted {
                isPlaying = true
            }
        }
        .fullScreenCover(isPresented: $isPlaying) {
            if let exercise {
                PracticeRunnerView(exercise: exercise) { completed in
                    isPlaying = false
                    lastCompleted = completed
                    // Voice-awaited runs resolve here; tap-only runs are a no-op
                    // because the coordinator is idle.
                    practices?.resolve(completed ? .completed : .stopped)
                }
            }
        }
        .onDisappear {
            // Route torn down while Cal is still awaiting — treat as stopped.
            if practices?.activeSlug == slug {
                practices?.resolve(.stopped)
            }
        }
    }

    @ViewBuilder
    private func content(_ exercise: Exercise) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let purpose = exercise.purpose {
                    Text(purpose)
                        .font(.title3)
                        .accessibilityIdentifier("practice-purpose")
                }

                HStack(spacing: 16) {
                    if let duration = exercise.duration {
                        Label(
                            Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)),
                            systemImage: "clock"
                        )
                        .monospacedDigit()
                    }
                    if let category = exercise.category {
                        Label(category.displayName, systemImage: "circle.hexagongrid")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if lastCompleted {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CoherenceScale.textTint(for: .high))
                        .accessibilityIdentifier("practice-completed")
                }

                Button {
                    lastCompleted = false
                    isPlaying = true
                } label: {
                    Label("Begin practice", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("begin-practice")

                // The wording is Dr. Mia's and fixed; the pacing is ours and
                // pending her approval (§17 question 5). Saying so in the app
                // during the MVP keeps testers honest about what they're reacting
                // to — the words or the timing.
                Text("Timings are provisional and being reviewed.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Hosts a standalone practice run and records it (§ `PracticeSession`).
///
/// A session row is written when playback starts and updated when it ends, so an
/// abandoned run still leaves its progress behind — which is the signal that says
/// whether a practice is mistimed.
struct PracticeRunnerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(PracticeRunCoordinator.self) private var practices: PracticeRunCoordinator?
    @State private var session: PracticeSession?
    @State private var stopObserver: Int = 0

    let exercise: Exercise
    /// `true` when the practice ran to the end.
    let onDismiss: (Bool) -> Void

    var body: some View {
        ExercisePlayerView(
            exercise: exercise,
            onFinished: { Task { await finish() } },
            onSkip: { progress in Task { await abandon(at: progress) } }
        )
        .task { await begin() }
        .onChange(of: practices?.stopToken ?? 0) { _, token in
            guard token != stopObserver, practices?.isRunning == true else { return }
            stopObserver = token
            Task { await abandon(at: 0) }
        }
    }

    private func begin() async {
        guard session == nil else { return }
        let new = PracticeSession(
            exerciseSlug: exercise.slug,
            localDate: container.dates.today,
            startedAt: container.dates.now
        )
        session = new
        try? await container.practiceSessions.save(new)
    }

    private func finish() async {
        guard var session else {
            practices?.resolve(.completed)
            onDismiss(true)
            return
        }
        session.finish(at: container.dates.now)
        self.session = session
        try? await container.practiceSessions.save(session)
        practices?.resolve(.completed)
        onDismiss(true)
    }

    private func abandon(at progress: Double) async {
        guard var session else {
            practices?.resolve(.stopped)
            onDismiss(false)
            return
        }
        session.abandon(atProgress: progress)
        self.session = session
        try? await container.practiceSessions.save(session)
        practices?.resolve(.stopped)
        onDismiss(false)
    }
}

#Preview("detail") {
    NavigationStack { PracticeDetailView(slug: "presence-of-light") }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
