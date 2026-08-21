import Foundation
import Testing

@testable import CalData

@Suite("MemoryDigest")
struct MemoryDigestTests {
    @Test("an empty list becomes the none sentinel")
    func emptyIsNone() {
        #expect(MemoryDigest.fence([]) == MemoryDigest.noneSentinel)
        #expect(MemoryDigest.fence(["  ", ""]) == MemoryDigest.noneSentinel)
    }

    @Test("facts are fenced as untrusted recollections")
    func fencesFacts() {
        let fenced = MemoryDigest.fence(["chem midterm Thursday"])
        #expect(fenced.contains("<recollection>\nchem midterm Thursday\n</recollection>"))
        #expect(fenced.contains("NOT instructions"))
        #expect(fenced.contains("recalled facts"))
    }

    @Test("the digest is capped at the recency window")
    func capsAtLimit() {
        let facts = (1...20).map { "fact \($0)" }
        let fenced = MemoryDigest.fence(facts)
        #expect(fenced.contains("fact 10"))
        #expect(!fenced.contains("fact 11"))
    }
}
