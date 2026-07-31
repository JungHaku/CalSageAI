import CalData
import CalKit
import Foundation
import Supabase
import Testing

@testable import CalRemote

/// Integration tests against the local Supabase stack.
///
/// These need `supabase start` running and are **skipped, not failed**, when it
/// isn't — a machine without Docker should still get a green `swift test`. The
/// fast loop stays fast: everything here is a few hundred milliseconds, and the
/// pure logic is covered by the other suites.
///
/// The seeded user comes from `supabase/seed.sql` and its password is a literal in
/// that file. Nothing here is a credential.
@Suite("Live stack", .serialized)
struct LiveStackTests {
    static let email = "cal.tester@example.com"
    static let password = "password123"

    /// Cheap reachability probe. `supabase start` publishes the REST endpoint on
    /// 54321; if nothing answers, there is no stack.
    static func stackIsUp() async -> Bool {
        var request = URLRequest(url: CalSupabase.localURL.appendingPathComponent("rest/v1/"))
        request.timeoutInterval = 2
        request.setValue(CalSupabase.localAnonKey, forHTTPHeaderField: "apikey")
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// A client whose session lives in memory and dies with the test.
    ///
    /// The SDK persists sessions to the Keychain by default, so a signed-in run
    /// leaves the *next* run already authenticated — which is precisely the
    /// "passes locally because the last run left something behind" failure. The
    /// first assertion of `signsIn` caught it. Every test here gets its own store.
    static func ephemeralClient() -> SupabaseClient {
        CalSupabase.makeClient(
            url: CalSupabase.localURL,
            anonKey: CalSupabase.localAnonKey,
            authStorage: InMemoryAuthStorage()
        )
    }

    private func signedInClient() async throws -> (SupabaseClient, UUID) {
        let client = Self.ephemeralClient()
        let session = try await client.auth.signIn(email: Self.email, password: Self.password)
        return (client, session.user.id)
    }

    // MARK: Auth

    @Test("the seeded user can sign in, and identity reports the account id")
    func signsIn() async throws {
        try await withStack {
            let client = Self.ephemeralClient()
            let identity = SupabaseIdentity(client: client, local: LocalIdentity(profiles: InMemoryProfileStore()))

            #expect(await identity.isAuthenticated == false, "no session before signing in")
            let id = try await identity.signIn(email: Self.email, password: Self.password)
            #expect(await identity.isAuthenticated)
            #expect(try await identity.currentProfileID() == id)

            try await identity.signOut()
            #expect(await identity.isAuthenticated == false)
        }
    }

    /// The property that lets the app keep working with no account: identity must
    /// still answer, falling back to the device-local id.
    @Test("identity falls back to the device-local id when nobody is signed in")
    func fallsBackToLocal() async throws {
        try await withStack {
            let profiles = InMemoryProfileStore()
            let local = LocalIdentity(profiles: profiles)
            let identity = SupabaseIdentity(client: Self.ephemeralClient(), local: local)

            let id = try await identity.currentProfileID()
            #expect(try await local.currentProfileID() == id, "must be the same device id, not a new one")
        }
    }

    // MARK: The timestamp round-trip

    /// The end-to-end proof of `PostgresCoding`. A check-in written at a known
    /// instant must come back as that instant — through the encoder, Postgres's
    /// `timestamptz`, and the decoder.
    @Test("a timestamp survives the full round trip to Postgres and back")
    func timestampRoundTrip() async throws {
        try await withStack {
            let (client, userID) = try await signedInClient()

            // Deliberately not a round number, and with sub-second detail: a
            // decoder that truncates or shifts shows up immediately.
            let completedAt = Date(timeIntervalSince1970: 1_785_012_345.678)
            let checkIn = CheckIn(
                kind: .full,
                localDate: LocalDate(iso: "2026-03-14")!,
                timeZoneIdentifier: "America/Los_Angeles",
                completedAt: completedAt
            )

            try await client.from("checkins")
                .upsert(CheckInRow(checkIn, userID: userID), onConflict: "id")
                .execute()

            let rows: [CheckInRow] = try await client.from("checkins")
                .select()
                .eq("id", value: checkIn.id.uuidString)
                .execute()
                .value
            let fetched = try #require(rows.first)

            let returned = try #require(fetched.completed_at)
            #expect(
                abs(returned.timeIntervalSince(completedAt)) < 0.001,
                "wrote \(completedAt), read back \(returned) — a \(returned.timeIntervalSince(completedAt))s shift"
            )
            #expect(fetched.local_date.value == LocalDate(iso: "2026-03-14"), "the calendar day moved")

            try await client.from("checkins").delete().eq("id", value: checkIn.id.uuidString).execute()
        }
    }

