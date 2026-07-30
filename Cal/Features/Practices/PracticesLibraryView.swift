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
    @State private var exercises: [Exercise] = []
    @State private var missingCategories: [CoherenceCategory] = []
    @State private var loadFailed = false

    var body: some View {
        List {
            if loadFailed {
                ContentUnavailableView(
                    "Practices unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The practice library couldn't be read.")
                )
            } else {
                Section {
                    ForEach(exercises) { exercise in
                        NavigationLink(value: exercise.slug) {
                            PracticeRow(exercise: exercise)
                        }
                    }
                } header: {
                    Text("Guided practices")
                } footer: {
                    if !missingCategories.isEmpty {
                        Text(
                            """
                            More coming: \(missingCategories.map(\.displayName).formatted(.list(type: .and))). \
                            Low scores in those areas use a placeholder for now.
                            """
                        )
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { slug in
            PracticeDetailView(slug: slug)
        }
        .navigationTitle("Practices")
        .task { await load() }
    }

    private func load() async {
        do {
            // Bound to a local before iterating: `for x in try await <call>`
            // segfaults this toolchain (see ARCHITECTURE.md §11).
            // Premium only: the placeholder is scaffolding and the study reset is
            // a tool inside Study Mode — neither is a session a student browses to.
            let all = try await container.content.exercises(tier: .premium)
            exercises = all.sorted { $0.title < $1.title }

            var missing: [CoherenceCategory] = []
            for category in CoherenceCategory.fullCheckIn {
                let match = try await container.content.exercise(for: category)
                if match == nil { missing.append(category) }
            }
            missingCategories = missing
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("practice-\(exercise.slug)")
    }
}

#Preview("library") {
    NavigationStack { PracticesLibraryView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
