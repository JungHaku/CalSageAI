import CalData
import CalDesign
import CalKit
import SwiftUI

/// Past check-ins, newest first.
struct HistoryView: View {
    @Environment(AppContainer.self) private var container
    @State private var checkIns: [CheckIn] = []
    @State private var didLoad = false

    var body: some View {
        List {
            if checkIns.isEmpty && didLoad {
                ContentUnavailableView(
                    "No check-ins yet",
                    systemImage: "calendar",
                    description: Text("Your check-ins will appear here.")
                )
            } else {
                ForEach(checkIns) { checkIn in
                    NavigationLink {
                        CheckInDetailView(checkIn: checkIn)
                    } label: {
                        HistoryRow(checkIn: checkIn)
                    }
                }
            }
        }
        .navigationTitle("History")
        .task { await load() }
    }

    private func load() async {
        let today = container.dates.today
        let start = today.adding(days: -365, in: container.dates.calendar)
        let loaded = (try? await container.store.checkIns(from: start, to: today)) ?? []
        // Newest first — the list is for "how have I been", which reads backwards.
        checkIns = loaded.filter(\.isComplete).sorted { $0.localDate > $1.localDate }
        didLoad = true
    }
}

private struct HistoryRow: View {
    let checkIn: CheckIn

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(checkIn.localDate.formattedMedium)
                    .font(.subheadline.weight(.medium))
                Text(
                    checkIn.regulatedCount > 0
                        ? "\(checkIn.regulatedCount) regulated"
                        : "no regulation needed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let after = checkIn.averageAfter {
                // Neutral ink, deliberately. Tinting a past low day red is the
                // exact manipulation shown to raise rumination and lower
                // self-compassion in this age group (ARCHITECTURE.md §11.1).
                Text(after, format: .number.precision(.fractionLength(1)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-\(checkIn.localDate.iso)")
    }
}

/// A past check-in, category by category.
struct CheckInDetailView: View {
    let checkIn: CheckIn

    var body: some View {
        List {
            Section {
                LabeledContent("Categories", value: "\(checkIn.scores.count)")
                LabeledContent("Regulated", value: "\(checkIn.regulatedCount)")
                if let delta = checkIn.averageDelta {
                    LabeledContent(
                        "Average change",
                        value: (delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(1)))
                    )
                }
            }

            Section("Scores") {
                ForEach(checkIn.scores) { score in
                    HStack {
                        Text(score.category.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text("\(score.before.value)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let after = score.after {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            // Colour marks improvement, never lowness — and it's
                            // paired with the arrow and the numbers, so it never
                            // carries meaning alone.
                            Text("\(after.value)")
                                .monospacedDigit()
                                .foregroundStyle(
                                    after.value > score.before.value
                                        ? ChartPalette.improvement : .primary
                                )
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(checkIn.localDate.formattedMedium)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension LocalDate {
    /// Locale-aware display date. The stored form stays ISO — this is presentation
    /// only, so a student in another region sees their own format.
    var formattedMedium: String {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return iso }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

#Preview("history") {
    NavigationStack { HistoryView() }
        .environment(
            AppContainer.live(arguments: ["-CalScenario", "day30Streak", "-CalFixedDate", "2026-07-30"])
        )
}

#Preview("detail") {
    NavigationStack { CheckInDetailView(checkIn: .fixture(band: .low, regulated: true)) }
}
