import CalData
import CalDesign
import CalKit
import CalStore
import SwiftUI

/// Hosts the voice home once there is a session. Until then, the login gate.
///
/// Same rule everywhere: stored session → Cal, else login. `isUITesting` does
/// not bypass this. Tests that need the orb seed a dummy session in the token
/// store the same way a returning student restores from the Keychain.
///
/// Sage is created only after sign-in so ElevenLabs does not connect on the
/// login screen. Sign-out hangs up and returns here.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase

    @State private var router: SageRouter?
    @State private var session: SageSession?
    @State private var welcome: WelcomeState = .unknown

    private enum WelcomeState {
        case unknown
        case needed
        case done
    }

    var body: some View {
        Group {
            if !container.hasSession {
                LoginGateView()
            } else if welcome == .needed {
                WelcomeView(kind: .firstSession) {
                    Task { await finishWelcome() }
                }
            } else if welcome == .done, let router, let session {
                RootNavigation(router: router, session: session)
                    .environment(router)
                    .environment(router.practices)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.appBackground.ignoresSafeArea())
        .task(id: container.hasSession) {
            if container.hasSession {
                await resolveWelcome()
            } else {
                welcome = .unknown
                await stopSage()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, let session else { return }
            Task { await session.stop() }
        }
    }

    private func resolveWelcome() async {
        let onboarded = (try? await container.profiles.current())?.isOnboarded ?? false
        if onboarded {
            welcome = .done
            startSageIfNeeded()
        } else {
            welcome = .needed
        }
    }

    private func finishWelcome() async {
        await container.completeOnboarding()
        welcome = .done
        startSageIfNeeded()
    }

    /// Creates sage + router but does **not** connect voice yet — RootNavigation
    /// waits for today's check-in form (if needed) first.
    private func startSageIfNeeded() {
        guard session == nil else { return }
        let created = SageRouter(
            content: container.content,
            placeSearch: container.placeSearch,
            store: container.store,
            dates: container.dates
        )
        let sage = SageSession(
            makeSession: container.makeVoiceSession,
            router: created,
            remember: { text, severity in
                Task {
                    guard AppContainer.loadMemoryConsent().permitsRemoteMemory else { return }
                    await container.remoteMemory.remember(text: text, severity: severity)
                }
            }
        )
        router = created
        session = sage
    }

    private func stopSage() async {
        await session?.stop()
        session = nil
        router = nil
    }
}

private struct RootNavigation: View {
    @Environment(AppContainer.self) private var container
    @Bindable var router: SageRouter
    @Bindable var session: SageSession
    @State private var showingEmergency = false
    @State private var voiceGateResolved = false

    var body: some View {
        NavigationStack(path: $router.path) {
            CalSageView(session: session, router: router)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: VoiceRoute.self) { route in
                    VoiceRouteDestination(route: route)
                        .toolbar { emergencyToolbarItem }
                }
        }
        .sheet(isPresented: $router.showingCheckInForm, onDismiss: {
            finishVoiceGateIfNeeded()
        }) {
            NavigationStack {
                CheckInView(kind: .full) {
                    router.dismissCheckInForm()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") {
                            router.dismissCheckInForm()
                        }
                        .accessibilityIdentifier("checkin-dismiss")
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showingEmergency) {
            EmergencyView()
                .onDisappear { session.acknowledgeCrisis() }
        }
        .onChange(of: session.crisis) { _, severity in
            guard severity == .acute, !router.path.isEmpty else { return }
            showingEmergency = true
        }
        .task {
            await resolveVoiceGate()
        }
    }

    /// If they have not finished today's check-in, show the form first; only
    /// then connect the voice agent so it waits quietly for them.
    private func resolveVoiceGate() async {
        guard !voiceGateResolved else { return }
        let checkedIn = await router.hasCompletedCheckInToday()
        if checkedIn {
            voiceGateResolved = true
            session.connectIfNeeded()
        } else {
            router.presentCheckInForm()
        }
    }

    private func finishVoiceGateIfNeeded() {
        guard !voiceGateResolved else { return }
        voiceGateResolved = true
        session.connectIfNeeded()
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
}

#Preview {
    RootView()
        .environment(AppContainer.live(arguments: [
            "-CalUseMockCoach", "1", "-CalVoiceScript", "greeting",
            "-CalScenario", "empty",
        ]))
}
