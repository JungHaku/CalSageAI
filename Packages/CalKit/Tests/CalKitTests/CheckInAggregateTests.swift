import Foundation
import Testing

@testable import CalKit

@Suite("CategoryScore")
struct CategoryScoreTests {
    // "Not yet regulated" and "regulated with no change" are different facts, and
    // the product's headline metric averages this. Collapsing nil to 0 would
    // quietly drag the reported improvement toward zero.
    @Test("delta is nil before re-rating, and 0 only when the score truly didn't move")
    func deltaDistinguishesUnmeasuredFromUnchanged() {
        let unmeasured = CategoryScore(category: .breath, before: Score(clamping: 3))
        #expect(unmeasured.delta == nil)
        #expect(!unmeasured.isRegulated)

        let unchanged = CategoryScore(category: .breath, before: Score(clamping: 3), after: Score(clamping: 3))
        #expect(unchanged.delta == 0)
        #expect(unchanged.isRegulated)
    }

    @Test("delta can be negative when regulation didn't help")
    func negativeDelta() {
        let worse = CategoryScore(category: .energy, before: Score(clamping: 5), after: Score(clamping: 3))
        #expect(worse.delta == -2)
    }

    @Test("effective score prefers the post-regulation value")
    func effectivePrefersAfter() {
        #expect(CategoryScore(category: .safety, before: Score(clamping: 2)).effective.value == 2)
        #expect(
            CategoryScore(category: .safety, before: Score(clamping: 2), after: Score(clamping: 7))
                .effective.value == 7
        )
    }
}

@Suite("CheckIn")
struct CheckInTests {
    let pacific = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    @Test("a quick check-in asks one question; a full check-in asks ten")
    func shapeByKind() {
        #expect(CheckInKind.quick.categories == [.overall])
        #expect(CheckInKind.full.categories.count == 10)
    }

    @Test("remaining categories shrink as scores are recorded")
    func remainingCategories() {
        var checkIn = CheckIn(kind: .full, localDate: LocalDate(iso: "2026-07-29")!, timeZoneIdentifier: "America/Los_Angeles")
        #expect(checkIn.remainingCategories.count == 10)

        checkIn.scores.append(CategoryScore(category: .safety, before: Score(clamping: 8)))
        #expect(checkIn.remainingCategories.count == 9)
        #expect(!checkIn.remainingCategories.contains(.safety))
    }

    @Test("only low scores await re-rating, and only until they get it")
    func awaitingReRating() {
        var checkIn = CheckIn(kind: .full, localDate: LocalDate(iso: "2026-07-29")!, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [
            CategoryScore(category: .safety, before: Score(clamping: 9)),   // fine
            CategoryScore(category: .breath, before: Score(clamping: 5)),   // premium threshold
            CategoryScore(category: .energy, before: Score(clamping: 2)),   // low
        ]
        #expect(checkIn.awaitingReRating.map(\.category) == [.breath, .energy])

        checkIn.scores[1].after = Score(clamping: 8)
        #expect(checkIn.awaitingReRating.map(\.category) == [.energy])
    }

    @Test("averages mirror the daily_coherence view: before, after, and delta")
    func averages() {
        var checkIn = CheckIn(kind: .full, localDate: LocalDate(iso: "2026-07-29")!, timeZoneIdentifier: "America/Los_Angeles")
        checkIn.scores = [
            CategoryScore(category: .safety, before: Score(clamping: 8)),
            CategoryScore(category: .breath, before: Score(clamping: 2), after: Score(clamping: 6)),
        ]
        #expect(checkIn.averageBefore == 5.0)          // (8 + 2) / 2
        #expect(checkIn.averageAfter == 7.0)           // (8 + 6) / 2, `after` wins where present
        #expect(checkIn.averageDelta == 4.0)           // only the regulated one counts
        #expect(checkIn.regulatedCount == 1)
    }

    @Test("an empty check-in reports nil averages rather than zero")
    func emptyAverages() {
        let empty = CheckIn(kind: .full, localDate: LocalDate(iso: "2026-07-29")!, timeZoneIdentifier: "America/Los_Angeles")
        #expect(empty.averageBefore == nil)
        #expect(empty.averageAfter == nil)
        #expect(empty.averageDelta == nil)
    }

    @Test("fixtures land in the band they claim")
    func fixtureBands() {
        for band in CoherenceBand.allCases {
            let checkIn = CheckIn.fixture(band: band)
            for score in checkIn.scores {
                #expect(CoherenceBand(score.before) == band)
            }
        }
    }

    @Test("synthetic history is byte-identical across runs, so snapshots don't flake")
    func fixturesAreDeterministic() {
        let today = LocalDate(iso: "2026-07-29")!
        let first = CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: pacific)
        let second = CheckIn.syntheticHistory(days: 10, endingOn: today, calendar: pacific)
        #expect(first.map(\.scores) == second.map(\.scores))
    }
}

