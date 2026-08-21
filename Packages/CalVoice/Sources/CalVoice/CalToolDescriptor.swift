import Foundation

/// The tool vocabulary as the agent is told it.
///
/// This exists so `elevenlabs/agent.json` can be **generated** rather than
/// hand-written (`PLAN-voice-first.md` §2). A tool schema typed into a vendor
/// dashboard and a decoder written in Swift are two descriptions of one contract,
/// and they drift the moment either changes. The failure that produces is
/// specific and bad: Cal calls a tool with arguments the app rejects, mid-session,
/// in front of someone — and the only symptom is that nothing happens.
///
/// So: this is the source, `tools/sync-agent.sh` renders it, and
/// `tools/check-agent.sh` fails the build when the rendering is stale. Same
/// pattern as `sync-prompt.sh` / `check-prompt.sh`.
public struct CalToolDescriptor: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public enum ValueType: String, Sendable {
            case string
            case integer
        }

        public let name: String
        public let type: ValueType
        public let isRequired: Bool
        /// Non-empty for enums. Rendered into the JSON schema so the model is
        /// constrained rather than merely asked.
        public let allowedValues: [String]
        /// What the model needs to know to get it right.
        public let describedAs: String

        public init(
            name: String,
            type: ValueType,
            isRequired: Bool = true,
            allowedValues: [String] = [],
            describedAs: String
        ) {
            self.name = name
            self.type = type
            self.isRequired = isRequired
            self.allowedValues = allowedValues
            self.describedAs = describedAs
        }
    }

    public let name: String
    /// The one-line purpose the agent sees. Written for a model deciding whether
    /// to call it, not for a developer reading a list.
    public let purpose: String
    public let parameters: [Parameter]
    /// How long the agent waits for the app before giving up on this call.
    public let responseTimeoutSeconds: Int

    public init(
        name: String,
        purpose: String,
        parameters: [Parameter] = [],
        responseTimeoutSeconds: Int = 10
    ) {
        self.name = name
        self.purpose = purpose
        self.parameters = parameters
        self.responseTimeoutSeconds = responseTimeoutSeconds
    }
}

extension CalToolDescriptor {
    public static let all: [CalToolDescriptor] = [
        CalToolDescriptor(
            name: CalTool.Name.todayStatus,
            purpose: """
            Grounding before you talk about how this student has been. Never \
            state a number about them — a streak, an average, a past score — \
            that you did not get from this tool. If they have not checked in \
            today, say "Check in today" and call start_check_in, then ask the \
            first question it returns. If they already checked in, open from \
            the band it reports (high / moderate / low) — never invent one.
            """
        ),

        CalToolDescriptor(
            name: CalTool.Name.startCheckIn,
            purpose: """
            Begin the spoken daily check-in (five topics, each 0–10). Returns \
            the exact question to ask next. Ask it out loud and wait for a \
            number. Do not open a screen. Do not stay silent.
            """
        ),

        CalToolDescriptor(
            name: CalTool.Name.recordScore,
            purpose: """
            Save their 0–10 answer for the current check-in question. Call this \
            as soon as they give a number. The result tells you the next \
            question, or to offer a short regulation practice if the score is low.
            """,
            parameters: [
                Parameter(
                    name: "value",
                    type: .integer,
                    describedAs: "Their rating from 0 to 10 inclusive."
                )
            ]
        ),

        CalToolDescriptor(
            name: CalTool.Name.skipRegulation,
            purpose: """
            They declined the regulation exercise. Advance to the next check-in \
            topic without an after-score.
            """
        ),

        CalToolDescriptor(
            name: CalTool.Name.continueCheckIn,
            purpose: """
            Call after a regulation practice finishes (or they are ready to \
            re-rate). Returns the re-prompt question to ask out loud.
            """
        ),

        CalToolDescriptor(
            name: CalTool.Name.playPractice,
            purpose: """
            Start a guided practice and return the spoken script. Read that \
            script out loud, exactly, with the waits, so they can follow with \
            their eyes closed. Do not invent extra lines. After the last wait \
            you may speak again. Prefer basic breath slugs for free-tier \
            regulation: box-breath, even-breath, belly-breath, four-seven-eight, \
            release-sigh, study-reset.
            """,
            parameters: [
                Parameter(
                    name: "slug",
                    type: .string,
                    describedAs: "The practice identifier: box-breath, even-breath, belly-breath, four-seven-eight, release-sigh, study-reset, or a guided-practice slug."
                )
            ],
            responseTimeoutSeconds: 20
        ),

        CalToolDescriptor(
            name: CalTool.Name.stopPractice,
            purpose: "Stop a running practice early, for example if the student asks you to."
        ),

        CalToolDescriptor(
            name: CalTool.Name.showPlace,
            purpose: """
            Show somewhere on the Berkeley campus map. Prefer Breathe Health \
            Center when they mention headache, depression, anxiety, body pain, \
            or feeling lethargic — and only suggest that clinic once per day. \
            Use for a building name or a plain description like 'somewhere quiet \
            to study'. If they only want the map itself, use open_screen with \
            screen 'map' instead.
            """,
            parameters: [
                Parameter(
                    name: "query",
                    type: .string,
                    describedAs: "What the student is looking for, in their own words."
                )
            ],
            responseTimeoutSeconds: 20
        ),

        CalToolDescriptor(
            name: CalTool.Name.openScreen,
            purpose: """
            Open one of the app's other screens when the student asks to see it. \
            Use screen 'map' for the Berkeley campus map with no place selected. \
            For check-in, use start_check_in — do not open a check-in screen.
            """,
            parameters: [
                Parameter(
                    name: "screen",
                    type: .string,
                    allowedValues: CalScreen.allCases.map(\.rawValue),
                    describedAs: "Which screen to open. 'map' is the Berkeley campus map."
                )
            ]
        ),

        CalToolDescriptor(
            name: CalTool.Name.endSession,
            purpose: "End the conversation, when the student says goodbye or asks you to stop."
        ),
    ]
}
