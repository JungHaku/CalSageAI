import Foundation

/// What the body is doing during a beat. Drives the visual, the haptic, and the
/// VoiceOver announcement, so the UI never has to invent any of them.
public enum BreathPhase: String, Codable, Sendable, CaseIterable {
    case cue      // spoken guidance, no breath instruction
    case inhale
    case hold
    case exhale

    /// Haptic strength at the *start* of this phase. Inhale and exhale are the
    /// beats a user paces against with their eyes closed, so they're the firm
    /// ones; hold is a light tick; a cue is silent so guidance doesn't buzz.
    public var hapticIntensity: Double {
        switch self {
        case .cue:    0.0
        case .inhale: 0.9
        case .hold:   0.3
        case .exhale: 0.7
        }
    }

    public var isBreath: Bool { self != .cue }
}

/// One authored step. Decoded from the `exercises.script` jsonb column, whose
/// shape is defined in `supabase/seed.sql`.
public enum ExerciseStep: Sendable, Equatable {
    case timed(phase: BreathPhase, text: String, seconds: TimeInterval)
    /// Repeats the contiguous run of breath steps immediately before it, so that
    /// run happens `times` times **in total** (not `times` additional times).
    case repeatCycle(times: Int)
}

extension ExerciseStep: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, seconds, times }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        if kind == "repeat" {
            self = .repeatCycle(times: try container.decode(Int.self, forKey: .times))
            return
        }
        guard let phase = BreathPhase(rawValue: kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown step kind '\(kind)'"
            )
        }
        self = .timed(
            phase: phase,
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            seconds: try container.decode(TimeInterval.self, forKey: .seconds)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repeatCycle(let times):
            try container.encode("repeat", forKey: .kind)
            try container.encode(times, forKey: .times)
        case .timed(let phase, let text, let seconds):
            try container.encode(phase.rawValue, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(seconds, forKey: .seconds)
        }
    }
}

public struct ExerciseScript: Codable, Sendable, Equatable {
    public let steps: [ExerciseStep]

    public init(steps: [ExerciseStep]) { self.steps = steps }

    public init(json: Data) throws {
        self.steps = try JSONDecoder().decode([ExerciseStep].self, from: json)
    }
}

public enum ExerciseScriptError: Error, Equatable, Sendable {
    case repeatWithoutPrecedingCycle
    case repeatCountOutOfRange(Int)
    case nonPositiveDuration(TimeInterval)
    case empty
}

/// A flattened, absolutely-timed schedule — `repeat` expanded, offsets computed.
///
/// Flattening ahead of time rather than interpreting during playback means the
/// player is a pure lookup against elapsed time. That keeps drift out of the loop
/// and, more importantly, makes the whole schedule assertable in a unit test
/// instead of only observable by watching it run.
public struct ExerciseTimeline: Sendable, Equatable {
    public struct Beat: Sendable, Equatable, Identifiable {
        public let id: Int
        public let phase: BreathPhase
        public let text: String
        public let start: TimeInterval
        public let duration: TimeInterval
        /// 1-based repetition this beat belongs to, for "breath 3 of 4" UI.
        public let cycle: Int?
        /// Total repetitions in this beat's cycle, when it's part of one.
        public let cycleCount: Int?

        public var end: TimeInterval { start + duration }
    }

    public let beats: [Beat]

    /// A timeline with nothing to play.
    ///
    /// The memberwise initialiser stays internal on purpose — only `timeline()`
    /// can produce a valid schedule, because the beats' cumulative offsets have to
    /// be consistent with their durations. This is the one named exception, for
    /// callers that need a safe "nothing to play" value.
    public static let empty = ExerciseTimeline(beats: [])

    public var totalDuration: TimeInterval { beats.last?.end ?? 0 }

    /// The beat covering `time`. Clamps: before the start returns the first beat,
    /// at or past the end returns `nil` so the player can finish.
    public func beat(at time: TimeInterval) -> Beat? {
        guard !beats.isEmpty else { return nil }
        if time < 0 { return beats[0] }
        return beats.first { time < $0.end }
    }

    public func progress(at time: TimeInterval) -> Double {
        guard totalDuration > 0 else { return 1 }
        return min(1, max(0, time / totalDuration))
    }
}

extension ExerciseScript {
    public func timeline() throws -> ExerciseTimeline {
        guard !steps.isEmpty else { throw ExerciseScriptError.empty }

        // Expand `repeat` into concrete steps first, tagging cycle membership.
        var expanded: [(phase: BreathPhase, text: String, seconds: TimeInterval, cycle: Int?, of: Int?)] = []

        for step in steps {
            switch step {
            case .timed(let phase, let text, let seconds):
                guard seconds > 0 else { throw ExerciseScriptError.nonPositiveDuration(seconds) }
                expanded.append((phase, text, seconds, nil, nil))

            case .repeatCycle(let times):
                guard times >= 1, times <= 100 else {
                    throw ExerciseScriptError.repeatCountOutOfRange(times)
                }
                // The cycle is the maximal trailing run of breath steps.
                let cycleStart = expanded.lastIndex(where: { !$0.phase.isBreath }).map { $0 + 1 } ?? 0
                let cycle = Array(expanded[cycleStart...])
                guard !cycle.isEmpty else { throw ExerciseScriptError.repeatWithoutPrecedingCycle }

                // The run already present counts as repetition 1.
                expanded.replaceSubrange(
                    cycleStart...,
                    with: (1...times).flatMap { repetition in
                        cycle.map { ($0.phase, $0.text, $0.seconds, repetition, times) }
                    }
                )
            }
        }

        var beats: [ExerciseTimeline.Beat] = []
        var clock: TimeInterval = 0
        for (index, item) in expanded.enumerated() {
            beats.append(
                .init(
                    id: index, phase: item.phase, text: item.text,
                    start: clock, duration: item.seconds,
                    cycle: item.cycle, cycleCount: item.of
                )
            )
            clock += item.seconds
        }
        return ExerciseTimeline(beats: beats)
    }
}

/// An exercise as stored in `public.exercises` — and, in the MVP, as shipped in
/// `CalContent`'s bundled JSON. `Codable` because those are the same shape:
/// content moves from bundle to database at Phase B without a translation layer.
public struct Exercise: Sendable, Equatable, Identifiable, Codable {
    public let slug: String
    public let title: String
    /// Dr. Mia's one-line statement of what the practice is for, verbatim from
    /// `SPEC-practices.md` ("Expand awareness beyond the self…"). Optional so a
    /// payload without it still decodes.
    public let purpose: String?
    public let category: CoherenceCategory?
    public let tier: ContentTier
    public let script: ExerciseScript
    public let audioPath: String?
    public let version: Int

    public var id: String { slug }

    public init(
        slug: String,
        title: String,
        purpose: String? = nil,
        category: CoherenceCategory?,
        tier: ContentTier,
        script: ExerciseScript,
        audioPath: String? = nil,
        version: Int = 1
    ) {
        self.slug = slug
        self.title = title
        self.purpose = purpose
        self.category = category
        self.tier = tier
        self.script = script
        self.audioPath = audioPath
        self.version = version
    }

    /// Total runtime, or `nil` when the script is malformed.
    public var duration: TimeInterval? {
        try? script.timeline().totalDuration
    }
}

public enum ContentTier: String, Codable, Sendable {
    case free, premium
}
