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

    /// Both flows are Dr. Mia's domain types; the paid tier no longer gates a
    /// check-in, because the app no longer has one.
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

    /// The free tier is not a demo. Emergency help and the student's own journal
    /// stay reachable without paying.
    @Test("the free tier still reaches emergency help and export")
    func freeTierIsUsableOnItsOwn() {
        #expect(PremiumFeature.neverGated.contains("emergency-help"))
        #expect(PremiumFeature.neverGated.contains("data-export"))
    }

    /// Encodes the boundary rather than trusting it: the paid tier gates the
    /// surfaces that are built, and this test names them so that widening the
    /// paywall is a visible, deliberate edit rather than a quiet one.
    @Test("the paywall covers exactly the surfaces that are built")
    func gatedSurfacesAreTheBuiltOnes() {
        #expect(
            Set(PremiumFeature.allCases) == [.practiceLibrary],
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
