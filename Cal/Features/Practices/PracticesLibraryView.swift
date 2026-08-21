import CalContent
import CalDesign
import CalKit
import SwiftUI

/// The Premium Guided Library (`SPEC-premium.md`), browsable outside a check-in.
///
/// Deliberately honest about what isn't written yet: the footer names the
/// categories still waiting on Dr. Mia's copy rather than presenting the library
/// as complete.
struct PracticesLibraryView: View {
    @Environment(AppContainer.self) private var container
    @State private var basics: [Exercise] = []
    @State private var guided: [Exercise] = []
    @State private var loadFailed = false

    var body: some View {
        Group {
            if loadFailed {
                ContentUnavailableView(
                    "Practices unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The practice library couldn't be read.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !basics.isEmpty {
                            practiceGroup("Basic breathwork", exercises: basics)
                        }
                        if !guided.isEmpty {
                            PremiumGate(feature: .practiceLibrary) {
                                practiceGroup("Guided practices", exercises: guided)
                            }
                            .frame(minHeight: 120)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Practices")
        .task { await load() }
    }

    private func practiceGroup(_ title: String, exercises: [Exercise]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 { Divider() }
                    NavigationLink(value: VoiceRoute.practice(slug: exercise.slug, autoStart: false)) {
                        PracticeRow(exercise: exercise)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practice-\(exercise.slug)")
                }
            }
            .background(Surface.card, in: .rect(cornerRadius: 14))
        }
    }

    private func load() async {
        do {
            let allFree = try await container.content.exercises(tier: .free)
            basics = allFree
                .filter { $0.slug != "study-reset" && $0.slug != "seed-placeholder" }
                .sorted { $0.title < $1.title }
            guided = try await container.content.exercises(tier: .premium)
                .sorted { $0.title < $1.title }
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

private struct PracticeRow: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let duration = exercise.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let purpose = exercise.purpose {
                Text(purpose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

#Preview("library") {
    NavigationStack { PracticesLibraryView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
