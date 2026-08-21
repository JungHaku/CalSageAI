import CalContent
import CalData
import CalKit
import CalVoice
import Foundation
import Observation
import SwiftUI

/// Everywhere Cal can send you.
///
/// A typed path rather than `NavigationPath`, so the router can *read* the stack
/// — `stop_practice` has to know whether a practice is what's on top, and a
/// type-erased path cannot answer that.
enum VoiceRoute: Hashable {
    /// Guided practice. `autoStart` is true when Cal opened it (`play_practice`);
    /// false when the student opened it from Tools / Today themselves.
    case practice(slug: String, autoStart: Bool)
    case practices
    case navigate(query: String)
    case planner
    case study
    case settings
    case premium
    /// Journal hub (free write + prompts). Compose and entry sit on top of this.
    case journal
    /// New free-write or prompted entry (`promptID` nil = free write).
    case journalCompose(promptID: String?)
    /// Open an existing journal entry by id.
    case journalEntry(UUID)
}

/// The thing that moves the screen when Cal decides to.
@Observable
@MainActor
final class SageRouter: CalToolPerforming {
    /// Screens pushed on top of the voice home. Empty = looking at Cal.
    var path: [VoiceRoute] = []

    /// Single owner of an awaited `play_practice` run.
    let practices: PracticeRunCoordinator

    /// Spoken check-in in progress. Nil when idle or complete.
    private(set) var checkInFlow: CheckInFlow?

    /// Prompt for the current check-in step — shown under the orb for sighted /
    /// VoiceOver users while Cal asks out loud.
    var checkInPrompt: String? {
        guard let flow = checkInFlow else { return nil }
        switch flow.step {
        case .rating(let q): return q.prompt
        case .reRating(let q): return q.rePrompt
        case .regulation: return "A short regulation when you're ready."
        case .complete: return nil
        }
    }

    var checkInProgress: (answered: Int, total: Int)? {
        guard let flow = checkInFlow, !flow.isComplete else { return nil }
        return flow.progress
    }

    private let content: any ContentRepository
    private let placeSearch: any PlaceSearching
    private let store: (any CoherenceStoring)?
    private let dates: any DateProvider
    private let remember: (@MainActor @Sendable (String) -> Void)?
    /// Clinic suggestion throttle — once per local calendar day.
    private var lastClinicSuggestionDay: LocalDate?

    init(
        content: any ContentRepository,
        placeSearch: any PlaceSearching,
        store: (any CoherenceStoring)? = nil,
        dates: any DateProvider = SystemDateProvider(),
        practices: PracticeRunCoordinator = PracticeRunCoordinator(),
        remember: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.content = content
        self.placeSearch = placeSearch
        self.store = store
        self.dates = dates
        self.practices = practices
        self.remember = remember
    }

    func perform(_ tool: CalTool) async -> ToolResult {
        switch tool {
        case .todayStatus:
            return await todayStatus()

        case .startCheckIn:
            return await startCheckIn()

        case .recordScore(let value):
            return await recordScore(value)

        case .skipRegulation:
            return await skipRegulation()

        case .continueCheckIn:
            return await continueCheckIn()

        case .playPractice(let slug):
            return await playPractice(slug)

        case .stopPractice:
            return stopPractice()

        case .showPlace(let query):
            return await showPlace(query)

        case .openScreen(let screen):
            push(route(for: screen))
            return .ok(
                screen == .map
                    ? "Opened the Berkeley campus map."
                    : "Opened \(screen.rawValue)."
            )

        case .endSession:
            return .ok("Ending the conversation.")
        }
    }

    // MARK: Spoken check-in

    private func startCheckIn() async -> ToolResult {
        if let store {
            let today = dates.today
            let existing = (try? await store.checkIns(from: today, to: today))?
                .filter(\.isComplete) ?? []
            if !existing.isEmpty {
                return .ok(
                    """
                    They already finished today's check-in. Do not start another. \
                    Open from how that check-in went, or just listen.
                    """
                )
            }
        }

        var copy = CoherenceQuestion.seed
        if let questions = try? await content.questions() {
            copy = questions
        }
        var exercises: [CoherenceCategory: String] = [:]
        for category in CheckInKind.full.categories {
            if let exercise = try? await content.exercise(for: category) {
                exercises[category] = exercise.slug
            }
        }

        let flow = CheckInFlow(
            kind: .full,
            localDate: dates.today,
            timeZoneIdentifier: dates.calendar.timeZone.identifier,
            copy: copy,
            exercises: exercises
        )
        checkInFlow = flow
        return .ok(describeStep(flow))
    }

