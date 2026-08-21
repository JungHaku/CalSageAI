import Foundation
import Testing

@testable import CalKit

@Suite("CoherenceTrend")
struct CoherenceTrendTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    let today = LocalDate(iso: "2026-07-30")!

    private func trend(
        _ history: [CheckIn],
        _ granularity: TrendGranularity = .day,
        days: Int = 13
    ) -> CoherenceTrend {
        CoherenceTrend.build(
            history: history,
            granularity: granularity,
            from: today.adding(days: -days, in: calendar),
            to: today,
            calendar: calendar
        )
    }

    @Test("an empty history still produces the full window, all buckets empty")
    func emptyHistory() {
        let result = trend([], .day, days: 6)
        #expect(result.points.count == 7)
        let allEmpty = result.points.allSatisfy(\.isEmpty)
        #expect(allEmpty)
        #expect(result.populated.isEmpty)
        #expect(!result.hasEnoughForTrend)
    }

    // The reason `averageBefore` is optional. A skipped Tuesday is a gap; drawing
    // a line through it, or plotting zero, invents a score the student never gave.
    @Test("a missed day is an empty bucket, not a zero and not a closed-up gap")
    func missingDaysAreGaps() {
        let history = [
            CheckIn.fixture(band: .high, on: today.adding(days: -2, in: calendar)),
            CheckIn.fixture(band: .high, on: today),
        ]
        let result = trend(history, .day, days: 2)

        #expect(result.points.count == 3)
        #expect(result.points[1].isEmpty)
        #expect(result.points[1].averageBefore == nil, "a gap must not become a zero")
        #expect(result.populated.count == 2)
    }

    // Plotting every point as one series would draw a straight line across a
    // skipped week — inventing a smooth trend that never happened.
    @Test("a gap splits the series into separate runs, so the line breaks")
    func segmentsBreakAtGaps() {
        let history = [
            CheckIn.fixture(band: .high, on: today.adding(days: -4, in: calendar)),
            CheckIn.fixture(band: .high, on: today.adding(days: -3, in: calendar)),
            // two-day gap
            CheckIn.fixture(band: .high, on: today),
        ]
        let segments = trend(history, .day, days: 4).segments
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 1)
    }

    @Test("an unbroken history is a single run")
    func singleSegment() {
        let history = CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: calendar)
        #expect(trend(history, .day, days: 9).segments.count == 1)
    }

    @Test("an empty history has no runs at all")
    func noSegments() {
        #expect(trend([], .day, days: 6).segments.isEmpty)
    }

    @Test("daily buckets are contiguous and ordered oldest first")
    func dailyBucketsAreContiguous() {
        let result = trend([], .day, days: 9)
        #expect(result.points.count == 10)
        for (a, b) in zip(result.points, result.points.dropFirst()) {
            #expect(b.periodStart.days(since: a.periodStart, in: calendar) == 1)
        }
    }

    @Test("several check-ins in one day average into a single bucket")
    func multiplePerDayAverage() {
        let history = [
            CheckIn.fixture(band: .high, on: today),   // 9s
            CheckIn.fixture(band: .low, on: today, regulated: false),  // 3s
        ]
        let result = trend(history, .day, days: 0)
        #expect(result.points.count == 1)
        #expect(result.points[0].checkInCount == 2)
        #expect(result.points[0].averageBefore == 6.0)
    }

    @Test("weekly buckets are seven days apart and collapse a week's check-ins")
    func weeklyBuckets() {
        let history = CheckIn.syntheticHistory(days: 21, endingOn: today, calendar: calendar)
        let result = trend(history, .week, days: 20)

        for (a, b) in zip(result.points, result.points.dropFirst()) {
            #expect(b.periodStart.days(since: a.periodStart, in: calendar) == 7)
        }
        let allPopulated = result.points.allSatisfy { $0.checkInCount > 0 }
        #expect(allPopulated)
        #expect(result.points.count < 21, "weekly buckets must collapse the daily series")
    }

    @Test("monthly buckets start on the first and step one month, including across a year")
    func monthlyBuckets() {
        let start = LocalDate(iso: "2026-11-15")!
        let end = LocalDate(iso: "2027-02-03")!
        let result = CoherenceTrend.build(
            history: [], granularity: .month, from: start, to: end, calendar: calendar
        )
        #expect(result.points.map(\.periodStart.iso) == [
            "2026-11-01", "2026-12-01", "2027-01-01", "2027-02-01",
        ])
    }

    @Test("a trend needs at least three populated points before it claims a direction")
    func minimumPoints() {
        let two = [
            CheckIn.fixture(band: .high, on: today),
            CheckIn.fixture(band: .high, on: today.adding(days: -1, in: calendar)),
        ]
        #expect(!trend(two).hasEnoughForTrend)

        let three = two + [CheckIn.fixture(band: .high, on: today.adding(days: -2, in: calendar))]
        #expect(trend(three).hasEnoughForTrend)
    }

    // A zoomed axis turns a 0.3 wobble on a 0–10 scale into a cliff. The domain is
    // the scale, always.
    @Test("the chart domain is the full scale, not fitted to the data")
    func fixedDomain() {
        #expect(CoherenceTrend.scaleDomain == 0...10)
    }

    @Test("delta is nil when nothing was regulated, rather than a fabricated zero")
    func deltaNilWithoutRegulation() {
        let result = trend([CheckIn.fixture(band: .high, on: today)], .day, days: 0)
        #expect(result.points[0].delta == nil)

        let regulated = trend([CheckIn.fixture(band: .low, on: today, regulated: true)], .day, days: 0)
        #expect(regulated.points[0].delta == 3.0)
    }

    @Test("check-ins outside the window are excluded")
    func windowBounds() {
        let history = [
            CheckIn.fixture(band: .high, on: today.adding(days: -40, in: calendar)),
            CheckIn.fixture(band: .high, on: today),
        ]
        #expect(trend(history, .day, days: 6).populated.count == 1)
    }

    @Test("a 60-day history buckets into a sane number of points at each granularity")
    func sixtyDayFixture() {
        let history = CheckIn.syntheticHistory(days: 60, endingOn: today, calendar: calendar)
        #expect(trend(history, .day, days: 59).populated.count == 60)
        #expect(trend(history, .week, days: 59).populated.count <= 10)
        #expect(trend(history, .month, days: 59).populated.count <= 4)
    }
}