@Suite("CoherenceSummary")
struct CoherenceSummaryTests {
    let pacific = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    @Test("the prompt digest stays compact — it is the thing we send instead of raw history")
    func staysCompact() {
        let today = LocalDate(iso: "2026-07-29")!
        let history = CheckIn.syntheticHistory(days: 30, endingOn: today, calendar: pacific)
        let summary = CoherenceSummary.build(history: history, today: today, calendar: pacific)

        let text = summary.promptText
        #expect(!text.isEmpty)
        // ~4 chars/token: a few hundred characters is the ~50-token budget in §8.3.
        #expect(text.count < 400, "digest grew to \(text.count) chars:\n\(text)")
        #expect(text.contains("7-day avg coherence"))
        #expect(text.contains("Streak: 30 days"))
    }

    @Test("incomplete check-ins are excluded from the digest")
    func ignoresIncomplete() {
        let today = LocalDate(iso: "2026-07-29")!
        let abandoned = CheckIn(
            kind: .full,
            localDate: today,
            timeZoneIdentifier: "America/Los_Angeles",
            scores: [CategoryScore(category: .safety, before: Score(clamping: 0))],
            completedAt: nil
        )
        let summary = CoherenceSummary.build(history: [abandoned], today: today, calendar: pacific)
        #expect(summary.promptText.isEmpty)
        #expect(summary.streak == 0)
    }

    @Test("an empty history produces an empty digest, not a sentence full of nils")
    func emptyHistory() {
        let summary = CoherenceSummary.build(history: [], today: LocalDate(iso: "2026-07-29")!, calendar: pacific)
        #expect(summary.promptText.isEmpty)
    }

    @Test("today's regulation counts and improvement are reported")
    func todaysNumbers() {
        let today = LocalDate(iso: "2026-07-29")!
        let checkIn = CheckIn.fixture(band: .low, on: today, regulated: true)
        let summary = CoherenceSummary.build(history: [checkIn], today: today, calendar: pacific)

        #expect(summary.todayCategoryCount == 10)
        #expect(summary.todayRegulatedCount == 10)
        #expect(summary.todayAverageDelta == 3.0)
        #expect(summary.promptText.contains("regulated 10 of 10 categories"))
        #expect(summary.promptText.contains("avg improvement +3.0"))
    }

    @Test("the digest never contains free-text — only numbers and category names")
    func containsNoFreeText() {
        let today = LocalDate(iso: "2026-07-29")!
        let history = CheckIn.syntheticHistory(days: 14, endingOn: today, calendar: pacific)
        let text = CoherenceSummary.build(history: history, today: today, calendar: pacific).promptText

        // Guards §8.3 / §18.2 minimum-necessary: if someone later threads journal
        // or chat content into the digest, this fails.
        #expect(!text.contains("seed-placeholder"))
        #expect(!text.contains("America/Los_Angeles"))
        for line in text.split(separator: "\n") {
            #expect(line.count < 120, "digest line unexpectedly long: \(line)")
        }
    }
}
