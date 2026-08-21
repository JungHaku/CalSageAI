import CalContent
import CalDesign
import CalKit
import SwiftUI

/// TODAY tab root (`PLAN-cal-sage-shell.md` §4): greeting, quick reset, one line
/// of encouragement. Unused as a root — Cal is the home — but still compiled.
struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var motivation: Motivation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(greeting)
                    .font(.largeTitle.weight(.semibold))
                quickReset
                if let motivation { MotivationCard(motivation: motivation) }
            }
            .padding()
        }
        .background(alignment: .top) {
            CalWatermark(opacity: 0.10)
                .frame(width: 300)
                .offset(x: 90, y: -30)
        }
        .navigationTitle("Today")
        .accessibilityIdentifier("today-root")
        .task { await load() }
        .refreshable { await load() }
    }

    private var greeting: String {
        let hour = container.dates.calendar.component(.hour, from: container.dates.now)
        return switch hour {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var quickReset: some View {
        NavigationLink(value: VoiceRoute.practice(slug: "study-reset", autoStart: true)) {
            HStack(spacing: 14) {
                Image(systemName: "wind")
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Reset").font(.headline).foregroundStyle(.primary)
                    Text("Thirty seconds back to your body")
                        .font(.caption)
                        .foregroundStyle(Surface.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Surface.card, in: .rect(cornerRadius: 14))
        .accessibilityIdentifier("quick-reset")
    }

    private func load() async {
        let pool = (try? await container.content.motivations()) ?? []
        motivation = Motivation.forDay(container.dates.today, from: pool, calendar: container.dates.calendar)
    }
}

private struct MotivationCard: View {
    let motivation: Motivation

    var body: some View {
        Text(motivation.body)
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Surface.card, in: .rect(cornerRadius: 14))
            .accessibilityIdentifier("daily-motivation")
    }
}

#Preview("first launch") {
    NavigationStack { HomeView() }
        .environment(AppContainer.live(arguments: ["-CalScenario", "empty", "-CalFixedDate", "2026-07-30"]))
}
