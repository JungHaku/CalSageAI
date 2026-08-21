// swift-tools-version: 6.0
import PackageDescription

// CalVoice holds the boundary between the app and the live voice agent, and
// nothing else. No SwiftUI, no AVFoundation, no WebSocket — those arrive in
// `ElevenLabsVoiceSession` (PLAN-voice-first.md §9 step 4), behind the protocol
// declared here.
//
// The rule this package exists to enforce: everything about *what Cal can do to
// the app* — the tool vocabulary, the trust boundary that decodes agent JSON,
// and the crisis tripwire — is testable with `swift test`, with no simulator, no
// microphone, no socket and no billable second. If something here needs a
// device, it belongs in the app target instead.
let package = Package(
    name: "CalVoice",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CalVoice", targets: ["CalVoice"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(name: "CalVoice", dependencies: ["CalKit"]),
        // Renders the agent's tool schema for `tools/sync-agent.sh`. Not part of
        // the library product, so the app never links it and it never runs on a
        // device — it exists so the schema the agent is given is generated from
        // the same descriptors the decoder validates against.
        .executableTarget(name: "CalAgentTools", dependencies: ["CalVoice"]),
        .testTarget(name: "CalVoiceTests", dependencies: ["CalVoice"]),
    ]
)
