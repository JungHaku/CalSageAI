import Foundation
import Testing

@testable import CalKit

@Suite("ExerciseScript")
struct ExerciseScriptTests {
    /// The exact jsonb shape stored in `supabase/seed.sql`. If the two drift, the
    /// app can't play the content Dr. Mia edits, so this string is the contract.
    static let seedJSON = """
    [
      {"kind":"cue","text":"Let's take one minute together.","seconds":4},
      {"kind":"inhale","text":"Breathe in through your nose","seconds":4},
      {"kind":"hold","text":"Hold","seconds":2},
      {"kind":"exhale","text":"Out slowly through your mouth","seconds":6},
      {"kind":"repeat","times":4},
      {"kind":"cue","text":"Let your shoulders drop.","seconds":4}
    ]
    """

    @Test("the seed script from the migration decodes")
    func decodesSeed() throws {
        let script = try ExerciseScript(json: Data(Self.seedJSON.utf8))
        #expect(script.steps.count == 6)
        #expect(script.steps[0] == .timed(phase: .cue, text: "Let's take one minute together.", seconds: 4))
        #expect(script.steps[4] == .repeatCycle(times: 4))
    }

    /// The bundled copy exists so a low score works offline and on a fresh install;
    /// if it drifts from the row in `seed.sql`, the same exercise plays differently
    /// depending on whether the device has synced. This pins them together.
    @Test("the bundled placeholder is identical to the seed.sql row")
    func bundledMatchesSeed() throws {
        #expect(try ExerciseScript(json: Data(Self.seedJSON.utf8)) == Exercise.placeholder.script)
    }

    @Test("round-trips through encode/decode unchanged")
    func roundTrips() throws {
        let original = try ExerciseScript(json: Data(Self.seedJSON.utf8))
        let reDecoded = try ExerciseScript(json: try JSONEncoder().encode(original.steps))
        #expect(reDecoded == original)
    }

