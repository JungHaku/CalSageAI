import Foundation
import Testing

@testable import CalKit

@Suite("StudySession")
struct StudySessionTests {
    let start = Date(timeIntervalSince1970: 1_785_000_000)

    private func session(_ length: StudySession.Length = .short) -> StudySession {
        StudySession(length: length, startedAt: start)
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("the three lengths are the spec's 25, 50 and 90 minutes")
    func lengths() {
        #expect(StudySession.Length.allCases.map(\.minutes) == [25, 50, 90])
        #expect(StudySession.Length.short.duration == 1500)
        #expect(StudySession.Length.long.duration == 5400)
    }

    @Test("a session starts in focus and stays there until the block ends")
    func focusPhase() {
        let s = session()
        #expect(s.phase(at: start) == .focus)
        #expect(s.phase(at: at(60)) == .focus)
        #expect(s.phase(at: at(1499)) == .focus)
    }

    // The reset is not optional in her spec — "every session ends with" it — so
    // the timer routes into it rather than just stopping.
    @Test("focus rolls straight into the 30-second reset")
    func resetPhase() {
        let s = session()
        #expect(s.phase(at: at(1500)) == .reset)
        #expect(s.phase(at: at(1520)) == .reset)
        #expect(s.phase(at: at(1529)) == .reset)
    }

    @Test("the session finishes after focus plus the reset")
    func finished() {
        let s = session()
        #expect(s.phase(at: at(1530)) == .finished)
        #expect(s.phase(at: at(9999)) == .finished)
    }

    @Test("remaining counts down within the current phase and never goes negative")
    func remaining() {
        let s = session()
        #expect(s.remaining(at: start) == 1500)
        #expect(s.remaining(at: at(500)) == 1000)
        #expect(s.remaining(at: at(1500)) == 30, "the reset has its own countdown")
        #expect(s.remaining(at: at(1515)) == 15)
        #expect(s.remaining(at: at(9999)) == 0)
    }

    // A clock that jumps backwards — a manual time change, an NTP correction —
    // must not produce a negative timer or a session that un-finishes.
    @Test("a backwards clock is clamped rather than producing negative time")
    func backwardsClock() {
        let s = session()
        #expect(s.elapsed(at: at(-500)) == 0)
        #expect(s.remaining(at: at(-500)) == 1500)
        #expect(s.phase(at: at(-500)) == .focus)
    }

    @Test("focus progress is pinned at 1 during the reset, so a ring doesn't wrap")
    func focusProgress() {
        let s = session()
        #expect(s.focusProgress(at: start) == 0)
        #expect(s.focusProgress(at: at(750)) == 0.5)
        #expect(s.focusProgress(at: at(1500)) == 1)
        #expect(s.focusProgress(at: at(1520)) == 1)
    }

    @Test("the countdown label rounds up, so it never shows 0:00 while time remains")
    func remainingLabel() {
        let s = session()
        #expect(s.remainingLabel(at: start) == "25:00")
        #expect(s.remainingLabel(at: at(0.5)) == "25:00")
        #expect(s.remainingLabel(at: at(1499.5)) == "0:01")
        #expect(s.remainingLabel(at: at(1500)) == "0:30")
        #expect(s.remainingLabel(at: at(9999)) == "0:00")
    }

    @Test("each length reaches its own reset boundary", arguments: StudySession.Length.allCases)
    func boundariesPerLength(_ length: StudySession.Length) {
        let s = session(length)
        #expect(s.phase(at: at(length.duration - 1)) == .focus)
        #expect(s.phase(at: at(length.duration)) == .reset)
        #expect(s.phase(at: at(length.duration + StudySession.resetDuration)) == .finished)
    }
}
