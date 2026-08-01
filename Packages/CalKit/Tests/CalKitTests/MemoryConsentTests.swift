import Foundation
import Testing

@testable import CalKit

@Suite("Memory consent")
struct MemoryConsentTests {

    /// The default that matters. MHMDA requires opt-in, and an opt-in that
    /// starts on is an opt-out wearing a different hat.
    @Test("consent starts not granted")
    func defaultsToNo() {
        #expect(MemoryConsent.notGranted.isGranted == false)
        #expect(MemoryConsent.notGranted.permitsRemoteMemory == false)
    }

    @Test("granting records when, and against which disclosure")
    func grantingRecordsProvenance() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let consent = MemoryConsent.granted(at: now)

        #expect(consent.permitsRemoteMemory)
        #expect(consent.grantedAt == now)
        #expect(consent.version == MemoryConsent.currentVersion)
    }

    /// Consent to old wording is not consent to new wording. Cheaper to ask
    /// again than to argue later that someone agreed to something they were
    /// never shown.
    @Test("consent against a superseded disclosure does not carry over")
    func staleVersionIsNotConsent() {
        let stale = MemoryConsent(
            isGranted: true, grantedAt: Date(timeIntervalSince1970: 0), version: "memory-v0"
        )
        #expect(stale.isGranted)
        #expect(!stale.permitsRemoteMemory, "a superseded disclosure must force the question again")
    }

    @Test("consent survives a round trip through storage")
    func codableRoundTrip() throws {
        let consent = MemoryConsent.granted(at: Date(timeIntervalSince1970: 1_785_000_000))
        let data = try JSONEncoder().encode(consent)
        #expect(try JSONDecoder().decode(MemoryConsent.self, from: data) == consent)
    }

    /// The disclosure has to be refusable to be a real question, and it has to
    /// name what actually happens rather than gesture at it.
    @Test("the disclosure says what leaves the device and that declining is fine")
    func copyIsHonest() {
        let body = MemoryConsentCopy.body.lowercased()
        #expect(body.contains("works without this"))
        #expect(body.contains("sent to our server"))
        #expect(body.contains("delete"))
        #expect(MemoryConsentCopy.sharingNote.lowercased().contains("do not sell"))
        #expect(!MemoryConsentCopy.declineTitle.isEmpty, "declining needs its own words")
    }
}