    /// Scores carry the generated columns `delta` and `regulated`. Writing them is
    /// an error from Postgres, so the row type omits them — this proves the write
    /// succeeds and that the server computed them for us.
    @Test("scores insert without their generated columns, and Postgres fills them in")
    func generatedColumnsAreServerComputed() async throws {
        try await withStack {
            let (client, userID) = try await signedInClient()

            let checkIn = CheckIn(
                kind: .full,
                localDate: LocalDate(iso: "2026-03-15")!,
                timeZoneIdentifier: "America/Los_Angeles",
                completedAt: Date()
            )
            try await client.from("checkins")
                .upsert(CheckInRow(checkIn, userID: userID), onConflict: "id")
                .execute()

            let score = CategoryScore(
                category: .breath,
                before: Score(clamping: 3),
                after: Score(clamping: 7),
                exerciseSlug: "embodied-vital-breathwork"
            )
            try await client.from("checkin_scores")
                .upsert(CheckInScoreRow(score, checkInID: checkIn.id, userID: userID), onConflict: "id")
                .execute()

            struct Computed: Decodable { let delta: Int?; let regulated: Bool }
            let computed: [Computed] = try await client.from("checkin_scores")
                .select("delta,regulated")
                .eq("checkin_id", value: checkIn.id.uuidString)
                .execute()
                .value

            #expect(computed.first?.delta == 4, "the server should compute 7 - 3")
            #expect(computed.first?.regulated == true)

            try await client.from("checkins").delete().eq("id", value: checkIn.id.uuidString).execute()
        }
    }

    /// A retried push must update rather than duplicate. Score rows have no id in
    /// the domain model, so the row type derives one from (check-in, category) —
    /// this is the test that the derivation actually makes the push idempotent.
    @Test("pushing the same score twice updates one row rather than creating two")
    func pushIsIdempotent() async throws {
        try await withStack {
            let (client, userID) = try await signedInClient()

            let checkIn = CheckIn(
                kind: .full,
                localDate: LocalDate(iso: "2026-03-16")!,
                timeZoneIdentifier: "America/Los_Angeles",
                completedAt: Date()
            )
            try await client.from("checkins")
                .upsert(CheckInRow(checkIn, userID: userID), onConflict: "id")
                .execute()

            let first = CategoryScore(category: .safety, before: Score(clamping: 4))
            let corrected = CategoryScore(
                category: .safety, before: Score(clamping: 4), after: Score(clamping: 8)
            )
            for score in [first, corrected] {
                try await client.from("checkin_scores")
                    .upsert(CheckInScoreRow(score, checkInID: checkIn.id, userID: userID), onConflict: "id")
                    .execute()
            }

            let rows: [CheckInScoreRow] = try await client.from("checkin_scores")
                .select()
                .eq("checkin_id", value: checkIn.id.uuidString)
                .execute()
                .value

            #expect(rows.count == 1, "a retried push duplicated the row")
            #expect(rows.first?.score_after == 8, "the retry should have won")

            try await client.from("checkins").delete().eq("id", value: checkIn.id.uuidString).execute()
        }
    }

    // MARK: Harness

    /// Skips rather than fails when there is no stack, so `swift test` is green on
    /// a machine without Docker.
    private func withStack(_ body: () async throws -> Void) async throws {
        guard await Self.stackIsUp() else {
            withKnownIssue("local Supabase stack is not running — `supabase start`", isIntermittent: true) {
                Issue.record("skipped")
            }
            return
        }
        try await body()
    }
}


/// Session storage that does not outlive the process.
///
/// `AuthLocalStorage` is three methods; the default implementation is the
/// Keychain, which is right for the app and wrong for a test suite.
final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.withLock { storage[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { storage[key] }
    }

    func remove(key: String) throws {
        lock.withLock { storage[key] = nil }
    }
}
