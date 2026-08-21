import CalKit
import SwiftUI

/// Screens Cal (or a home card) can push on the voice stack.
///
/// Kept as its own view so `CalSageView` stays the home chrome and destinations
/// stay one switch. Hub screens (`HomeView`, `ToolsHubView`, `YouView`) are not
/// roots anymore; they are unused files, not deleted.
struct VoiceRouteDestination: View {
    let route: VoiceRoute

    var body: some View {
        switch route {
        case .practice(let slug, let autoStart):
            PracticeDetailView(slug: slug, autoStart: autoStart)
        case .practices:
            PracticesLibraryView()
        case .navigate(let query):
            NavigateView(initialQuery: query)
        case .planner:
            PlannerView()
        case .study:
            StudyTimerView()
        case .settings:
            SettingsView()
        case .premium:
            PaywallView()
        case .journal:
            JournalHubView()
        case .journalCompose(let promptID):
            JournalEditorView(promptID: promptID)
        case .journalEntry(let id):
            JournalEditorView(entryID: id)
        }
    }
}
