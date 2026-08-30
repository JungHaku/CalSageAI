import Foundation
import Testing

@testable import CalVoice

/// The drift guard.
///
/// `CalToolDescriptor.all` is what the agent is told it can do;
/// `CalTool.init(_:)` is what the app will actually accept. They are two
/// descriptions of one contract, and the failure when they disagree is a tool
/// call that arrives mid-conversation and does nothing at all.
@Suite("CalToolDescriptor — the agent's schema matches the decoder")
struct CalToolDescriptorTests {

    @Test("every declared tool is one the decoder accepts")
    func noPhantomTools() {
        for descriptor in CalToolDescriptor.all {
            let call = exampleCall(for: descriptor)
            #expect(
                (try? CalTool(call)) != nil,
                "'\(descriptor.name)' is described to the agent but the decoder rejects it"
            )
        }
    }

    @Test("every tool the decoder accepts is declared to the agent")
    func noHiddenTools() {
        let described = Set(CalToolDescriptor.all.map(\.name))
        for name in CalTool.Name.all {
            #expect(described.contains(name), "'\(name)' is decodable but the agent is never told about it")
        }
    }

    @Test("the name list and the descriptor list are the same set")
    func listsAgree() {
        #expect(Set(CalToolDescriptor.all.map(\.name)) == Set(CalTool.Name.all))
        #expect(CalToolDescriptor.all.count == CalTool.Name.all.count, "a name is duplicated")
    }

    @Test("enum parameters offer exactly the values the decoder accepts")
    func enumsAgree() {
        let allowed = { (tool: String, parameter: String) -> [String] in
            CalToolDescriptor.all
                .first { $0.name == tool }?
                .parameters.first { $0.name == parameter }?
                .allowedValues ?? []
        }
        #expect(allowed("open_screen", "screen") == CalScreen.allCases.map(\.rawValue))
    }

    /// The rule `PROMPT-cal.md` already enforces on the text path, restated where
    /// the agent will read it. Losing this line is how Cal starts inventing
    /// someone's streak.
    @Test("get_today_status tells the agent not to invent numbers")
    func numbersRule() throws {
        let descriptor = try #require(CalToolDescriptor.all.first { $0.name == CalTool.Name.todayStatus })
        #expect(descriptor.purpose.lowercased().contains("never state a number"))
        #expect(descriptor.purpose.lowercased().contains("do not start a check-in"))
    }

    /// Builds a call that should decode, from the descriptor alone. If a
    /// parameter is added to the schema and not to the decoder — or vice versa —
    /// this is what notices.
    private func exampleCall(for descriptor: CalToolDescriptor) -> VoiceToolCall {
        let pairs = descriptor.parameters.map { parameter -> String in
            switch parameter.type {
            case .integer:
                return "\"\(parameter.name)\":5"
            case .string:
                let value = parameter.allowedValues.first ?? "example"
                return "\"\(parameter.name)\":\"\(value)\""
            }
        }
        return VoiceToolCall(id: "example", name: descriptor.name, json: "{\(pairs.joined(separator: ","))}")
    }
}
