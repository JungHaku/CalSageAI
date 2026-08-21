import Foundation

/// Renders `CalToolDescriptor.all` into the JSON the agent is configured with.
///
/// This is the whole reason the descriptors exist. A tool schema typed into a
/// vendor dashboard and a decoder written in Swift are two descriptions of one
/// contract, and they drift the moment either changes — producing a tool call
/// that arrives mid-conversation and does nothing, with no symptom except a
/// screen that did not move.
///
/// So the JSON is generated: `tools/sync-agent.sh` runs `cal-agent-tools`, which
/// prints this, and `tools/check-agent.sh` fails when the committed
/// `elevenlabs/agent.json` no longer matches.
///
/// ⚠️ **The envelope below is ElevenLabs' shape, and it is theirs to change.**
/// If a sync is rejected, the fix is almost certainly in `AgentToolSchema` — one
/// type, in one file — and not in `CalTool` or the descriptors. Keep it that way.
public enum AgentSchema {

    /// Every tool, as a pretty-printed JSON array.
    ///
    /// Deterministic: sorted keys and a stable descriptor order, so a
    /// regenerated file diffs to nothing when nothing changed. A generator whose
    /// output churns is a generator whose drift check gets ignored.
    public static func toolsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CalToolDescriptor.all.map(AgentToolSchema.init))
    }
}

/// One client tool, in the agent's configuration format.
///
/// "Client" because these run on the phone: the agent asks, the app acts, the
/// app answers. Nothing here reaches a server of ours.
struct AgentToolSchema: Encodable {
    let type = "client"
    let name: String
    let description: String
    /// The agent waits for the app's `ToolResult` before speaking again.
    ///
    /// Always true, and load-bearing. Cal announcing "let's breathe together"
    /// and then continuing while the app is still deciding is how she ends up
    /// talking over a practice, or describing a screen that failed to open.
    let expectsResponse = true
    let responseTimeoutSecs: Int
    /// Omitted entirely for tools that take none — an empty `properties` object
    /// reads to some models as "there is an argument here I have not worked out".
    let parameters: ObjectSchema?

    init(_ descriptor: CalToolDescriptor) {
        self.name = descriptor.name
        // Collapsed to a single line: these are read by a model, and the
        // wrapping in the Swift source is for the humans reviewing it.
        self.description = descriptor.purpose
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        self.responseTimeoutSecs = descriptor.responseTimeoutSeconds
        self.parameters = descriptor.parameters.isEmpty
            ? nil
            : ObjectSchema(descriptor.parameters)
    }

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters
        case expectsResponse = "expects_response"
        case responseTimeoutSecs = "response_timeout_secs"
    }

    struct ObjectSchema: Encodable {
        let type = "object"
        let properties: [String: PropertySchema]
        let required: [String]

        init(_ parameters: [CalToolDescriptor.Parameter]) {
            self.properties = Dictionary(
                uniqueKeysWithValues: parameters.map { ($0.name, PropertySchema($0)) }
            )
            self.required = parameters.filter(\.isRequired).map(\.name)
        }
    }

    struct PropertySchema: Encodable {
        let type: String
        let description: String
        /// Constrains the model rather than merely asking it. Every enum the
        /// decoder accepts is listed, so a value that gets past the model is a
        /// value `CalTool.init` will take.
        let allowed: [String]?

        init(_ parameter: CalToolDescriptor.Parameter) {
            self.type = parameter.type.rawValue
            self.description = parameter.describedAs
            self.allowed = parameter.allowedValues.isEmpty ? nil : parameter.allowedValues
        }

        enum CodingKeys: String, CodingKey {
            case type, description
            case allowed = "enum"
        }
    }
}
