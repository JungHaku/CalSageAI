import CalContent
import CalData
import CalDesign
import CalKit
import SwiftUI

/// The landing screen: where you are today, one line of encouragement, and the
/// two ways in — check in, or practise.
struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var insights: CoherenceInsights?
    @State private var motivation: Motivation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                todayCard
                if let motivation { MotivationCard(motivation: motivation) }
                if let insights, insights.totalCheckIns > 0 { progressCard(insights) }
                destinations
            }
            .padding()
        }
        .navigationTitle("Cal")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Today

    @ViewBuilder
    private var todayCard: some View {
        let done = insights?.hasCheckedInToday ?? false
        VStack(alignment: .leading, spacing: 12) {
            Text(greeting)
                .font(.largeTitle.weight(.semibold))

            if done, let checkIn = insights?.todaysCheckIn {
                Label("Checked in today", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(CoherenceScale.tint(for: .high))
                    .accessibilityIdentifier("checked-in-today")
                if let delta = checkIn.averageDelta, checkIn.regulatedCount > 0 {
                    Text(
                        "You moved \(delta >= 0 ? "+" : "")\(delta.formatted(.number.precision(.fractionLength(1)))) on average today."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            } else {
                NavigationLink(value: HomeRoute.checkIn) {
                    Label(
                        insights?.inProgress != nil ? "Finish today's check-in" : "Start today's check-in",
                        systemImage: "brain.head.profile"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("start-checkin")
            }
        }
    }

    private var greeting: String {
        let hour = container.dates.calendar.component(.hour, from: container.dates.now)
        return switch hour {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: Progress

    private func progressCard(_ insights: CoherenceInsights) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your progress")
                .font(.headline)

            // Consistency leads, not the streak. "18 of the last 30 days" survives
            // a missed Tuesday; a streak resets to zero and takes the credit with
            // it. In a wellness app aimed at stressed students, a counter that
            // punishes one bad day is the wrong incentive to put first.
            StatRow(
                label: "Days practised",
                value: "\(insights.daysPracticedInWindow) of \(insights.windowDays)",
                identifier: "stat-consistency"
            )

            if let delta = insights.meanDelta {
                StatRow(
                    label: "Average change after regulating",
                    value: (delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(1))),
                    identifier: "stat-delta",
                    tint: CoherenceScale.tint(for: .high)
                )
            }

            // Weeks, not days. A daily counter would mark most people as failing
            // every week and produces a loss event on any bad week; a weekly one
            // survives exams and illness without one.
            if insights.currentWeeklyStreak > 0 {
                StatRow(
                    label: "Weeks in a row",
                    value: "\(insights.currentWeeklyStreak)",
                    identifier: "stat-streak"
                )
            }

            if let trend = insights.trend, let average = insights.windowAverage {
                Label(
                    "7-day average \(average.formatted(.number.precision(.fractionLength(1)))) · \(trendWord(trend))",
                    systemImage: trendIcon(trend)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }

    // Neutral vocabulary on purpose: "easing" rather than "worse". A number going
    // down on a coherence scale is information, not a failing.
    private func trendWord(_ trend: CoherenceInsights.Trend) -> String {
        switch trend {
        case .up: "rising"
        case .down: "easing"
        case .steady: "steady"
        }
    }

    private func trendIcon(_ trend: CoherenceInsights.Trend) -> String {
        switch trend {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .steady: "arrow.right"
        }
    }

    // MARK: Destinations

    private var destinations: some View {
        VStack(spacing: 0) {
            NavigationLink(value: HomeRoute.practices) {
                DestinationRow(
                    title: "Practices", subtitle: "Guided coherence sessions",
                    icon: "wind", identifier: "dest-practices"
                )
            }
            Divider()
            NavigationLink(value: HomeRoute.history) {
                DestinationRow(
                    title: "History", subtitle: "Your past check-ins",
                    icon: "calendar", identifier: "dest-history"
                )
            }
            Divider()
            NavigationLink(value: HomeRoute.settings) {
                DestinationRow(
                    title: "Settings", subtitle: "Reminder and your data",
                    icon: "gear", identifier: "dest-settings"
                )
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }

    private func load() async {
        let today = container.dates.today
        let calendar = container.dates.calendar
        let history = (try? await container.store.recent(days: 60, today: today, calendar: calendar)) ?? []
        insights = CoherenceInsights.build(history: history, today: today, calendar: calendar)

        let pool = (try? await container.content.motivations()) ?? []
        motivation = Motivation.forDay(today, from: pool, calendar: calendar)
    }
}

enum HomeRoute: Hashable {
    case checkIn, practices, history, settings
}

private struct MotivationCard: View {
    let motivation: Motivation

    var body: some View {
        Text(motivation.body)
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
            .accessibilityIdentifier("daily-motivation")
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let identifier: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct DestinationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let identifier: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

#Preview("first launch") {
    NavigationStack { HomeView() }
        .environment(AppContainer.live(arguments: ["-CalScenario", "empty", "-CalFixedDate", "2026-07-30"]))
}

#Preview("30-day history") {
    NavigationStack { HomeView() }
        .environment(AppContainer.live(arguments: ["-CalScenario", "day30Streak", "-CalFixedDate", "2026-07-30"]))
}
