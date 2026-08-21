import CalVoice
import Foundation

// Prints the agent's tool schema, generated from `CalToolDescriptor.all`.
//
// The whole executable. `tools/sync-agent.sh` pipes this into
// `elevenlabs/agent.json`, and `tools/check-agent.sh` compares it against what
// is committed — so the tools the agent is told about cannot drift from the
// tools the app will accept.
//
//   swift run --package-path Packages/CalVoice cal-agent-tools
//
// Deliberately not part of the CalVoice library product: nothing in the app
// links it, and it never runs on a device.

do {
    FileHandle.standardOutput.write(try AgentSchema.toolsJSON())
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("failed to render agent tools: \(error)\n".utf8))
    exit(1)
}
