import CalKit
import Foundation

/// Talks to our Edge Function. Never to a provider directly — there is no API key
/// in this binary, and that is the whole reason the function exists (§8.1).
///
/// Emits the same `CoachEvent` stream as `MockCoachClient`, so the chat screen
/// cannot tell them apart and neither can its tests.
public struct LiveCoachClient: CoachClient {
    private let endpoint: URL
    private let anonKey: String?
    private let session: URLSession
    private let detector = CrisisDetector()

    public init(endpoint: URL, anonKey: String? = nil, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.anonKey = anonKey
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            // `timeoutIntervalForRequest` is the gap between *bytes*, not the
            // whole call — which is what a stream needs. The resource timeout is
            // the ceiling on the entire reply.
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            return URLSession(configuration: configuration)
        }()
    }

    /// The local development function, served by
    /// `supabase functions serve --env-file supabase/functions/.env`.
    public static func local() -> LiveCoachClient {
        LiveCoachClient(endpoint: URL(string: "http://127.0.0.1:54321/functions/v1/coach")!)
    }

    public func send(_ request: CoachRequest) -> AsyncThrowingStream<CoachEvent, Error> {
        AsyncThrowingStream { continuation in
            // The prefilter runs FIRST, on-device, before a byte leaves the phone.
            // That ordering is the point: it costs nothing, needs no network, and
            // works in the exact situation — no signal, 2am — where a server-side
            // classifier is useless. An acute assessment never reaches the model.
            let assessment = detector.evaluate(request.message)
            if assessment.severity == .acute {
                continuation.yield(.crisis(.acute))
                continuation.yield(.finished(Self.unbilled))
                continuation.finish()
                return
            }

            let task = Task {
                do {
                    try await stream(request, into: continuation, assessment: assessment)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Leaving the chat screen cancels the Task, which must cancel the HTTP
            // request too — otherwise the model keeps generating, and keeps
            // billing, for text nobody will read.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ request: CoachRequest,
        into continuation: AsyncThrowingStream<CoachEvent, Error>.Continuation,
        assessment: CrisisAssessment
    ) async throws {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let anonKey {
            urlRequest.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        }
        // The acute filter is applied again here, at the actual network boundary,
        // even though `ConversationWindow` already did it. Defence in depth is
        // cheap and the failure it guards against — self-harm text reaching a
        // model because some future caller built a request by hand — is not.
        let digest = request.coherence?.promptText
        urlRequest.httpBody = try JSONEncoder().encode(
            Payload(
                message: request.message,
                threadId: request.threadID.uuidString,
                surface: request.surface.rawValue,
                history: request.history
                    .filter { $0.safety != .acute }
                    .map { Turn(role: $0.role.rawValue, text: $0.text) },
                coherence: (digest?.isEmpty ?? true) ? nil : digest
            )
        )

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoachError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // Elevated severity rides *alongside* the reply rather than replacing it —
        // the model still answers, and the UI surfaces resources next to it.
        if assessment.severity == .elevated {
            continuation.yield(.crisis(.elevated))
        }

        var usage: CoachUsage?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ServerEvent.self, from: data)
            else { continue }

            switch event.type {
            case "delta":
                if let text = event.text { continuation.yield(.delta(text)) }
            case "fallback":
                // Not an error. The function decided it could not reach the model
                // and sent authored copy; it should read as Cal talking.
                if let text = event.text { continuation.yield(.fallback(text)) }
            case "usage":
                usage = event.asUsage()
            case "error":
                throw CoachError.streamInterrupted
            case "done":
                break
            default:
                break
            }
        }

        continuation.yield(.finished(usage ?? Self.unbilled))
    }

    /// Used when nothing was sent to a model — a crisis short-circuit, or a
    /// function-level fallback. Zeroes are honest here: no tokens were spent.
    static let unbilled = CoachUsage(
        model: "none", promptVersion: "none",
        inputTokens: 0, cachedTokens: 0, outputTokens: 0, costMicros: 0
    )

    private struct Payload: Encodable {
        let message: String
        let threadId: String
        /// Selects what retrieval may see. The raw value is the wire format the
        /// function's `KINDS_FOR_SURFACE` keys off, so it matches `CoachSurface`.
        let surface: String
        let history: [Turn]
        /// The digest is sent **rendered**, not as a struct.
        ///
        /// `CoherenceSummary.promptText` is already the exact text that goes in
        /// the prompt, and it is unit-tested in `CalKit`. Sending the numbers and
        /// re-rendering them in TypeScript would mean two copies of that wording,
        /// one of them untested, drifting apart.
        let coherence: String?
    }

    private struct Turn: Encodable {
        let role: String
        let text: String
    }

    private struct ServerEvent: Decodable {
        let type: String
        let text: String?
        let model: String?
        let promptVersion: String?
        let inputTokens: Int?
        let cachedTokens: Int?
        let outputTokens: Int?

        func asUsage() -> CoachUsage {
            CoachUsage(
                model: model ?? "unknown",
                promptVersion: promptVersion ?? "unknown",
                inputTokens: inputTokens ?? 0,
                cachedTokens: cachedTokens ?? 0,
                outputTokens: outputTokens ?? 0,
                // Left at zero deliberately. Pricing belongs server-side where it
                // can change without an app release; inventing a per-token rate
                // here would just be a number that goes stale (§10.4).
                costMicros: 0
            )
        }
    }
}

public enum CoachError: Error, Equatable, Sendable {
    case badResponse(Int)
    case streamInterrupted
}
