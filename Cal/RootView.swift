import CalDesign
import CalKit
import CalStore
import SwiftUI

/// The five tabs from Dr. Mia's spec, plus the Emergency affordance that must be
/// reachable in one tap from every screen (ARCHITECTURE.md §1, §9.2 Layer D).
///
/// Phase 0 ships the shell and the navigation contract; the tabs themselves are
/// built in Phases 1–4 (§19). Each placeholder names its phase so nobody mistakes
/// it for something that's finished.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selection: Tab = .home
    @State private var showingEmergency = false

    enum Tab: String, Hashable, CaseIterable {
        /// Declaration order **is** the tab bar's order — `allCases` drives the
        /// `ForEach` below.
        ///
        /// Check-In sits in the middle of the five deliberately: it is the thing
        /// the app is for, and the centre of a five-tab bar is the easiest target
        /// to hit with either thumb. Navigate takes second, where Check-In was.
        ///
        /// Note this is not the order in Dr. Mia's spec (§1). The *set* of five is
        /// hers; the arrangement is ours, and she should be told it moved.
        case home, navigate, checkIn, planner, chat

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
        // Not gated — *routed*. Free gets Dr. Mia's single-question check-in from
        // `SPEC-free.md` §1, premium the ten-category framework. Both regulate a
        // low score into guided breathing, so nobody is locked out of the part
        // that helps (`PremiumFeature.neverGated`).
        case .checkIn: CheckInView(kind: container.premium.checkInKind)
        case .home:
            HomeView()
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .checkIn: CheckInView(kind: container.premium.checkInKind)
                    case .practices:
                        PremiumGate(feature: .practiceLibrary) { PracticesLibraryView() }
                    case .progress:
                        PremiumGate(feature: .coherenceAnalytics) { AnalyticsView() }
                    case .study: StudyTimerView()
                    // Never gated: this is the person's own data (§ Entitlement).
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    case .premium: PaywallView()
                    }
                }
        case .navigate: NavigateView()
        case .planner:  PlannerView()
        case .chat:     ChatView()
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
