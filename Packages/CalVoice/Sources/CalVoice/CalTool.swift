import Foundation

/// A tool call as it arrives from the agent, undecoded.
///
/// Carried through `VoiceEvent.toolCall` in this shape on purpose: the decode can
/// fail, and when it does the failure has to travel back to Cal as a
/// `ToolResult` so she can correct herself out loud. If the stream decoded eagerly
/// it would have to either throw — killing the session over a bad argument — or
/// swallow it, which is Cal saying "let's breathe together" while nothing moves.
public struct VoiceToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The raw JSON object of arguments. `{}` when the tool takes none.
    public let arguments: Data

    public init(id: String, name: String, arguments: Data = Data("{}".utf8)) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Convenience for tests and fixtures, where the arguments are a literal.
    public init(id: String, name: String, json: String) {
        self.init(id: id, name: name, arguments: Data(json.utf8))
    }
}

/// A screen Cal can open that isn't part of a richer flow.
public enum CalScreen: String, Codable, Sendable, CaseIterable {
    case practices
    case settings
    /// The Berkeley campus map, with no search pre-filled.
    case map
    /// Focus block with a timed reset.
    case study
}

/// Everything Cal is allowed to do to the app.
///
/// This enum is the entire surface. A capability that isn't here is one Cal
/// cannot reach, which is the property worth protecting — the agent's prompt
/// lives on a vendor's servers and can be edited by anyone with the login, so the
/// list of things a compromised or merely confused prompt can trigger should be
/// short, enumerated, and reviewed in a diff.
///
/// Note what is deliberately absent: nothing deletes, nothing spends, nothing
/// signs in or out, and nothing changes consent. Those stay taps. Daily check-in
/// is a form on the phone, not a voice tool.
public enum CalTool: Sendable, Equatable {
    /// Grounding before Cal talks about "how you've been." Call this before
    /// stating any number about them. If they have not checked in, this says so.
    case todayStatus

    case playPractice(slug: String)
    case stopPractice
    case showPlace(query: String)
    case openScreen(CalScreen)
    case endSession
}

// MARK: - The trust boundary

extension CalTool {
    /// Decodes a call from the agent.
    ///
    /// This initializer is the whole trust boundary between a language model and
    /// the student's data, so it validates rather than coerces.
    public init(_ call: VoiceToolCall) throws(CalToolError) {
        switch call.name {
        case Name.todayStatus:  self = .todayStatus
        case Name.stopPractice: self = .stopPractice
        case Name.endSession:   self = .endSession

        case Name.playPractice:
            let args: SlugArgs = try Self.decode(call)
            let slug = args.slug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else {
                throw .invalidValue(tool: call.name, argument: "slug", reason: "must not be empty")
            }
            self = .playPractice(slug: slug)

        case Name.showPlace:
            let args: QueryArgs = try Self.decode(call)
            let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw .invalidValue(tool: call.name, argument: "query", reason: "must not be empty")
            }
            self = .showPlace(query: query)

        case Name.openScreen:
            let args: ScreenArgs = try Self.decode(call)
            guard let screen = CalScreen(rawValue: args.screen) else {
                throw .invalidValue(
                    tool: call.name, argument: "screen",
                    reason: Self.oneOf(CalScreen.allCases.map(\.rawValue))
                )
            }
            self = .openScreen(screen)

        default:
            throw .unknownTool(call.name)
        }
    }

    /// The tool's wire name, for logging and for asserting against `agent.json`.
    public var name: String {
        switch self {
        case .todayStatus:  Name.todayStatus
        case .playPractice: Name.playPractice
        case .stopPractice: Name.stopPractice
        case .showPlace:    Name.showPlace
        case .openScreen:   Name.openScreen
        case .endSession:   Name.endSession
        }
    }

    public enum Name {
        public static let todayStatus  = "get_today_status"
        public static let playPractice = "play_practice"
        public static let stopPractice = "stop_practice"
        public static let showPlace    = "show_place"
        public static let openScreen   = "open_screen"
        public static let endSession   = "end_session"

        /// Every name the decoder accepts. `CalToolDescriptorTests` asserts this
        /// matches `CalToolDescriptor.all` in both directions, so a tool added to
        /// one and forgotten in the other fails `swift test` rather than failing
        /// silently in front of Dr. Mia.
        public static let all = [
            todayStatus, playPractice, stopPractice, showPlace, openScreen, endSession,
        ]
    }

    private static func decode<T: Decodable>(_ call: VoiceToolCall) throws(CalToolError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: call.arguments)
        } catch {
            throw .malformedArguments(tool: call.name, detail: Self.explain(error))
        }
    }

    /// Turns a `DecodingError` into something worth saying to a model.
    ///
    /// Cal is going to hear this and try again, so "missing 'value'" is useful
    /// and the default multi-line dump of coding paths is not.
    private static func explain(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "could not be read" }
        switch decoding {
        case .keyNotFound(let key, _):
            return "missing '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let key = context.codingPath.last?.stringValue
            return key.map { "'\($0)' is the wrong type" } ?? "an argument is the wrong type"
        case .dataCorrupted:
            return "was not valid JSON"
        @unknown default:
            return "could not be read"
        }
    }

    private static func oneOf(_ values: [String]) -> String {
        "must be one of: " + values.joined(separator: ", ")
    }

    private struct SlugArgs: Decodable { let slug: String }
    private struct QueryArgs: Decodable { let query: String }
    private struct ScreenArgs: Decodable { let screen: String }
}

// MARK: - Results

/// What goes back to the agent after a tool runs.
///
/// Short and factual, because Cal reads it and then talks about it. "opened
/// 4-7-8" and "no place matched 'the gym'" both give her something true to say;
/// an empty acknowledgement gives her nothing, and she will fill the gap with
/// something plausible.
public struct ToolResult: Sendable, Equatable {
    public let text: String
    /// Marks the tool as having failed, so the agent treats it as something to
    /// recover from rather than a fact about the world.
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func ok(_ text: String) -> ToolResult {
        ToolResult(text: text)
    }

    public static func failure(_ text: String) -> ToolResult {
        ToolResult(text: text, isError: true)
    }

    public init(_ error: CalToolError) {
        self.init(text: error.agentMessage, isError: true)
    }
}

/// Why a tool call could not be turned into a `CalTool`.
public enum CalToolError: Error, Equatable, Sendable {
    case unknownTool(String)
    case malformedArguments(tool: String, detail: String)
    case invalidValue(tool: String, argument: String, reason: String)

    /// What Cal is told. Phrased so the next attempt can be right — the agent is
    /// the only one who can fix any of these, and it can only fix what it is told.
    public var agentMessage: String {
        switch self {
        case .unknownTool(let name):
            "There is no tool called '\(name)'."
        case .malformedArguments(let tool, let detail):
            "The arguments to \(tool) \(detail)."
        case .invalidValue(let tool, let argument, let reason):
            "The '\(argument)' argument to \(tool) \(reason)."
        }
    }
}

// MARK: - Performing

/// Whoever actually moves the screen.
///
/// Implemented in the app target by the router, because it owns a
/// `NavigationPath` and this package deliberately knows nothing about SwiftUI.
@MainActor
public protocol CalToolPerforming: AnyObject, Sendable {
    func perform(_ tool: CalTool) async -> ToolResult
}
