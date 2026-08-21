import CalDesign
import CalKit
import CalVoice
import Foundation
import Observation

/// App-scoped voice companion (`PLAN-cal-sage-shell.md` §2).
///
/// Owned above the shell so dismissing the Cal cover does not hang up. The orb
/// halo, the mini strip, and the cover all render this same session. Only
/// `scenePhase == .background`, an explicit end, or a failed/ended restart path
/// stops it.
@Observable
@MainActor
final class SageSession {
    let model: VoiceRootViewModel

    init(
        makeSession: @escaping @MainActor @Sendable () -> any VoiceSession,
        router: SageRouter,
        remember: (@MainActor @Sendable (String, String) -> Void)? = nil
    ) {
        self.model = VoiceRootViewModel(
            makeSession: makeSession,
            router: router,
            remember: remember
        )
    }

    var state: VoiceSessionState { model.state }
    var isLive: Bool { model.isLive }
    var crisis: CrisisSeverity { model.crisis }

    /// Halo for the raised orb — bronze-gold wash on the light field.
    var orbHalo: CalAvatar.Halo { .sageAndGold }

    /// Ring motion for the live companion. Idle everywhere else.
    var orbActivity: CalAvatar.Activity {
        switch state {
        case .speaking:            .speaking
        case .listening, .hearing: .listening
        case .thinking:            .thinking
        default:                   .idle
        }
    }

    /// Opens / resumes the conversation. Idle starts; ended or failed restarts;
    /// already live is a no-op. Orb and launch both go through here so there is
    /// never a separate "connect" step.
    func connectIfNeeded() {
        switch model.state {
        case .idle:
            model.start()
        case .ended, .failed:
            Task { await model.restart() }
        default:
            break
        }
    }

    func stop() async {
        await model.stop()
    }

    func acknowledgeCrisis() {
        model.acknowledgeCrisis()
    }
}
