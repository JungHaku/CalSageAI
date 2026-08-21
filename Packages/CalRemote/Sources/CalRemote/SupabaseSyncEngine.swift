import CalData
import CalKit
import Foundation
import Supabase

/// `SyncEngine` against Supabase (ARCHITECTURE.md §15 step 5).
///
/// Replaces `NoOpSyncEngine` behind the same protocol, so no caller changes.
///
/// ## What it does, and the order matters
///
/// **Push, then pull.** The other order loses data: pulling first can overwrite a
/// local row that has not been pushed yet, and the local row is the one the
/// person actually wrote.
///
/// ## The claim migration (§15 step 4) needs no code
///
/// The first sync after signing in *is* the migration. Every local row is still
/// `isDirty` — nothing ever cleared it, which §2 called out as exactly what a
/// device that has never synced needs — so the first push sends the person's
/// whole history under the new `user_id`. There is no id remapping because the
/// UUIDs already match on both sides.
///
/// ## Conflict rules
///
/// From §15 step 5, and each is a decision rather than a default:
///
/// - **Check-ins and scores are append-mostly**, so conflicts are structurally
///   rare. Last-write-wins on `updatedAt`, with one exception below.
/// - **A dirty local row always wins.** An unpushed local edit is newer than
///   anything the server can know about. `SwiftDataCoherenceStore.merge` enforces
///   this, not this type — the store owns its own consistency.
/// - **Scores are replaced wholesale** with their check-in, matching what `save`
///   does locally. `CheckInScoreRow.deterministicID` makes that idempotent: the
///   same (check-in, category) always produces the same row id, so a retry
///   updates instead of duplicating.
///
/// ## What it deliberately does not do
///
/// No journal. There is no local journal store yet, and §15's rule — *never
/// silently overwrite an unsynced local body* — deserves to be implemented
/// against a real store rather than guessed at now.
public actor SupabaseSyncEngine: SyncEngine {
    private let client: SupabaseClient
    private let store: SwiftDataCoherenceStore
    /// The signed-in session, or `nil` — which is not an error, it is the
    /// ordinary state of an app that works without accounts.
    ///
    /// `AuthSession` rather than a bare user id, because the id alone is not
    /// enough: this client needs the *token* too. That was a real bug — a fresh
    /// `SupabaseClient` carries no session, so every request went out with only
    /// the anon key, RLS correctly refused it, and the push silently pushed
    /// nothing. Nothing in the UI could have shown that; only the empty table did.
    private let auth: AuthSession

    /// How many rows one sync will push. A first sync after months of use could
    /// otherwise be one enormous request that times out and never succeeds,
    /// leaving the person permanently unsynced. Bounded work retries cleanly.
    private static let batchSize = 500

    public init(client: SupabaseClient, store: SwiftDataCoherenceStore, auth: AuthSession) {
        self.client = client
        self.store = store
        self.auth = auth
    }

    /// Hands this client the signed-in session, refreshing the token first if it
    /// has expired. Returns the user id, or `nil` when nobody is signed in.
    ///
    /// Done per sync rather than once at construction: tokens last an hour, and a
    /// client holding a stale one fails in the way `AuthSession.accessToken`'s
    /// own comment describes — indistinguishable from having no token at all.
    private func adoptSession() async -> UUID? {
        guard let credentials = await auth.credentials(),
              let token = await auth.accessToken()
        else { return nil }
        _ = try? await client.auth.setSession(
            accessToken: token, refreshToken: credentials.refreshToken
        )
        return credentials.userID
    }

    public func pendingCount() async throws -> Int {
        try await store.pendingSyncCount()
    }

    @discardableResult
    public func sync() async throws -> SyncOutcome {
        // Not signed in is `notConfigured`, not a failure. There is nowhere to
        // sync *to*, and the settings screen should say so plainly rather than
        // showing an error the person cannot act on.
        guard let userID = await adoptSession() else { return .notConfigured }

        do {
            let pushed = try await push(userID: userID)
            let pulled = try await pull(userID: userID)
            return .synced(pushed: pushed, pulled: pulled)
        } catch let error as URLError {
            // Offline is an ordinary state for a phone, not an error worth
            // surfacing. Everything stays dirty and the next attempt retries it.
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return .offline
            default:
                throw error
            }
        }
    }

    // MARK: Push

    private func push(userID: UUID) async throws -> Int {
        let pending = try await store.pendingCheckIns(limit: Self.batchSize)
        guard !pending.isEmpty else { return 0 }

        var acknowledged: [UUID: Date] = [:]

        for item in pending {
            if item.isDeleted {
                // Tombstone, not a hard delete. The row has to keep existing so
                // another device learns it was removed; deleting it outright
                // would let it come back on that device's next push.
                try await client.from("checkins")
                    .update(["deleted_at": item.deletedAt])
                    .eq("id", value: item.id.uuidString)
                    .execute()
                acknowledged[item.id] = item.updatedAt
                continue
            }

            guard let checkIn = item.checkIn else { continue }

            try await client.from("checkins")
                .upsert(CheckInRow(checkIn, userID: userID), onConflict: "id")
                .execute()

            if !checkIn.scores.isEmpty {
                let rows = checkIn.scores.map {
                    CheckInScoreRow($0, checkInID: checkIn.id, userID: userID)
                }
                try await client.from("checkin_scores")
                    .upsert(rows, onConflict: "id")
                    .execute()
            }

            acknowledged[item.id] = item.updatedAt
        }

        // Marked clean only after the server accepted them. A throw above leaves
        // everything dirty, which is the state a retry needs.
        try await store.markSynced(acknowledged)
        return acknowledged.count
    }

    // MARK: Pull

    private func pull(userID: UUID) async throws -> Int {
        // RLS already restricts every row to the caller, so `.eq("user_id", ...)`
        // is redundant as *security*. It is here as intent: a policy change should
        // not silently widen what this reads.
        let rows: [CheckInRow] = try await client.from("checkins")
            .select()
            .eq("user_id", value: userID.uuidString)
            .is("deleted_at", value: nil)
            .limit(Self.batchSize)
            .execute()
            .value
        guard !rows.isEmpty else { return 0 }

        let scoreRows: [CheckInScoreRow] = try await client.from("checkin_scores")
            .select()
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value

        var scoresByCheckIn: [UUID: [CategoryScore]] = [:]
        for row in scoreRows {
            guard let score = try? row.toDomain() else { continue }
            scoresByCheckIn[row.checkin_id, default: []].append(score)
        }

        var checkIns: [CheckIn] = []
        var stamps: [UUID: Date] = [:]
        for row in rows {
            guard let checkIn = try? row.toDomain(scores: scoresByCheckIn[row.id] ?? []) else {
                // One undecodable row must not fail the whole pull. It stays on
                // the server and the rest of the person's history still arrives.
                continue
            }
            checkIns.append(checkIn)
            // `completed_at` is the best timestamp these rows carry — `updated_at`
            // is not in `CheckInRow`, deliberately, because pushing it would let a
            // client overwrite the server's own bookkeeping. The store treats a
            // missing stamp conservatively and keeps whatever is local.
            stamps[row.id] = row.completed_at ?? .distantPast
        }

        return try await store.merge(checkIns, updatedAt: stamps)
    }
}
