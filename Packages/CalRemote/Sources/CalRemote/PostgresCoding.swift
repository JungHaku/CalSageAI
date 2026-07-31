import CalKit
import Foundation

/// JSON coders that read and write what Postgres actually sends.
///
/// ## The bug this exists to prevent
///
/// supabase-swift's default decoder **silently discards the UTC offset on every
/// timestamp it parses**. `Sources/Helpers/DateFormatter.swift` builds its format
/// style without a `.timeZone()` component, so `Date.ISO8601FormatStyle` falls
/// back to GMT and any trailing offset is thrown away:
///
///     "2026-07-30T12:00:00.000Z"      -> 12:00Z   correct
///     "2026-07-30T12:00:00.000+05:00" -> 12:00Z   WRONG, should be 07:00Z
///     "2026-07-30T12:00:00.000-07:00" -> 12:00Z   WRONG, should be 19:00Z
///
/// It is benign against a stock Supabase, which always emits `Z` — which is
/// exactly what makes it dangerous. It stays invisible until something writes a
/// timestamp with a real offset: a psql session, a migration, a webhook, a second
/// service. Then check-ins land hours away from when they happened, and the
/// analytics that read them are quietly wrong with no error anywhere.
///
/// Seven hours of skew in an app whose whole claim is "look how you changed
/// between 8am and 8:04am" is not a rounding error, so the coders are replaced
/// rather than trusted.
public enum PostgresCoding {

    /// Decodes ISO-8601 with a genuine offset, with or without fractional seconds.
    ///
    /// Both are needed: `timestamptz` comes back with microseconds
    /// (`...T08:00:00.123456+00:00`) while a value stored without them comes back
    /// bare (`...T08:00:00+00:00`). A decoder that handles only one shape fails on
    /// perfectly ordinary rows.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseTimestamp(text) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "not an ISO-8601 timestamp: \(text)"
                    )
                )
            }
            return date
        }
        return decoder
    }

    /// Always emits UTC with fractional seconds, which Postgres accepts for
    /// `timestamptz` and stores unambiguously.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampFormatter().string(from: date))
        }
        return encoder
    }

    // MARK: Timestamps

    /// Built per call rather than cached in a `static let`: `ISO8601DateFormatter`
    /// is not `Sendable`, and the same shortcut was already corrected once in
    /// `ExportArchive`.
    static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // MARK: Dates

    /// A Postgres `date` is a calendar day with no instant and no zone, which is
    /// exactly `LocalDate`. Mapping it through `Date` would reintroduce the
    /// timezone question that `LocalDate` exists to avoid — and would put the
    /// check-in on the wrong day for anyone west of UTC.
    static func localDate(from text: String) -> LocalDate? {
        LocalDate(iso: String(text.prefix(10)))
    }
}

/// A `LocalDate` on the wire, as the `YYYY-MM-DD` string Postgres uses.
///
/// `LocalDate`'s own `Codable` conformance is a struct of three integers, which is
/// right for the export archive and wrong for a `date` column. Rather than change
/// a type the whole app depends on, the wire form is expressed here.
struct PostgresDate: Codable, Hashable, Sendable {
    let value: LocalDate

    init(_ value: LocalDate) { self.value = value }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = PostgresCoding.localDate(from: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)")
            )
        }
        self.value = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.iso)
    }
}
