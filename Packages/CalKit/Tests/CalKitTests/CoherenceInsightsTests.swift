import Foundation
import Testing

@testable import CalKit

@Suite("CoherenceInsights")
struct CoherenceInsightsTests {
    let today = LocalDate(iso: "2026-07-30")!
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func build(_ history: [CheckIn], windowDays: Int = 30) -> CoherenceInsights {
        CoherenceInsights.build(history: history, today: today, calendar: calendar, windowDays: windowDays)
    }

    @Test("a first launch reports zeroes, not nils dressed up as numbers")
    func emptyHistory() {
        let insights = build([])
        #expect(insights.currentStreak == 0)
        #expect(insights.totalCheckIns == 0)
        #expect(!insights.hasCheckedInToday)
        #expect(insights.windowAverage == nil)
        #expect(insights.meanDelta == nil)
        #expect(insights.trend == nil)
        #expect(insights.consistency == 0)
    }

    @Test("today's completed check-in is surfaced")
    func todaysCheckIn() {
        let insights = build([CheckIn.fixture(band: .high, on: today)])
        #expect(insights.hasCheckedInToday)
        #expect(insights.todaysCheckIn?.localDate == today)
        #expect(insights.currentStreak == 1)
    }

    // An abandoned check-in must not count as done — otherwise the streak rewards
    // opening the app rather than actually checking in.
    @Test("an unfinished check-in is reported separately and doesn't count as done")
    func inProgressIsNotComplete() {
        var partial = CheckIn(kind: .full, localDate: today, timeZoneIdentifier: "America/Los_Angeles")
        partial.scores = [CategoryScore(category: .safety, before: Score(clamping: 6))]

        let insights = build([partial])
        #expect(!insights.hasCheckedInToday)
        #expect(insights.inProgress != nil)
        #expect(insights.currentStreak == 0)
        #expect(insights.totalCheckIns == 0)
    }

    @Test("streaks come from the shared calculator, including the yesterday grace")
    func streaks() {
        let history = CheckIn.syntheticHistory(days: 12, endingOn: today, calendar: calendar)
        let insights = build(history)
        #expect(insights.currentStreak == 12)
        #expect(insights.longestStreak == 12)
        #expect(insights.totalCheckIns == 12)
    }

    @Test("consistency counts distinct days in the window, so a gap doesn't erase it")
    func consistencySurvivesGaps() {
        // 20 days of history, then a five-day gap, then today.
        var history = CheckIn.syntheticHistory(days: 20, endingOn: today.adding(days: -6, in: calendar), calendar: calendar)
        history.append(CheckIn.fixture(band: .high, on: today))

        let insights = build(history)
        #expect(insights.currentStreak == 1, "the streak resets after a gap")
        #expect(insights.daysPracticedInWindow == 21)
        #expect(abs(insights.consistency - 21.0 / 30.0) < 0.0001)
    }

    @Test("two check-ins on the same day count once toward consistency")
    func duplicateDaysCountOnce() {
        let insights = build([
            CheckIn.fixture(band: .high, on: today),
            CheckIn.fixture(band: .low, on: today),
        ])
        #expect(insights.daysPracticedInWindow == 1)
    }

    @Test("check-ins older than the window are excluded from consistency but not the total")
    func windowBounds() {
        let old = CheckIn.fixture(band: .high, on: today.adding(days: -45, in: calendar))
        let recent = CheckIn.fixture(band: .high, on: today)
        let insights = build([old, recent])

        #expect(insights.totalCheckIns == 2)
        #expect(insights.daysPracticedInWindow == 1)
    }

    // MARK: Trend

    @Test("a small change reads as steady rather than as improvement")
    func smallChangeIsSteady() {
        // Same band on both windows → averages within noise.
        var history = (0..<7).map { CheckIn.fixture(band: .moderate, on: today.adding(days: -$0, in: calendar)) }
        history += (7..<14).map { CheckIn.fixture(band: .moderate, on: today.adding(days: -$0, in: calendar)) }
        #expect(build(history).trend == .steady)
    }

    @Test("a real rise reads as up, a real fall as down")
    func trendDirection() {
        let recentHigh = (0..<7).map { CheckIn.fixture(band: .high, on: today.adding(days: -$0, in: calendar)) }
        let olderLow = (7..<14).map { CheckIn.fixture(band: .low, on: today.adding(days: -$0, in: calendar), regulated: false) }
        #expect(build(recentHigh + olderLow).trend == .up)

        let recentLow = (0..<7).map { CheckIn.fixture(band: .low, on: today.adding(days: -$0, in: calendar), regulated: false) }
        let olderHigh = (7..<14).map { CheckIn.fixture(band: .high, on: today.adding(days: -$0, in: calendar)) }
        #expect(build(recentLow + olderHigh).trend == .down)
    }