@Suite("CategorySummary")
struct CategorySummaryTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    let today = LocalDate(iso: "2026-07-30")!

    private func build(_ history: [CheckIn]) -> [CategorySummary] {
        CategorySummary.build(
            history: history, from: today.adding(days: -30, in: calendar), to: today
        )
    }

    @Test("an empty history yields no summaries rather than ten zeroed rows")
    func empty() {
        #expect(build([]).isEmpty)
    }

    @Test("the overall category is excluded — it belongs to the free single question")
    func excludesOverall() {
        var quick = CheckIn(kind: .quick, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        quick.scores = [CategoryScore(category: .overall, before: Score(clamping: 5))]
        quick.completedAt = Date()
        #expect(build([quick]).isEmpty)
    }

    // "Where do I keep getting stuck" is the useful question, not "what am I
    // already good at".
    @Test("summaries are ordered weakest first")
    func weakestFirst() {
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [
            CategoryScore(category: .safety, before: Score(clamping: 9)),
            CategoryScore(category: .breath, before: Score(clamping: 2)),
            CategoryScore(category: .energy, before: Score(clamping: 5)),
        ]
        checkIn.completedAt = Date()

        #expect(build([checkIn]).map(\.category) == [.breath, .energy, .safety])
    }

    @Test("averages and regulation counts are computed per category")
    func averages() {
        var first = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        first.scores = [CategoryScore(category: .breath, before: Score(clamping: 2), after: Score(clamping: 6))]
        first.completedAt = Date()

        var second = CheckIn(kind: .full, localDate: today.adding(days: -1, in: calendar), timeZoneIdentifier: "America/Los_Angeles")
        second.scores = [CategoryScore(category: .breath, before: Score(clamping: 4))]
        second.completedAt = Date()

        let summary = build([first, second])[0]
        #expect(summary.category == .breath)
        #expect(summary.averageBefore == 3.0)      // (2 + 4) / 2
        #expect(summary.averageAfter == 6.0)       // only the regulated one
        #expect(summary.timesRated == 2)
        #expect(summary.timesRegulated == 1)
        #expect(summary.delta == 3.0)
    }

    @Test("a category never regulated has no after value and no delta")
    func noRegulation() {
        var checkIn = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [CategoryScore(category: .safety, before: Score(clamping: 9))]
        checkIn.completedAt = Date()

        let summary = build([checkIn])[0]
        #expect(summary.averageAfter == nil)
        #expect(summary.delta == nil)
        #expect(summary.timesRegulated == 0)
    }

    @Test("incomplete check-ins are excluded")
    func ignoresIncomplete() {
        var partial = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        partial.scores = [CategoryScore(category: .breath, before: Score(clamping: 2))]
        #expect(build([partial]).isEmpty)
    }

    @Test("the 60-day fixture yields all five check-in categories")
    func sixtyDayFixture() {
        let history = CheckIn.syntheticHistory(days: 60, endingOn: today, calendar: calendar)
        let summaries = CategorySummary.build(
            history: history, from: today.adding(days: -59, in: calendar), to: today
        )
        #expect(summaries.count == 5)
        let allRated = summaries.allSatisfy { $0.timesRated == 60 }
        #expect(allRated)
    }
}