    private func recordScore(_ value: Int) async -> ToolResult {
        guard var flow = checkInFlow else {
            return .failure("No check-in is in progress. Call start_check_in first.")
        }
        let score = Score(clamping: value)
        switch flow.step {
        case .rating:
            flow.submitRating(score, now: dates.now)
        case .reRating:
            flow.submitReRating(score, now: dates.now)
        default:
            return .failure("Waiting for a regulation to finish or be skipped, not a score.")
        }
        checkInFlow = flow
        await persistCheckIn()
        if flow.isComplete {
            return await finishCheckIn()
        }
        return .ok(describeStep(flow))
    }

    private func skipRegulation() async -> ToolResult {
        guard var flow = checkInFlow else {
            return .failure("No check-in is in progress.")
        }
        guard case .regulation = flow.step else {
            return .failure("Nothing to skip — they are not in a regulation step.")
        }
        flow.skipRegulation(now: dates.now)
        checkInFlow = flow
        await persistCheckIn()
        if flow.isComplete {
            return await finishCheckIn()
        }
        return .ok(describeStep(flow))
    }

    private func continueCheckIn() async -> ToolResult {
        guard var flow = checkInFlow else {
            return .failure("No check-in is in progress.")
        }
        guard case .regulation = flow.step else {
            return .failure("Call continue_check_in only after a regulation practice.")
        }
        flow.completeRegulation()
        checkInFlow = flow
        return .ok(describeStep(flow))
    }

    private func describeStep(_ flow: CheckInFlow) -> String {
        switch flow.step {
        case .rating(let q):
            let (answered, total) = flow.progress
            return """
                Ask this out loud, then wait for a number 0–10. Do not paraphrase.
                Question \(answered + 1) of \(total) (\(q.category.rawValue)):
                \(q.prompt)
                """
        case .reRating(let q):
            return """
                Ask this re-prompt out loud, then wait for a number 0–10:
                \(q.rePrompt)
                """
        case .regulation(_, let slug):
            return """
                Their score was low. Offer a short regulation. Call play_practice \
                with slug '\(slug)' (or another basic breath if that slug fails). \
                After it ends, call continue_check_in. If they decline, call \
                skip_regulation.
                """
        case .complete:
            return "Check-in is complete."
        }
    }

    private func finishCheckIn() async -> ToolResult {
        guard let flow = checkInFlow, flow.isComplete else {
            return .failure("Check-in is not complete yet.")
        }
        await persistCheckIn()
        let checkIn = flow.checkIn
        let parts = checkIn.scores.map {
            "\($0.category.displayName.lowercased()) \($0.effective.value)"
        }.joined(separator: ", ")
        let avg = checkIn.averageAfter.map { String(format: "%.1f", $0) } ?? "unknown"
        remember?(
            "Daily check-in \(checkIn.localDate.iso): \(parts). Average \(avg)."
        )
        checkInFlow = nil
        let band: String = {
            guard let avg = checkIn.averageAfter else { return "moderate" }
            if avg >= 8 { return "high" }
            if avg >= 5 { return "moderate" }
            return "low"
        }()
        return .ok(
            """
            Check-in saved. Average \(avg) (\(band)). Thank them briefly, then \
            listen. Scores: \(parts).
            """
        )
    }

    private func persistCheckIn() async {
        guard let flow = checkInFlow, let store else { return }
        try? await store.save(flow.checkIn)
    }

    // MARK: Practices

    private func playPractice(_ slug: String) async -> ToolResult {
        guard let exercise = try? await content.exercise(slug: slug) else {
            return .failure("There is no practice called '\(slug)'.")
        }
        push(.practice(slug: slug, autoStart: true))
        Task {
            let outcome = await self.practices.begin(slug: slug)
            self.popPracticeIfPresent()
            _ = outcome
        }
        var spins = 0
        while !practices.isRunning, spins < 80 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        return .ok(
            """
            The practice '\(exercise.title)' is on screen. Speak this script now, \
            exactly, so they can follow with their eyes closed. Do not add lines \
            or ask questions until the last wait is over.

            \(exercise.script.spokenGuide)
            """
        )
    }

    private func stopPractice() -> ToolResult {
        guard practices.isRunning || isPracticeOnStack else {
            return .failure("No practice is running.")
        }
        practices.requestStop()
        popPracticeIfPresent()
        return .ok("Stopped the practice.")
    }

    private var isPracticeOnStack: Bool {
        if case .practice = path.last { return true }
        return false
    }

    private func popPracticeIfPresent() {
        guard case .practice = path.last else { return }
        path.removeLast()
    }

    // MARK: Grounding

