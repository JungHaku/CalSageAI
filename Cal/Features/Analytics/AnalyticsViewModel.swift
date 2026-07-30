import CalData
import CalKit
import Foundation
import Observation

@Observable
final class AnalyticsViewModel {
    private(set) var trend: CoherenceTrend = .empty()
    private(set) var categories: [CategorySummary] = []
    private(set) var meanDelta: Double?
    private(set) var regulatedCount = 0
    private(set) var granularity: TrendGranularity = .day

    private let store: any CoherenceStoring
    private let dates: any DateProvider
    private var history: [CheckIn] = []

    /// How far back each granularity looks. A daily chart of 90 points is a smear;
    /// a monthly chart of 30 days is one bar. The window follows the bucket size.
    private var windowDays: Int {
        switch granularity {
        case .day: 30
        case .week: 90
        case .month: 365
        }
    }

    init(store: any CoherenceStoring, dates: any DateProvider) {
        self.store = store
        self.dates = dates
    }

    var isEmpty: Bool { history.isEmpty }

    func load() async {
        let today = dates.today
        let calendar = dates.calendar
        // Load the widest window once, then re-bucket locally when the
        // granularity changes — no refetch per filter change.
        let start = today.adding(days: -365, in: calendar)
        history = ((try? await store.checkIns(from: start, to: today)) ?? []).filter(\.isComplete)
        recompute()
    }

    func setGranularity(_ newValue: TrendGranularity) async {
        guard newValue != granularity else { return }
        granularity = newValue
        recompute()
    }

    private func recompute() {
        let today = dates.today
        let calendar = dates.calendar
        let start = today.adding(days: -(windowDays - 1), in: calendar)

        trend = CoherenceTrend.build(
            history: history, granularity: granularity, from: start, to: today, calendar: calendar
        )
        categories = CategorySummary.build(history: history, from: start, to: today)

        let deltas = history
            .filter { $0.localDate >= start }
            .flatMap { $0.scores.compactMap { $0.delta.map(Double.init) } }
        regulatedCount = deltas.count
        meanDelta = deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count)
    }

    // MARK: Accessibility
    //
    // Swift Charts gives VoiceOver per-mark navigation but no summary of what the
    // chart says. Without these, a non-visual reader gets a list of coordinates
    // and no headline — so each chart carries a spoken summary, and the table view
    // is the full alternative.

    var trendAccessibilitySummary: String {
        let populated = trend.populated
        guard let first = populated.first?.averageAfter,
              let last = populated.last?.averageAfter
        else { return "No data yet." }

        let direction =
            if abs(last - first) < 0.1 { "roughly steady" }
            else if last > first { "higher than at the start" }
            else { "lower than at the start" }

        return """
        \(populated.count) \(granularity.displayName.lowercased()) points, \
        from \(first.formatted(.number.precision(.fractionLength(1)))) \
        to \(last.formatted(.number.precision(.fractionLength(1)))) out of 10, \(direction).
        """
    }

    var categoryAccessibilitySummary: String {
        guard let weakest = categories.first else { return "No data yet." }
        var parts = [
            "Lowest is \(weakest.category.displayName) at "
                + weakest.averageBefore.formatted(.number.precision(.fractionLength(1)))
                + " out of 10."
        ]
        if let strongest = categories.last, strongest.id != weakest.id {
            parts.append(
                "Highest is \(strongest.category.displayName) at "
                    + strongest.averageBefore.formatted(.number.precision(.fractionLength(1)))
                    + "."
            )
        }
        return parts.joined(separator: " ")
    }
}
