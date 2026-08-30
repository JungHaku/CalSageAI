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

    /// When true, present the check-in form sheet (startup or menu/chip).
    var showingCheckInForm = false

    private let content: any ContentRepository
    private let placeSearch: any PlaceSearching
    private let store: (any CoherenceStoring)?
    private let dates: any DateProvider
    /// Clinic suggestion throttle — once per local calendar day.
    private var lastClinicSuggestionDay: LocalDate?

    init(
        content: any ContentRepository,
        placeSearch: any PlaceSearching,
        store: (any CoherenceStoring)? = nil,
        dates: any DateProvider = SystemDateProvider(),
        practices: PracticeRunCoordinator = PracticeRunCoordinator()
    ) {
        self.content = content
        self.placeSearch = placeSearch
        self.store = store
        self.dates = dates
        self.practices = practices
    }

    /// Complete check-in for today — source of truth for the startup sheet.
    func hasCompletedCheckInToday() async -> Bool {
        guard let store else { return false }
        let today = dates.today
        let todays = ((try? await store.checkIns(from: today, to: today)) ?? [])
            .filter(\.isComplete)
        return !todays.isEmpty
    }

    func presentCheckInForm() {
        showingCheckInForm = true
    }

    func dismissCheckInForm() {
        showingCheckInForm = false
    }

    func perform(_ tool: CalTool) async -> ToolResult {
        switch tool {
        case .todayStatus:
            return await todayStatus()

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
            Never state a number about them that is not in this result. \
            Do not start a check-in — that is a form on the phone.
            """
        guard let store else {
            return .ok(
                """
                They have not finished a check-in today. If they ask about it, \
                point them to Check in in the menu. Do not run a spoken check-in.
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
                They have not finished a check-in today. If they ask about it, \
                point them to Check in in the menu. Do not run a spoken check-in.
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
        return .ok(
            """
            They already checked in today. Band: \(band).
            \(summary.promptText)
            \(numbersRule)
            """
        )
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
