import Foundation
import Testing

@testable import CalKit

@Suite("Entitlement")
struct EntitlementTests {

    @Test("free unlocks no premium feature", arguments: PremiumFeature.allCases)
    func freeUnlocksNothing(feature: PremiumFeature) {
        #expect(!Entitlement.free.unlocks(feature))
    }

    @Test("plus unlocks every premium feature", arguments: PremiumFeature.allCases)
    func plusUnlocksEverything(feature: PremiumFeature) {
        #expect(Entitlement.plus.unlocks(feature))
    }

    /// Both flows are Dr. Mia's, and they differ in more than length — the free
    /// one regulates at 0–4, the premium one at 5 or below (`CoherenceBand`).
    @Test("the tier picks the check-in flow, and each flow keeps its own threshold")
    func checkInKindPerTier() {
        #expect(Entitlement.free.checkInKind == .quick)
        #expect(Entitlement.plus.checkInKind == .full)

        #expect(Entitlement.free.checkInKind.categories == [.overall])
        #expect(Entitlement.plus.checkInKind.categories.count == 10)

        #expect(Entitlement.free.checkInKind.regulationPolicy.triggersAtOrBelow == 4)
        #expect(Entitlement.plus.checkInKind.regulationPolicy.triggersAtOrBelow == 5)
    }

    /// Not an arbitrary default. Anything that can't establish a paid entitlement —
    /// a fresh install, a lapsed subscription, a StoreKit query that threw — has to
    /// land somewhere, and the only honest place is the tier the person has
    /// definitely paid for.
    @Test("the default entitlement is free")
    func defaultsToFree() {
        #expect(Entitlement.default == .free)
    }

    // MARK: The standing constraint

    /// The guard on `neverGated`. If someone later adds `case emergencyHelp` or
    /// `case checkInRegulation` to `PremiumFeature`, this fails and they have to
    /// come read the reasoning before overriding it.
    @Test("nothing in the never-gated set has been turned into a premium feature")
    func neverGatedStaysUngated() {
        let gated = Set(PremiumFeature.allCases.map(\.rawValue))
        let overlap = gated.intersection(PremiumFeature.neverGated)
        #expect(overlap.isEmpty, "these became paid features: \(overlap.sorted())")
    }

    /// The free tier is not a demo. Dr. Mia's stated goal for it is that a student
    /// who thinks "I need help" opens Cal — which only works if the free tier can
    /// actually complete a check-in and reach a regulation exercise.
    @Test("the free tier can still complete a check-in and be guided through regulation")
    func freeTierIsUsableOnItsOwn() {
        let kind = Entitlement.free.checkInKind
        #expect(!kind.categories.isEmpty, "free must be able to check in at all")

        // The distress path: a low score routes into guided breathing, unpaid.
        let policy = kind.regulationPolicy
        #expect(policy.needsRegulation(Score(clamping: 0)))
        #expect(policy.needsRegulation(Score(clamping: 3)))
    }

    /// Encodes the boundary rather than trusting it: the paid tier gates three
    /// things, and this test names them so that widening the paywall is a visible,
    /// deliberate edit rather than a quiet one.
    @Test("the paywall covers exactly the three surfaces that are built")
    func gatedSurfacesAreTheBuiltOnes() {
        #expect(
            Set(PremiumFeature.allCases) == [.fullCheckIn, .coherenceAnalytics, .practiceLibrary],
            """
            The gated set changed. If a feature was added, confirm it is actually \
            built and working — SPEC-premium.md promises several that are not.
            """
        )
    }

    @Test("entitlement round-trips through Codable so it can be cached")
    func codable() throws {
        for entitlement in Entitlement.allCases {
            let data = try JSONEncoder().encode(entitlement)
            #expect(try JSONDecoder().decode(Entitlement.self, from: data) == entitlement)
        }
    }
}