    @Test("with only one window of history there is no trend to report")
    func noTrendWithoutComparison() {
        let history = (0..<5).map { CheckIn.fixture(band: .moderate, on: today.adding(days: -$0, in: calendar)) }
        #expect(build(history).trend == nil)
    }

    // MARK: The headline metric

    @Test("mean delta averages only regulated categories, across all history")
    func meanDelta() {
        // The .low fixture regulates every category, +3 each.
        let insights = build([CheckIn.fixture(band: .low, on: today, regulated: true)])
        #expect(insights.meanDelta == 3.0)
    }

    @Test("unregulated history yields no delta rather than a fabricated zero")
    func noDeltaWithoutRegulation() {
        #expect(build([CheckIn.fixture(band: .high, on: today)]).meanDelta == nil)
    }
}

@Suite("Daily motivation rotation")
struct MotivationRotationTests {
    let calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private let pool = (1...5).map { Motivation(id: "m\($0)", body: "Body \($0)") }

    @Test("an empty pool yields nothing rather than crashing the home screen")
    func emptyPool() {
        #expect(Motivation.forDay(LocalDate(iso: "2026-07-30")!, from: [], calendar: calendar) == nil)
    }

    @Test("the same day always gives the same message")
    func stableWithinADay() {
        let day = LocalDate(iso: "2026-07-30")!
        #expect(
            Motivation.forDay(day, from: pool, calendar: calendar)
                == Motivation.forDay(day, from: pool, calendar: calendar)
        )
    }

    // The reason this is a rotation and not a hash: with a five-item pool a hash
    // collides constantly, and the same line two mornings running reads as a bug.
    @Test("every message is used once before any repeats")
    func fullCycleBeforeRepeat() {
        var start = LocalDate(iso: "2026-07-30")!
        var seen: [String] = []
        for _ in 0..<pool.count {
            let pick = Motivation.forDay(start, from: pool, calendar: calendar)
            seen.append(pick!.id)
            start = start.adding(days: 1, in: calendar)
        }
        #expect(Set(seen).count == pool.count, "repeated within one cycle: \(seen)")
    }

    @Test("the cycle repeats after exactly pool.count days")
    func cycleLength() {
        let day = LocalDate(iso: "2026-07-30")!
        let later = day.adding(days: pool.count, in: calendar)
        #expect(
            Motivation.forDay(day, from: pool, calendar: calendar)?.id
                == Motivation.forDay(later, from: pool, calendar: calendar)?.id
        )
    }

    // Month boundaries are exactly where a naive year*372+month*31+day encoding
    // skips, which would let a message repeat two days apart.
    @Test("consecutive days never repeat, including across month and year boundaries")
    func noAdjacentRepeatsAcrossBoundaries() {
        var day = LocalDate(iso: "2026-01-28")!
        var previous: String?
        for _ in 0..<400 {
            let pick = Motivation.forDay(day, from: pool, calendar: calendar)!.id
            #expect(pick != previous, "repeated on consecutive days at \(day)")
            previous = pick
            day = day.adding(days: 1, in: calendar)
        }
    }

    @Test("the rotation order is stable across processes, not seeded per launch")
    func stableOrder() {
        #expect(Motivation.rotationOrder(pool).map(\.id) == Motivation.rotationOrder(pool).map(\.id))
        // A specific expected order pins that the shuffle is genuinely seeded.
        #expect(Set(Motivation.rotationOrder(pool).map(\.id)) == Set(pool.map(\.id)))
    }

    @Test("dates before the epoch index forwards, not off the front of the array")
    func negativeDayNumbers() {
        let ancient = LocalDate(iso: "1990-03-04")!
        #expect(ancient.dayNumber(in: calendar) < 0)
        #expect(Motivation.forDay(ancient, from: pool, calendar: calendar) != nil)
    }

    @Test("day numbers increment by exactly one per calendar day, including over DST")
    func dayNumberIsMonotonic() {
        var day = LocalDate(iso: "2026-03-06")!  // spans the spring-forward transition
        for _ in 0..<6 {
            let next = day.adding(days: 1, in: calendar)
            #expect(next.dayNumber(in: calendar) - day.dayNumber(in: calendar) == 1)
            day = next
        }
    }
}
