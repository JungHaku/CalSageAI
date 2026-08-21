import Foundation
import Testing

@testable import CalVoice

/// The trust boundary between a language model and the student's data.
@Suite("CalTool — decoding agent calls")
struct CalToolTests {

    @Test("no-argument tools")
    func noArguments() throws {
        #expect(try CalTool(VoiceToolCall(id: "1", name: "get_today_status")) == .todayStatus)
        #expect(try CalTool(VoiceToolCall(id: "2", name: "start_check_in")) == .startCheckIn)
        #expect(try CalTool(VoiceToolCall(id: "3", name: "skip_regulation")) == .skipRegulation)
        #expect(try CalTool(VoiceToolCall(id: "4", name: "continue_check_in")) == .continueCheckIn)
        #expect(try CalTool(VoiceToolCall(id: "5", name: "stop_practice")) == .stopPractice)
        #expect(try CalTool(VoiceToolCall(id: "6", name: "end_session")) == .endSession)
    }

    @Test("record_score accepts 0–10")
    func recordScore() throws {
        #expect(
            try CalTool(VoiceToolCall(id: "1", name: "record_score", json: #"{"value":7}"#))
                == .recordScore(value: 7)
        )
    }

    @Test("record_score rejects out of range")
    func recordScoreRange() {
        #expect(throws: CalToolError.self) {
            try CalTool(VoiceToolCall(id: "1", name: "record_score", json: #"{"value":11}"#))
        }
    }

    @Test("every screen Cal can open", arguments: CalScreen.allCases)
    func everyScreen(_ screen: CalScreen) throws {
        let tool = try CalTool(
            VoiceToolCall(id: "1", name: "open_screen", json: #"{"screen":"\#(screen.rawValue)"}"#)
        )
        #expect(tool == .openScreen(screen))
    }

    @Test("free-text arguments are trimmed, not rejected")
    func trimming() throws {
        #expect(
            try CalTool(VoiceToolCall(id: "1", name: "show_place", json: #"{"query":"  the gym  "}"#))
                == .showPlace(query: "the gym")
        )
        #expect(
            try CalTool(VoiceToolCall(id: "2", name: "play_practice", json: #"{"slug":" 4-7-8 "}"#))
                == .playPractice(slug: "4-7-8")
        )
    }

    @Test("empty free text is rejected rather than opening an empty search")
    func emptyStrings() {
        #expect(throws: CalToolError.self) {
            try CalTool(VoiceToolCall(id: "1", name: "show_place", json: #"{"query":"   "}"#))
        }
        #expect(throws: CalToolError.self) {
            try CalTool(VoiceToolCall(id: "2", name: "play_practice", json: #"{"slug":""}"#))
        }
    }

    @Test("a tool that does not exist is named back")
    func unknownTool() {
        let error = capture { try CalTool(VoiceToolCall(id: "1", name: "delete_everything")) }
        #expect(error == .unknownTool("delete_everything"))
        #expect(error?.agentMessage.contains("delete_everything") == true)
    }

    @Test("garbage in the arguments field does not throw out of the decoder")
    func garbage() {
        let error = capture {
            try CalTool(VoiceToolCall(id: "1", name: "show_place", json: "not json at all"))
        }
        #expect(error != nil)
    }

    @Test("a decode failure converts to a result Cal can act on")
    func errorBecomesResult() {
        let result = ToolResult(CalToolError.unknownTool("nope"))
        #expect(result.isError)
        #expect(result.text == "There is no tool called 'nope'.")
    }

    @Test("a missing argument names itself")
    func missingArgument() {
        let error = capture {
            try CalTool(VoiceToolCall(id: "1", name: "play_practice", json: "{}"))
        }
        #expect(error == .malformedArguments(tool: "play_practice", detail: "missing 'slug'"))
    }

    private func capture(_ body: () throws -> CalTool) -> CalToolError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? CalToolError
        }
    }
}
