import Foundation
import Observation

/// Owns one in-flight guided practice for voice (`PLAN-practice-voice-form.md` §1).
///
/// `play_practice` awaits `begin` until the player reports a terminal outcome.
/// Finish, skip, route pop, and `stop_practice` all resolve through here — and
/// only once — so the agent is never told the practice ended twice.
@Observable
@MainActor
final class PracticeRunCoordinator {
    enum Outcome: Equatable, Sendable {
        /// Timeline reached its end.
        case completed
        /// Skip, dismiss, `stop_practice`, or the route was torn down.
        case stopped
    }

    private(set) var activeSlug: String?
    private(set) var isRunning = false

    /// Observed by `PracticeRunnerView` so `stop_practice` can tear down the
    /// player without only popping a route.
    private(set) var stopToken = 0

    private var continuation: CheckedContinuation<Outcome, Never>?
    private var resolved = false

    /// Starts a run and suspends until `resolve` is called.
    ///
    /// If a previous run is still open, it is resolved as `.stopped` first so
    /// Cal never waits on a practice that was replaced.
    func begin(slug: String) async -> Outcome {
        if isRunning {
            resolve(.stopped)
        }
        activeSlug = slug
        isRunning = true
        resolved = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Idempotent. Safe to call from finish, skip, disappear, and stop.
    func resolve(_ outcome: Outcome) {
        guard isRunning, !resolved else { return }
        resolved = true
        isRunning = false
        let slug = activeSlug
        activeSlug = nil
        continuation?.resume(returning: outcome)
        continuation = nil
        _ = slug
    }

    /// Asks the active player to stop, then resolves `.stopped` if the player
    /// never reports (e.g. detail was already gone).
    func requestStop() {
        guard isRunning else { return }
        stopToken &+= 1
        // If nothing is observing the token (route already popped), resolve now.
        // Views that are still up call `resolve(.stopped)` from onDisappear /
        // skip; a short deferred resolve covers the gap without double-resume
        // thanks to idempotency.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            resolve(.stopped)
        }
    }
}