    @Test("an unknown step kind is rejected rather than silently dropped")
    func rejectsUnknownKind() {
        #expect(throws: (any Error).self) {
            try ExerciseScript(json: Data(#"[{"kind":"levitate","seconds":3}]"#.utf8))
        }
    }

    // MARK: repeat semantics

    @Test("repeat means N cycles TOTAL, expanding the trailing breath run")
    func repeatIsTotalNotAdditional() throws {
        let timeline = try ExerciseScript(json: Data(Self.seedJSON.utf8)).timeline()

        // cue + (inhale, hold, exhale) x 4 + cue = 1 + 12 + 1 = 14 beats
        #expect(timeline.beats.count == 14)
        // 4 + (4 + 2 + 6) x 4 + 4 = 56s
        #expect(timeline.totalDuration == 56)
        #expect(timeline.beats.filter { $0.phase == .inhale }.count == 4)
    }

    @Test("cycle numbering is 1-based and carries its total, for \"breath 3 of 4\" UI")
    func cycleNumbering() throws {
        let timeline = try ExerciseScript(json: Data(Self.seedJSON.utf8)).timeline()
        let inhales = timeline.beats.filter { $0.phase == .inhale }
        #expect(inhales.map(\.cycle) == [1, 2, 3, 4])
        #expect(inhales.allSatisfy { $0.cycleCount == 4 })
        // Cues sit outside any cycle.
        #expect(timeline.beats.first?.cycle == nil)
        #expect(timeline.beats.last?.cycle == nil)
    }

    @Test("repeat only takes the trailing breath run, not everything before it")
    func repeatStopsAtACue() throws {
        let script = ExerciseScript(steps: [
            .timed(phase: .inhale, text: "warmup", seconds: 1),
            .timed(phase: .cue, text: "now the real thing", seconds: 1),
            .timed(phase: .inhale, text: "in", seconds: 2),
            .timed(phase: .exhale, text: "out", seconds: 2),
            .repeatCycle(times: 3),
        ])
        let timeline = try script.timeline()

        // warmup + cue + (in, out) x 3 = 8 beats; the warmup inhale is not repeated.
        #expect(timeline.beats.count == 8)
        #expect(timeline.beats.filter { $0.text == "warmup" }.count == 1)
        #expect(timeline.totalDuration == 1 + 1 + (2 + 2) * 3)
    }

    @Test("repeat times: 1 is a no-op")
    func repeatOnce() throws {
        let script = ExerciseScript(steps: [
            .timed(phase: .inhale, text: "in", seconds: 2),
            .repeatCycle(times: 1),
        ])
        #expect(try script.timeline().beats.count == 1)
    }

    @Test("malformed scripts throw with a specific reason")
    func validation() {
        #expect(throws: ExerciseScriptError.empty) {
            try ExerciseScript(steps: []).timeline()
        }
        #expect(throws: ExerciseScriptError.repeatWithoutPrecedingCycle) {
            try ExerciseScript(steps: [.repeatCycle(times: 3)]).timeline()
        }
        #expect(throws: ExerciseScriptError.repeatWithoutPrecedingCycle) {
            try ExerciseScript(steps: [
                .timed(phase: .cue, text: "hi", seconds: 1),
                .repeatCycle(times: 3),
            ]).timeline()
        }
        #expect(throws: ExerciseScriptError.repeatCountOutOfRange(0)) {
            try ExerciseScript(steps: [
                .timed(phase: .inhale, text: "in", seconds: 2),
                .repeatCycle(times: 0),
            ]).timeline()
        }
        #expect(throws: ExerciseScriptError.nonPositiveDuration(0)) {
            try ExerciseScript(steps: [.timed(phase: .inhale, text: "in", seconds: 0)]).timeline()
        }
    }

    // MARK: Playback lookup

    @Test("beats are contiguous with no gap or overlap")
    func beatsAreContiguous() throws {
        let timeline = try ExerciseScript(json: Data(Self.seedJSON.utf8)).timeline()
        #expect(timeline.beats.first?.start == 0)
        for (a, b) in zip(timeline.beats, timeline.beats.dropFirst()) {
            #expect(a.end == b.start, "gap between beat \(a.id) and \(b.id)")
        }
    }

    @Test("lookup by elapsed time returns the right beat, and nil once finished")
    func lookup() throws {
        let timeline = try ExerciseScript(json: Data(Self.seedJSON.utf8)).timeline()

        #expect(timeline.beat(at: 0)?.phase == .cue)
        #expect(timeline.beat(at: 3.9)?.phase == .cue)
        #expect(timeline.beat(at: 4)?.phase == .inhale)      // boundary belongs to the next beat
        #expect(timeline.beat(at: 8)?.phase == .hold)
        #expect(timeline.beat(at: 10)?.phase == .exhale)
        #expect(timeline.beat(at: 55.9)?.phase == .cue)
        #expect(timeline.beat(at: 56) == nil, "at the end the player should finish")
        #expect(timeline.beat(at: 999) == nil)
        // Negative time clamps rather than crashing.
        #expect(timeline.beat(at: -1)?.phase == .cue)
    }

    @Test("progress is clamped to 0...1")
    func progress() throws {
        let timeline = try ExerciseScript(json: Data(Self.seedJSON.utf8)).timeline()
        #expect(timeline.progress(at: -5) == 0)
        #expect(timeline.progress(at: 28) == 0.5)
        #expect(timeline.progress(at: 56) == 1)
        #expect(timeline.progress(at: 900) == 1)
    }

    @Test("haptics fire on breath beats and stay silent during spoken cues")
    func hapticIntensities() {
        #expect(BreathPhase.cue.hapticIntensity == 0)
        #expect(BreathPhase.inhale.hapticIntensity > BreathPhase.exhale.hapticIntensity)
        #expect(BreathPhase.exhale.hapticIntensity > BreathPhase.hold.hapticIntensity)
        #expect(BreathPhase.hold.hapticIntensity > 0)
        #expect(!BreathPhase.cue.isBreath)
        #expect(BreathPhase.inhale.isBreath)
    }

    @Test("spokenGuide names empty breath beats and collapses repeats")
    func spokenGuide() {
        let script = ExerciseScript(steps: [
            .timed(phase: .cue, text: "Close your eyes.", seconds: 4),
            .timed(phase: .inhale, text: "", seconds: 4),
            .timed(phase: .exhale, text: "", seconds: 6),
            .repeatCycle(times: 3),
            .timed(phase: .cue, text: "Rest.", seconds: 3),
        ])
        let guide = script.spokenGuide
        #expect(guide.contains("Close your eyes. Wait 4 seconds."))
        #expect(guide.contains("Inhale. Wait 4 seconds."))
        #expect(guide.contains("Exhale. Wait 6 seconds."))
        #expect(guide.contains("Repeat that same breath cycle 2 more times"))
        #expect(guide.contains("Rest. Wait 3 seconds."))
        #expect(!guide.contains("Inhale. Wait 4 seconds.\nInhale."))
    }

    @Test("the bundled placeholder exercise is playable")
    func placeholderIsPlayable() throws {
        let timeline = try Exercise.placeholder.script.timeline()
        #expect(timeline.totalDuration > 0)
        #expect(Exercise.placeholder.tier == .free)
        // Named so it can never be mistaken for approved clinical content.
        #expect(Exercise.placeholder.title.lowercased().contains("placeholder"))
    }
}
