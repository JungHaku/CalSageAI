import CalContent
import CalData
import CalDesign
import CalKit
import SwiftUI

/// The check-in. A rendering of `CheckInFlow.step` and nothing more — every
/// transition decision lives in `CalKit` where it's tested without a simulator.
struct CheckInView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: CheckInViewModel?

    let kind: CheckInKind

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            let created = CheckInViewModel(
                kind: kind,
                store: container.store,
                content: container.content,
                sessions: container.practiceSessions,
                dates: container.dates
            )
            model = created
            await created.loadContent()
        }
    }

    @ViewBuilder
    private func content(_ model: CheckInViewModel) -> some View {
        VStack(spacing: 0) {
            if !model.isComplete {
                progressBar(model)
            }

            switch model.flow.step {
            case .rating(let question):
                RatingStep(
                    prompt: question.prompt,
                    score: Binding(get: { model.draftScore }, set: { model.draftScore = $0 }),
                    // Only the free quick check-in shows the band response inline;
                    // on the ten-question flow it would fire ten times and become
                    // noise. It also only appears once a score exists.
                    showsBandResponse: kind == .quick,
                    canSubmit: model.canSubmit,
                    actionTitle: "Continue"
                ) {
                    Task { await model.submitRating() }
                }

            case .regulation(let question, _):
                if let exercise = model.currentExercise {
                    // No `.accessibilityIdentifier` on this container: in SwiftUI an
                    // identifier on a non-merged container propagates to every
                    // descendant and overwrites theirs, so the skip button and cue
                    // text lose their own ids and become unqueryable.
                    ExercisePlayerView(
                        exercise: exercise,
                        onFinished: { Task { await model.completeExercise() } },
                        onSkip: { progress in Task { await model.skipExercise(atProgress: progress) } }
                    )
                } else {
                    // Belt and braces: `currentExercise` falls back to the bundled
                    // placeholder, so this should be unreachable. If it ever isn't,
                    // the user proceeds instead of getting stuck.
                    RegulationUnavailable(summary: question.regulationSummary) {
                        // Nothing played, so the session records zero progress.
                        Task { await model.skipExercise(atProgress: 0) }
                    }
                }

            case .reRating(let question):
                RatingStep(
                    prompt: question.rePrompt,
                    score: Binding(get: { model.draftScore }, set: { model.draftScore = $0 }),
                    showsBandResponse: false,
                    canSubmit: model.canSubmit,
                    actionTitle: "Save"
                ) {
                    Task { await model.submitReRating() }
                }

            case .complete:
                CheckInSummary(checkIn: model.flow.checkIn)
            }
        }
        .animation(.snappy, value: model.flow.step)
        .overlay(alignment: .bottom) {
            if model.saveFailed {
                // The ratings are still in memory and the outbox retries, so this
                // is information, not an error the user must act on.
                Text("Saved on this device — we'll sync when you're back online.")
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: .capsule)
                    .padding(.bottom, 8)
            }
        }
    }

    private func progressBar(_ model: CheckInViewModel) -> some View {
        let (answered, total) = model.progress
        return VStack(spacing: 4) {
            ProgressView(value: Double(answered), total: Double(total))
            if total > 1 {
                Text("\(answered) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
        .accessibilityElement()
        .accessibilityLabel("Question \(min(answered + 1, total)) of \(total)")
    }
}

// MARK: - Steps

private struct RatingStep: View {
    let prompt: String
    @Binding var score: Score?
    let showsBandResponse: Bool
    let canSubmit: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(prompt)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("question-prompt")

                ScoreScale(score: $score)

                if showsBandResponse, let score {
                    Text(CoherenceBand(score).quickCheckInResponse)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("band-response")
                }

                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("continue-button")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RegulationUnavailable: View {
    let summary: String
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Exercise not downloaded", systemImage: "wifi.slash")
            } description: {
                Text(summary)
            }
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("skip-exercise")
        }
    }
}

private struct CheckInSummary: View {
    let checkIn: CheckIn

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(CoherenceScale.tint(for: .high))

                Text("Check-in complete")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("checkin-complete")

                // The product's actual claim (§15): that a few minutes of
                // regulation measurably moves the number. Shown only when
                // something was regulated — a fabricated "+0.0" would undercut it.
                if let delta = checkIn.averageDelta, checkIn.regulatedCount > 0 {
                    VStack(spacing: 4) {
                        Text(delta >= 0 ? "+\(delta, format: .number.precision(.fractionLength(1)))"
                                        : "\(delta, format: .number.precision(.fractionLength(1)))")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(CoherenceScale.tint(for: .high))
                        Text("average change across \(checkIn.regulatedCount) regulated \(checkIn.regulatedCount == 1 ? "area" : "areas")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                }

                if checkIn.kind == .full {
                    VStack(spacing: 0) {
                        ForEach(checkIn.scores) { score in
                            ScoreRow(score: score)
                            if score.id != checkIn.scores.last?.id { Divider() }
                        }
                    }
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                }
            }
            .padding()
        }
    }
}

private struct ScoreRow: View {
    let score: CategoryScore

    var body: some View {
        HStack {
            Text(score.category.displayName)
                .font(.subheadline)
            Spacer()
            // Neutral for the starting score; colour only marks improvement.
            // Tinting a low score red on a review screen is the manipulation
            // shown to raise rumination (§11.1).
            Text("\(score.before.value)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let after = score.after {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text("\(after.value)")
                    .foregroundStyle(
                        after.value > score.before.value ? ChartPalette.improvement : .primary
                    )
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview("full · 10 questions") {
    NavigationStack { CheckInView(kind: .full) }
        .environment(AppContainer.live(arguments: ["-CalFixedDate", "2026-07-29"]))
}

#Preview("quick · free tier") {
    NavigationStack { CheckInView(kind: .quick) }
        .environment(AppContainer.live(arguments: ["-CalFixedDate", "2026-07-29"]))
}

#Preview("complete · low day regulated") {
    CheckInSummary(checkIn: .fixture(band: .low, regulated: true))
}

#Preview("complete · quick") {
    CheckInSummary(checkIn: .fixture(kind: .quick, band: .moderate, regulated: false))
}
