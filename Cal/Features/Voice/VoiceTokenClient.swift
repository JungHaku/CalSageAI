import Foundation

/// Fetches short-lived ElevenLabs credentials from our Edge Function.
///
/// The phone never sees the ElevenLabs API key (`PLAN-voice-implementation.md`
/// §2–3, ARCHITECTURE.md §8.1).
///
/// The function returns a WebRTC `token`. That JWT's metadata also embeds a
/// `signed_url` for the text WebSocket — which is what the Simulator uses,
/// because LiveKit WebRTC times out there. Prefer an explicit `signed_url`
/// field when present (newer function), otherwise peel it out of the JWT.
struct VoiceTokenClient: Sendable {
    struct Credentials: Equatable, Sendable {
        let token: String
        let signedURL: String
    }

    enum Failure: Error, Equatable {
        case unconfigured
        case unavailable
        case offline
        case authenticationFailed
    }

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func fetchCredentials() async throws -> Credentials {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.unavailable
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw Failure.authenticationFailed
        case 503:
            throw Failure.unconfigured
        default:
            throw Failure.unavailable
        }

        struct Body: Decodable {
            let token: String?
            let signed_url: String?
            let error: String?
        }

        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let token = body.token, !token.isEmpty else {
            if body.error == "voice_unconfigured" { throw Failure.unconfigured }
            throw Failure.unavailable
        }

        if let signed = body.signed_url, !signed.isEmpty {
            return Credentials(token: token, signedURL: signed)
        }
        guard let signed = Self.signedURL(embeddedIn: token) else {
            throw Failure.unavailable
        }
        return Credentials(token: token, signedURL: signed)
    }

    /// Conversation tokens carry `metadata.signed_url` — enough for the
    /// Simulator text-only path without a second Edge Function mint.
    static func signedURL(embeddedIn token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let metadata: [String: Any]?
        if let dict = json["metadata"] as? [String: Any] {
            metadata = dict
        } else if let raw = json["metadata"] as? String,
                  let metaData = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            metadata = dict
        } else {
            metadata = nil
        }

        guard let url = metadata?["signed_url"] as? String, !url.isEmpty else { return nil }
        return url
    }
}
