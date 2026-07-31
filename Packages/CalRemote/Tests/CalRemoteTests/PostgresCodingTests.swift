import CalKit
import Foundation
import Testing

@testable import CalRemote

@Suite("Postgres coding")
struct PostgresCodingTests {

    private struct Wrapper: Codable, Equatable {
        let at: Date
    }

    private func decode(_ text: String) throws -> Date {
        let json = Data(#"{"at":"\#(text)"}"#.utf8)
        return try PostgresCoding.makeDecoder().decode(Wrapper.self, from: json).at
    }

    /// The bug this whole file exists for.
    ///
    /// supabase-swift's stock decoder drops the offset and reads every one of
    /// these as 12:00Z. That is invisible against a stock Supabase — which always
    /// emits `Z` — and silently wrong the moment anything else writes a timestamp:
    /// a psql session, a migration, a webhook. These four cases are exactly the
    /// ones it gets wrong.
    @Test(
        "an offset is honoured, not discarded",
        arguments: [
            ("2026-07-30T12:00:00.000Z", "2026-07-30T12:00:00Z"),
            ("2026-07-30T12:00:00.000+00:00", "2026-07-30T12:00:00Z"),
            ("2026-07-30T12:00:00.000+05:00", "2026-07-30T07:00:00Z"),
            ("2026-07-30T12:00:00.000-07:00", "2026-07-30T19:00:00Z"),
        ]
    )
    func offsetsAreHonoured(input: String, expectedUTC: String) throws {
        let decoded = try decode(input)
        let expected = try #require(PostgresCoding.parseTimestamp(expectedUTC))
        #expect(
            abs(decoded.timeIntervalSince(expected)) < 0.001,
            "\(input) decoded to \(decoded), expected \(expected)"
        )
    }

    /// Both shapes come off the wire from the same column: `timestamptz` carries
    /// microseconds when it has them and none when it doesn't. A decoder that
    /// handles one and not the other fails on ordinary rows.
    @Test("timestamps decode with and without fractional seconds")
    func fractionalSecondsOptional() throws {
        let withFraction = try decode("2026-07-30T08:00:00.123456+00:00")
        let without = try decode("2026-07-30T08:00:00+00:00")
        #expect(abs(withFraction.timeIntervalSince(without) - 0.123456) < 0.001)
    }

    @Test("a malformed timestamp throws rather than silently becoming a wrong date")
    func malformedThrows() {
        #expect(throws: (any Error).self) { try decode("not a timestamp") }
        // The failure mode that matters: a bare date must not quietly decode as
        // midnight UTC, because that is a real instant seven hours off in Berkeley.
        #expect(throws: (any Error).self) { try decode("2026-07-30") }
    }

    @Test("dates round-trip through the encoder we actually install")
    func encoderRoundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_785_000_000.5)
        let data = try PostgresCoding.makeEncoder().encode(Wrapper(at: original))
        let decoded = try PostgresCoding.makeDecoder().decode(Wrapper.self, from: data)
        #expect(abs(decoded.at.timeIntervalSince(original)) < 0.001)
    }

    // MARK: Calendar days

    /// A Postgres `date` has no instant and no zone, which is precisely
    /// `LocalDate`. Routing it through `Date` would reintroduce the timezone
    /// question `LocalDate` exists to remove — and would file a late-evening
    /// check-in in Berkeley under the following day.
    @Test("a date column decodes to the calendar day, with no timezone applied")
    func localDateIsZoneless() throws {
        let json = Data(#"{"value":"2026-07-30"}"#.utf8)
        struct Row: Codable { let value: PostgresDate }
        let decoded = try PostgresCoding.makeDecoder().decode(Row.self, from: json)
        #expect(decoded.value.value == LocalDate(iso: "2026-07-30"))
    }

    @Test("a date encodes back as YYYY-MM-DD, which is what the column accepts")
    func localDateEncodes() throws {
        struct Row: Codable { let value: PostgresDate }
        let day = try #require(LocalDate(iso: "2026-01-05"))
        let data = try PostgresCoding.makeEncoder().encode(Row(value: PostgresDate(day)))
        #expect(String(decoding: data, as: UTF8.self).contains("2026-01-05"))
    }

    /// Postgres sometimes returns a `date` with a time appended depending on the
    /// client and column type; taking the first ten characters is deliberate.
    @Test("a timestamp arriving in a date column still yields the right day")
    func dateToleratesATimestamp() {
        #expect(PostgresCoding.localDate(from: "2026-07-30T00:00:00Z") == LocalDate(iso: "2026-07-30"))
    }
}
