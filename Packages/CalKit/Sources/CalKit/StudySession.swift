import Foundation

/// A focus block followed by Dr. Mia's 30-second reset.
///
/// From `SPEC-free.md` §5: 25 / 50 / 90 minute sessions, and *"every session ends
/// with"* a 30-second reset — breath, stretch, shoulders, jaw, eyes — then "back
/// to work." The reset is not optional in her spec, so it isn't optional here;
/// it's the part that makes this a coherence tool rather than a stopwatch.
///
/// Pure: phase and remaining time are functions of `startedAt` and a supplied
/// `now`, so every boundary is testable without waiting 90 minutes.
public struct StudySession: Sendable, Equatable {
    /// The three lengths from the spec.
    public enum Length: Int, CaseIterable, Sendable, Identifiable {
        case short = 25
        case medium = 50
        case long = 90

        public var id: Int { rawValue }
        public var minutes: Int { rawValue }
        public var duration: TimeInterval { TimeInterval(rawValue) * 60 }
        public var displayName: String { "\(rawValue) min" }
    }

    public enum Phase: Equatable, Sendable {
        case focus
        case reset
        case finished
    }

    /// Her reset is 30 seconds; the closing line runs past it.
    public static let resetDuration: TimeInterval = 30

    public let length: Length
    public let startedAt: Date

    public init(length: Length, startedAt: Date) {
        self.length = length
        self.startedAt = startedAt
    }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    public func phase(at now: Date) -> Phase {
        let elapsed = elapsed(at: now)
        if elapsed < length.duration { return .focus }
        if elapsed < length.duration + Self.resetDuration { return .reset }
        return .finished
    }

    /// Time left in the current phase. Zero once finished.
    public func remaining(at now: Date) -> TimeInterval {
        switch phase(at: now) {
        case .focus: max(0, length.duration - elapsed(at: now))
        case .reset: max(0, length.duration + Self.resetDuration - elapsed(at: now))
        case .finished: 0
        }
    }

    /// 0…1 through the focus block. Pinned to 1 once focus is over, so a ring
    /// doesn't wrap around and start again during the reset.
    public func focusProgress(at now: Date) -> Double {
        guard length.duration > 0 else { return 1 }
        return min(1, elapsed(at: now) / length.duration)
    }

    /// `mm:ss` for the current phase.
    public func remainingLabel(at now: Date) -> String {
        let total = Int(remaining(at: now).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
