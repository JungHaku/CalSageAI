import Foundation
import Testing

@testable import CalKit

@Suite("PracticeSession")
struct PracticeSessionTests {
    let day = LocalDate(iso: "2026-07-30")!
    let start = Date(timeIntervalSince1970: 1_785_000_000)

    private func session(
        _ slug: String = "presence-of-light",
        completed: Bool = false,
        progress: Double = 0,
        checkIn: UUID? = nil
    ) -> PracticeSession {
        PracticeSession(
            exerciseSlug: slug,
            localDate: day,
            startedAt: start,
            completedAt: completed ? start.addingTimeInterval(82) : nil,
            progress: completed ? 1 : progress,
            checkInID: checkIn
        )
    }

    @Test("a new session is incomplete and self-initiated")
    func newSession() {
        let s = session()
        #expect(!s.wasCompleted)
        #expect(s.wasSelfInitiated)
        #expect(s.elapsed == nil)
    }

    @Test("a session started from a check-in is linked to it, not self-initiated")
    func linkedToCheckIn() {
        let checkInID = UUID()
        let s = session(checkIn: checkInID)
        #expect(!s.wasSelfInitiated)
        #expect(s.checkInID == checkInID)
    }

    @Test("finishing sets the timestamp and pins progress to 1")
    func finish() {
        var s = session(progress: 0.4)
        s.finish(at: start.addingTimeInterval(120))
        #expect(s.wasCompleted)
        #expect(s.progress == 1)
        #expect(s.elapsed == 120)
    }

    // Abandonment is the honest pacing signal — a run quit 40 seconds in has to
    // survive as data, not be discarded as a non-event.
    @Test("abandoning keeps the progress reached and leaves the session incomplete")
    func abandon() {
        var s = session()
        s.abandon(atProgress: 0.42)
        #expect(!s.wasCompleted)
        #expect(abs(s.progress - 0.42) < 0.0001)
    }

    @Test("progress is clamped to 0...1 on every path")
    func progressClamped() {
        #expect(session(progress: -3).progress == 0)
        #expect(session(progress: 9).progress == 1)

        var s = session()
        s.abandon(atProgress: 4)
        #expect(s.progress == 1)
        s.abandon(atProgress: -1)
        #expect(s.progress == 0)
    }

    @Test("completion rate reflects finished runs, and is nil for an unrun practice")
    func completionRate() {
        let runs = [
            session("a", completed: true),
            session("a", completed: true),
            session("a", progress: 0.3),
            session("b", progress: 0.1),
        ]
        #expect(runs.completionRate(for: "a").map { abs($0 - 2.0 / 3.0) < 0.0001 } == true)
        #expect(runs.completionRate(for: "b") == 0)
        #expect(runs.completionRate(for: "never-run") == nil)
    }

    /// The pacing review queue: worst completion first, so the practice most
    /// likely to be mistimed is the one Dr. Mia looks at first (§17 question 5).
    @Test("practices sort worst-completion-first")
    func reviewQueue() {
        let runs = [
            session("good", completed: true),
            session("good", completed: true),
            session("bad", progress: 0.2),
            session("bad", progress: 0.4),
            session("mixed", completed: true),
            session("mixed", progress: 0.5),
        ]
        #expect(runs.slugsByCompletionRate().map(\.slug) == ["bad", "mixed", "good"])
    }

    @Test("an empty history produces an empty queue rather than a crash")
    func emptyQueue() {
        #expect([PracticeSession]().slugsByCompletionRate().isEmpty)
    }
}

@Suite("Exercise metadata")
struct ExerciseMetadataTests {
    @Test("duration is derived from the timeline, so it can't drift from the script")
    func durationMatchesTimeline() throws {
        let expected = try Exercise.placeholder.script.timeline().totalDuration
        #expect(Exercise.placeholder.duration == expected)
    }

    @Test("a malformed script yields no duration rather than crashing a list row")
    func malformedScriptHasNoDuration() {
        let broken = Exercise(
            slug: "broken", title: "Broken", category: nil, tier: .free,
            script: ExerciseScript(steps: [.repeatCycle(times: 3)])
        )
        #expect(broken.duration == nil)
    }

    @Test("purpose is optional, so a payload without it still decodes")
    func purposeIsOptional() throws {
        let json = #"""
        {"slug":"x","title":"X","category":null,"tier":"free","version":1,
         "script":{"steps":[{"kind":"cue","text":"hi","seconds":3}]}}
        """#
        let decoded = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(decoded.purpose == nil)
        #expect(decoded.slug == "x")
    }
}
