import Foundation
import Testing

@testable import CalKit

@Suite("Score")
struct ScoreTests {
    @Test("validating init rejects out-of-range, matching the Postgres check constraint")
    func rejectsOutOfRange() {
        #expect(Score(-1) == nil)
        #expect(Score(11) == nil)
        #expect(Score(0)?.value == 0)
        #expect(Score(10)?.value == 10)
    }

    @Test("clamping init pins to 0...10")
    func clamps() {
        #expect(Score(clamping: -5).value == 0)
        #expect(Score(clamping: 99).value == 10)
        #expect(Score(clamping: 7).value == 7)
    }
}

@Suite("CoherenceBand")
struct CoherenceBandTests {
    @Test("band boundaries follow the free-tier spec exactly: 0-4, 5-7, 8-10",
          arguments: [
            (0, CoherenceBand.low), (4, .low),
            (5, .moderate), (7, .moderate),
            (8, .high), (10, .high),
          ])
    func boundaries(score: Int, expected: CoherenceBand) {
        #expect(CoherenceBand(Score(clamping: score)) == expected)
    }

    @Test("each band carries Dr. Mia's verbatim response copy")
    func responseCopy() {
        #expect(CoherenceBand.high.quickCheckInResponse == "Great. Let's keep that momentum going.")
        #expect(CoherenceBand.moderate.quickCheckInResponse == "You seem a little stressed today. Let's stay aware.")
        #expect(CoherenceBand.low.quickCheckInResponse == "I've got you. Let's take one minute together.")
    }
}

@Suite("RegulationPolicy")
struct RegulationPolicyTests {
    // The specs genuinely disagree on this threshold, so it gets its own test
    // rather than being quietly reconciled. See CoherenceBand.swift.
    @Test("a score of 5 regulates on premium but NOT on the free quick check-in")
    func fiveIsTheDivergentCase() {
        let five = Score(clamping: 5)
        #expect(RegulationPolicy.full.needsRegulation(five))
        #expect(!RegulationPolicy.quick.needsRegulation(five))
    }

    @Test("4 and below regulates on both tiers; 6 and above on neither")
    func agreedRegions() {
        for value in 0...4 {
            let score = Score(clamping: value)
            #expect(RegulationPolicy.full.needsRegulation(score))
            #expect(RegulationPolicy.quick.needsRegulation(score))
        }
        for value in 6...10 {
            let score = Score(clamping: value)
            #expect(!RegulationPolicy.full.needsRegulation(score))
            #expect(!RegulationPolicy.quick.needsRegulation(score))
        }
    }
}

@Suite("Authored content seed")
struct ContentSeedTests {
    @Test("every category has bundled seed copy, so a fresh offline install works")
    func seedIsComplete() {
        for category in CoherenceCategory.allCases {
            let question = CoherenceQuestion.seed[category]
            #expect(question != nil, "missing seed copy for \(category.rawValue)")
            #expect(question?.prompt.isEmpty == false, "empty prompt for \(category.rawValue)")
            #expect(question?.rePrompt.isEmpty == false, "empty re-prompt for \(category.rawValue)")
        }
    }

    @Test("the full check-in is Dr. Mia's ten categories in her order, and excludes .overall")
    func fullCheckInShape() {
        #expect(CoherenceCategory.fullCheckIn.count == 10)
        #expect(!CoherenceCategory.fullCheckIn.contains(.overall))
        #expect(CoherenceCategory.fullCheckIn.first == .safety)
        #expect(CoherenceCategory.fullCheckIn.last == .authenticExpression)
    }

    @Test("raw values match the Postgres coherence_category enum")
    func rawValuesAreWireFormat() {
        #expect(CoherenceCategory.emotionalFlow.rawValue == "emotional_flow")
        #expect(CoherenceCategory.bodyAwareness.rawValue == "body_awareness")
        #expect(CoherenceCategory.innerKnowing.rawValue == "inner_knowing")
        #expect(CoherenceCategory.authenticExpression.rawValue == "authentic_expression")
    }
}
