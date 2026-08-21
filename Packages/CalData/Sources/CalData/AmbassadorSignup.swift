import Foundation

/// Interest list for the ambassador program. One row per signed-in account.
public protocol AmbassadorSigning: Sendable {
    /// The email already on file, if any.
    func currentEmail() async -> String?
    /// Upserts this account's signup. `email` is trimmed and lowercased.
    func submit(email: String) async throws
}

public struct NoOpAmbassadorSignup: AmbassadorSigning {
    public init() {}
    public func currentEmail() async -> String? { nil }
    public func submit(email: String) async throws {}
}

public enum AmbassadorSignupError: Error, Equatable, Sendable {
    case invalidEmail
    case unsigned
    case rejected(Int)
}

/// PostgREST client. Same stack URL as `AuthSession`.
public struct RestAmbassadorSignup: AmbassadorSigning, Sendable {
    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let auth: AuthSession

    public init(
        baseURL: URL,
        anonKey: String,
        auth: AuthSession,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.auth = auth
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func currentEmail() async -> String? {
        guard let token = await auth.accessToken() else { return nil }
        var request = restRequest(
            path: "/rest/v1/ambassador_signups?select=email&limit=1",
            token: token
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let data = try await sendReturning(request)
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return rows.first?.email
        } catch {
            return nil
        }
    }

    public func submit(email: String) async throws {
        let normalized = Self.normalize(email)
        guard Self.isValid(normalized) else { throw AmbassadorSignupError.invalidEmail }
        guard let token = await auth.accessToken(),
              let userID = await auth.credentials()?.userID
        else { throw AmbassadorSignupError.unsigned }

        var request = restRequest(
            path: "/rest/v1/ambassador_signups?on_conflict=user_id",
            token: token
        )
        request.httpMethod = "POST"
        request.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(
            Body(user_id: userID.uuidString, email: normalized)
        )
        try await send(request)
    }

    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ email: String) -> Bool {
        guard (3...254).contains(email.count) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0].contains(where: { $0 != "." }) && parts[1].contains(".")
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
            throw AmbassadorSignupError.rejected(status)
        }
        return data
    }

    private struct Body: Encodable {
        let user_id: String
        let email: String
    }

    private struct Row: Decodable {
        let email: String
    }
}
