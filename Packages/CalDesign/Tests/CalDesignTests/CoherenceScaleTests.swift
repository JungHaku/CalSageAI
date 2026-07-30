import CalKit
import Testing

@testable import CalDesign

@Suite("CoherenceScale")
struct CoherenceScaleTests {
    @Test("every band has a distinct tint, so the scale is readable at a glance")
    func tintsAreDistinct() {
        let tints = CoherenceBand.allCases.map(CoherenceScale.tint(for:))
        #expect(Set(tints.map(String.init(describing:))).count == CoherenceBand.allCases.count)
    }

    @Test("score-based tint agrees with band-based tint at the boundaries")
    func scoreAndBandAgree() {
        for value in Score.validRange {
            let score = Score(clamping: value)
            #expect(
                String(describing: CoherenceScale.tint(for: score))
                    == String(describing: CoherenceScale.tint(for: CoherenceBand(score)))
            )
        }
    }
}
