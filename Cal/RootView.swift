import CalDesign
import CalKit
import SwiftUI

/// The five tabs from Dr. Mia's spec, plus the Emergency affordance that must be
/// reachable in one tap from every screen (ARCHITECTURE.md §1, §9.2 Layer D).
///
/// Phase 0 ships the shell and the navigation contract; the tabs themselves are
/// built in Phases 1–4 (§19). Each placeholder names its phase so nobody mistakes
/// it for something that's finished.
struct RootView: View {
    @State private var selection: Tab = .home
    @State private var showingEmergency = false

    enum Tab: String, Hashable, CaseIterable {
        case home, checkIn, navigate, planner, chat

        var title: String {
            switch self {
            case .home: "Home"
            case .checkIn: "Check-In"
            case .navigate: "Navigate"
            case .planner: "Planner"
            case .chat: "Chat with Cal"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .checkIn: "brain.head.profile"
            case .navigate: "map"
            case .planner: "calendar"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases, id: \.self) { tab in
                NavigationStack {
                    content(for: tab)
                        .navigationTitle(tab.title)
                        .toolbar { emergencyToolbarItem }
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
            }
        }
        .sheet(isPresented: $showingEmergency) {
            EmergencyView()
        }
    }

    @ToolbarContentBuilder
    private var emergencyToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingEmergency = true
            } label: {
                Label("Emergency help", systemImage: "lifepreserver")
            }
            .tint(.red)
            .accessibilityIdentifier("emergency-button")
        }
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        // The ten-question flow. Which tier a user gets is an entitlement
        // question, and entitlements are Phase 5 — until then everyone sees the
        // full framework, which is the part worth getting right.
        case .checkIn: CheckInView(kind: .full)
        case .home:
            HomeView()
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .checkIn: CheckInView(kind: .full)
                    case .practices: PracticesLibraryView()
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    }
                }
        case .navigate: PhasePlaceholder(feature: "Campus map and Navigate", phase: 4)
        case .planner:  PhasePlaceholder(feature: "Today's schedule", phase: 4)
        case .chat:     PhasePlaceholder(feature: "Chat with Cal", phase: 3)
        }
    }
}

private struct PhasePlaceholder: View {
    let feature: String
    let phase: Int

    var body: some View {
        ContentUnavailableView {
            Label(feature, systemImage: "hammer")
        } description: {
            Text("Built in Phase \(phase). See ARCHITECTURE.md §19.")
        }
    }
}

#Preview("shell") {
    RootView().environment(AppContainer.live(arguments: []))
}

#Preview("seeded 30-day streak") {
    RootView().environment(
        AppContainer.live(arguments: ["-CalScenario", "day30Streak", "-CalFixedDate", "2026-07-29"])
    )
}
