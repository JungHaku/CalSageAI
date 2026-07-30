import Foundation

/// A 0–10 coherence rating.
///
/// Mirrors the `check (score_before between 0 and 10)` constraint in Postgres
/// (ARCHITECTURE.md §5.2). Making the range a type rather than a convention
/// means an out-of-range score can't reach the database — or the analytics that
/// average it.
public struct Score: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let validRange = 0...10

    public let value: Int

    /// Fails for out-of-range input. Use this at trust boundaries: decoding a
    /// server payload, parsing a deep link.
    public init?(_ value: Int) {
        guard Self.validRange.contains(value) else { return nil }
        self.value = value
    }

    /// Clamps into range. Use this for UI input, where a slider can't
    /// meaningfully produce an invalid value and refusing one would just be a
    /// dead control.
    public init(clamping value: Int) {
        self.value = min(Self.validRange.upperBound, max(Self.validRange.lowerBound, value))
    }

    public var description: String { String(value) }

    public static func < (lhs: Score, rhs: Score) -> Bool { lhs.value < rhs.value }
}
