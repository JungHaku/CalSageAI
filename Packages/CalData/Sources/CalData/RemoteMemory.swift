import CalKit
import Foundation

/// Server half of personal memory: consent row + forget RPC.
///
/// The memories table is not client-writable. Consent lives in `consents` (the
/// student may write their own row). Forgetting goes through `forget_memories()`,
/// which deletes only `auth.uid()`'s rows.
public protocol RemoteMemoryControlling: Sendable {
    /// Writes or removes the current-version memory consent. No-op when nobody
    /// is signed in — local `MemoryConsent` still records the choice.
    func persistConsent(granted: Bool) async throws
    /// Erases standing facts for the signed-in user. No-op when signed out.
    func forgetAll() async throws
    /// Recent standing facts, newest first. Empty on any failure — voice and
    /// chat must still run.
    func digest() async -> [String]
    /// Store a voice (or other) turn. Fire-and-forget from the caller; failures
    /// are swallowed here so speech is never blocked.
    func remember(text: String, severity: String) async
}

public struct NoOpRemoteMemory: RemoteMemoryControlling {
    public init() {}
    public func persistConsent(granted: Bool) async throws {}
    public func forgetAll() async throws {}
    public func digest() async -> [String] { [] }
    public func remember(text: String, severity: String) async {}
}

/// PostgREST client. Uses the same stack URL as `AuthSession`.
public struct RestMemoryClient: RemoteMemoryControlling, Sendable {
    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let auth: AuthSession
    private let memoryFunctionURL: URL

    public init(
        baseURL: URL,
        anonKey: String,
        auth: AuthSession,
        session: URLSession? = nil,
        memoryFunctionURL: URL? = nil
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.auth = auth
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.memoryFunctionURL = memoryFunctionURL
            ?? baseURL.appendingPathComponent("functions/v1/memory")
    }

    public func persistConsent(granted: Bool) async throws {
        guard let token = await auth.accessToken(),
              let userID = await auth.credentials()?.userID
        else { return }

        if granted {
            try await upsertConsent(userID: userID, token: token)
        } else {
            try await deleteConsent(token: token)
            try await rpcForget(token: token)
        }
    }

    public func forgetAll() async throws {
        guard let token = await auth.accessToken() else { return }
        try await rpcForget(token: token)
    }

    public func digest() async -> [String] {
        guard let token = await auth.accessToken() else { return [] }
        var request = restRequest(
            path: "/rest/v1/memories?select=text&order=created_at.desc&limit=\(MemoryDigest.digestLimit)",
            token: token
        )
        request.httpMethod = "GET"
        do {
            let data = try await sendReturning(request)
            let rows = try JSONDecoder().decode([MemoryRow].self, from: data)
            return rows.map(\.text)
        } catch {
            return []
        }
    }

    public func remember(text: String, severity: String) async {
        guard let token = await auth.accessToken() else { return }
        var request = URLRequest(url: memoryFunctionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RememberBody(text: text, severity: severity))
        _ = try? await sendReturning(request)
    }

    private func upsertConsent(userID: UUID, token: String) async throws {
        var request = restRequest(
            path: "/rest/v1/consents?on_conflict=user_id,doc_type,doc_version",
            token: token
        )
        request.httpMethod = "POST"
        request.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(
            ConsentBody(
                user_id: userID.uuidString,
                doc_type: MemoryConsent.remoteDocType,
                doc_version: MemoryConsent.currentVersion
            )
        )
        try await send(request)
    }

    private func deleteConsent(token: String) async throws {
        var request = restRequest(
            path: "/rest/v1/consents?doc_type=eq.\(MemoryConsent.remoteDocType)",
            token: token
        )
        request.httpMethod = "DELETE"
        try await send(request)
    }

    private func rpcForget(token: String) async throws {
        var request = restRequest(path: "/rest/v1/rpc/forget_memories", token: token)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        try await send(request)
    }

    private func restRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: restURL(path))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func restURL(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
            ?? baseURL
    }

    private func send(_ request: URLRequest) async throws {
        _ = try await sendReturning(request)
    }

    @discardableResult
    private func sendReturning(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw AuthError.rejected(status, "")
        }
        return data
    }

    private struct ConsentBody: Encodable {
        let user_id: String
        let doc_type: String
        let doc_version: String
    }

    private struct MemoryRow: Decodable {
        let text: String
    }

    private struct RememberBody: Encodable {
        let text: String
        let severity: String
    }
}