    private func todayStatus() async -> ToolResult {
        let today = dates.today
        let numbersRule = """
            Never state a number about them that is not in this result.
            """
        guard let store else {
            return .ok(
                """
                They have not finished a check-in today. Say "Check in today", \
                call start_check_in, then ask the first question it returns.
                \(numbersRule)
                """
            )
        }
        let windowStart = today.adding(days: -30, in: dates.calendar)
        let history = (try? await store.checkIns(from: windowStart, to: today)) ?? []
        let completedToday = history.filter { $0.localDate == today && $0.isComplete }
        if completedToday.isEmpty {
            return .ok(
                """
                They have not finished a check-in today. Say "Check in today", \
                call start_check_in, then ask the first question it returns.
                \(numbersRule)
                """
            )
        }
        let summary = CoherenceSummary.build(
            history: history, today: today, calendar: dates.calendar
        )
        let avg = completedToday.compactMap(\.averageAfter).first
        let band: String = {
            guard let avg else { return "moderate" }
            if avg >= 8 { return "high" }
            if avg >= 5 { return "moderate" }
            return "low"
        }()
        let openerHint: String = switch band {
        case "high":
            "Open warmly — seems like they're having a good day — then listen."
        case "low":
            "Open gently — you're with them — then listen. Offer a breath if it fits."
        default:
            "Open simply — ask how the rest of the day is going — then listen."
        }
        return .ok(
            """
            They already checked in today. Band: \(band).
            \(summary.promptText)
            \(openerHint)
            \(numbersRule)
            """
        )
    }

    /// First spoken line for a new session (`{{session_opener}}`).
    func sessionOpener() async -> String {
        guard let store else { return "Check in today." }
        let today = dates.today
        let todays = ((try? await store.checkIns(from: today, to: today)) ?? [])
            .filter(\.isComplete)
        guard let checkIn = todays.last, let avg = checkIn.averageAfter else {
            return "Check in today."
        }
        if avg >= 8 {
            return "Seems like you're having a great day. What's on your mind?"
        }
        if avg >= 5 {
            return "How's the rest of today feeling?"
        }
        return "I'm here with you. What's been the hardest part today?"
    }

    // MARK: Places

    private func showPlace(_ query: String) async -> ToolResult {
        if Self.isBareMapRequest(query) {
            push(.navigate(query: ""))
            return .ok("Opened the Berkeley campus map.")
        }

        let clinic = Self.isClinicSymptomQuery(query)
        if clinic {
            if lastClinicSuggestionDay == dates.today {
                return .ok(
                    """
                    You already suggested Breathe Health Center today. Do not \
                    suggest it again. Offer a breath or just listen instead.
                    """
                )
            }
            lastClinicSuggestionDay = dates.today
            push(.navigate(query: "Breathe Health Center"))
            return .ok(
                """
                Showing Breathe Health Center on the map. Mention it once, briefly. \
                Do not diagnose. If they are in crisis, stop and point to Emergency help.
                """
            )
        }

        let all = ((try? CampusPlaceSeed.load()) ?? [])
        guard !all.isEmpty else {
            return .failure("The campus map isn't available.")
        }
        let matches = await placeSearch.search(query, in: all)
        guard let best = matches.first else {
            return .failure("Nothing on campus matched '\(query)'.")
        }
        push(.navigate(query: query))
        return .ok(
            matches.count == 1
                ? "Showing \(best.name) on the map."
                : "Showing \(matches.count) matches for '\(query)', starting with \(best.name)."
        )
    }

    private static func isBareMapRequest(_ query: String) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        let bare: Set<String> = [
            "map", "the map", "campus", "the campus", "campus map",
            "the campus map", "berkeley", "berkeley map", "uc berkeley",
            "navigate", "navigation",
        ]
        return bare.contains(normalized)
    }

    private static func isClinicSymptomQuery(_ query: String) -> Bool {
        let q = query.lowercased()
        let keys = [
            "headache", "migraine", "depression", "depressed", "anxiety",
            "anxious", "body pain", "pain in my body", "lethargic", "lethargy",
            "breathe health", "breathe health center",
        ]
        return keys.contains { q.contains($0) }
    }

    private func push(_ route: VoiceRoute) {
        open(route)
    }

    func open(_ route: VoiceRoute) {
        if path.last != route {
            path.append(route)
        }
    }

    private func route(for screen: CalScreen) -> VoiceRoute {
        switch screen {
        case .practices: .practices
        case .settings:  .settings
        case .map:       .navigate(query: "")
        case .study:     .study
        }
    }

    func popToRoot() {
        path = []
    }
}

typealias VoiceRouter = SageRouter
