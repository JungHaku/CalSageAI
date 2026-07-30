import CalData
import CalDesign
import CalKit
import Charts
import SwiftUI

/// Trends over time and per category.
///
/// Chart-form choices, each made from the data's job rather than from taste:
///
/// - The mean before→after change is a **hero figure**, not a chart. It's one
///   number, and a one-bar bar chart would be the classic way to miss that.
/// - Coherence over time is a **single-series line**: one hue, no legend (the
///   title names it), y-axis pinned to the full 0–10 scale.
/// - Before→after per category is a **dumbbell** — the canonical form for
///   before→after per item — in one hue, two validated shades.
/// - Every chart has a **table view twin**, so no value is reachable only by
///   colour or only by a chart.
struct AnalyticsView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: AnalyticsViewModel?
    @State private var showTable = false

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 28) {
                    // One filter row above everything it scopes — never a
                    // per-chart control.
                    granularityPicker(model)

                    if model.isEmpty {
                        ContentUnavailableView(
                            "Nothing to show yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Check in a few times and your trends will appear here.")
                        )
                        .padding(.top, 40)
                    } else {
                        heroDelta(model)
                        trendSection(model)
                        categorySection(model)
                        disclaimer
                    }
                }
                .padding()
            } else {
                ProgressView().padding(.top, 60)
            }
        }
        .navigationTitle("Progress")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTable.toggle()
                } label: {
                    Label(
                        showTable ? "Show charts" : "Show table",
                        systemImage: showTable ? "chart.xyaxis.line" : "tablecells"
                    )
                }
                .accessibilityIdentifier("toggle-table")
            }
        }
        .task {
            guard model == nil else { return }
            let created = AnalyticsViewModel(store: container.store, dates: container.dates)
            await created.load()
            model = created
        }
    }

    // MARK: Filter

    private func granularityPicker(_ model: AnalyticsViewModel) -> some View {
        Picker("Group by", selection: Binding(
            get: { model.granularity },
            set: { newValue in Task { await model.setGranularity(newValue) } }
        )) {
            ForEach(TrendGranularity.allCases, id: \.self) { granularity in
                Text(granularity.displayName).tag(granularity)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("granularity-picker")
    }

    // MARK: Hero

    @ViewBuilder
    private func heroDelta(_ model: AnalyticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let delta = model.meanDelta {
                // Proportional figures, system sans — a hero number is not a
                // column and doesn't want tabular digits.
                Text((delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(ChartPalette.improvement)
                    .accessibilityIdentifier("hero-delta")
                Text("average change after a practice, across \(model.regulatedCount) sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No practices recorded yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Trend

    @ViewBuilder
    private func trendSection(_ model: AnalyticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coherence over time")
                .font(.headline)

            if !model.trend.hasEnoughForTrend {
                Text("At least \(CoherenceTrend.minimumPointsForTrend) check-ins are needed before a trend means anything.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if showTable {
                trendTable(model)
            } else {
                trendChart(model)
            }
        }
    }

    private func trendChart(_ model: AnalyticsViewModel) -> some View {
        Chart {
            // One LineMark per contiguous run, so a skipped period is a real gap
            // rather than a straight line inventing a trend across it.
            ForEach(Array(model.trend.segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { point in
                    LineMark(
                        x: .value("Date", point.periodStart.chartDate),
                        y: .value("Coherence", point.averageAfter ?? 0),
                        series: .value("run", index)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(ChartPalette.primary)
                    .interpolationMethod(.monotone)

                    // Markers only when there are few enough to read; past that
                    // they become noise on the line.
                    if segment.count <= 14 {
                        PointMark(
                            x: .value("Date", point.periodStart.chartDate),
                            y: .value("Coherence", point.averageAfter ?? 0)
                        )
                        .symbolSize(60)
                        .foregroundStyle(ChartPalette.primary)
                    }
                }
            }
        }
        // The full scale, never fitted to the data: on a bounded 0–10 self-report
        // measure a zoomed axis turns a rounding wobble into a cliff.
        .chartYScale(domain: CoherenceTrend.scaleDomain)
        .chartYAxis {
            AxisMarks(values: [0, 2, 4, 6, 8, 10]) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(ChartPalette.gridline)
                AxisValueLabel()
                    .foregroundStyle(ChartPalette.axisLabel)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(ChartPalette.gridline)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(ChartPalette.axisLabel)
            }
        }
        // Single series — the title names it, so no legend box.
        .chartLegend(.hidden)
        .frame(height: 200)
        .accessibilityElement()
        .accessibilityLabel("Coherence over time")
        .accessibilityValue(model.trendAccessibilitySummary)
    }

    private func trendTable(_ model: AnalyticsViewModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.trend.populated) { point in
                HStack {
                    Text(point.periodStart.formattedMedium)
                        .font(.subheadline)
                    Spacer()
                    Text((point.averageAfter ?? 0).formatted(.number.precision(.fractionLength(1))))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .accessibilityIdentifier("trend-table")
    }

    // MARK: Categories

    @ViewBuilder
    private func categorySection(_ model: AnalyticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By area")
                .font(.headline)
            Text("Weakest first. The lighter dot is where you started; the darker one is after a practice.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showTable {
                categoryTable(model)
            } else {
                categoryChart(model)
            }
        }
    }

    private func categoryChart(_ model: AnalyticsViewModel) -> some View {
        Chart {
            ForEach(model.categories) { summary in
                // The connecting rule first, so the dots sit on top of it.
                if let after = summary.averageAfter {
                    RuleMark(
                        xStart: .value("Before", summary.averageBefore),
                        xEnd: .value("After", after),
                        y: .value("Area", summary.category.displayName)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(ChartPalette.secondary)
                }

                PointMark(
                    x: .value("Score", summary.averageBefore),
                    y: .value("Area", summary.category.displayName)
                )
                .symbolSize(70)
                .foregroundStyle(by: .value("Stage", "Before"))

                if let after = summary.averageAfter {
                    PointMark(
                        x: .value("Score", after),
                        y: .value("Area", summary.category.displayName)
                    )
                    .symbolSize(70)
                    .foregroundStyle(by: .value("Stage", "After"))
                }
            }
        }
        .chartXScale(domain: CoherenceTrend.scaleDomain)
        .chartForegroundStyleScale([
            "Before": ChartPalette.secondary,
            "After": ChartPalette.primary,
        ])
        // Two series here, so a legend is required — identity must never rest on
        // colour alone.
        .chartLegend(position: .bottom, spacing: 12)
        .chartXAxis {
            AxisMarks(values: [0, 2, 4, 6, 8, 10]) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(ChartPalette.gridline)
                AxisValueLabel()
                    .foregroundStyle(ChartPalette.axisLabel)
            }
        }
        .chartYAxis {
            AxisMarks { AxisValueLabel()
                    .foregroundStyle(ChartPalette.axisLabel) }
        }
        .frame(height: CGFloat(model.categories.count) * 34 + 60)
        .accessibilityElement()
        .accessibilityLabel("Average score by area, weakest first")
        .accessibilityValue(model.categoryAccessibilitySummary)
    }

    private func categoryTable(_ model: AnalyticsViewModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.categories) { summary in
                HStack {
                    Text(summary.category.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(summary.averageBefore.formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let after = summary.averageAfter {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(after.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                Divider()
            }
        }
        .accessibilityIdentifier("category-table")
    }

    /// Descriptive, not causal. This is single-arm self-report with no control:
    /// the honest statement is that the numbers moved, not that the practice
    /// moved them.
    private var disclaimer: some View {
        Text("These are your own ratings, not a clinical measure.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

extension LocalDate {
    /// Charts plot `Date`; noon avoids a DST-shifted midnight landing on the
    /// previous day.
    var chartDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}

#Preview("60 days") {
    NavigationStack { AnalyticsView() }
        .environment(
            AppContainer.live(arguments: ["-CalScenario", "day30Streak", "-CalFixedDate", "2026-07-30"])
        )
}

#Preview("empty") {
    NavigationStack { AnalyticsView() }
        .environment(AppContainer.live(arguments: ["-CalScenario", "empty", "-CalFixedDate", "2026-07-30"]))
}
