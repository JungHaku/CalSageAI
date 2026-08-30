import CalDesign
import CalKit
import CalVoice
import SwiftUI

/// The only home: Cal's orb in the centre, a top-right menu of destinations,
/// and the live transcript underneath.=
///
/// Taps and client tools share `SageRouter.path`. There is nothing behind this
/// screen — no Close, no tab bar. Backgrounding still stops the session (owned
/// in `RootView`).
///
/// Three things on this screen are not decoration:
///
/// - **The transcript.** A voice-only interface is unusable to anyone who cannot
///   hear and unverifiable to everyone else.
/// - **Emergency**, always present, never behind a network check.
/// - **The menu**, top-right, for every other screen. Voice-first is the default,
///   not a trap — type instead is in that menu too.
struct CalSageView: View {
    @Bindable var session: SageSession
    @Bindable var router: SageRouter

    @State private var presented: Sheet?

    private enum Sheet: Identifiable {
        case emergency
        case chat

        var id: Self { self }
    }

    private var model: VoiceRootViewModel { session.model }

    var body: some View {
        content(model)
            // Connect once from RootView — do not restart C.A.L. every time a
            // destination pops and this view reappears.
            .onChange(of: model.crisis) { _, severity in
                guard severity == .acute else { return }
                presented = .emergency
            }
            .sheet(item: $presented) { sheet in
                switch sheet {
                case .emergency:
                    EmergencyView()
                        .onDisappear { session.acknowledgeCrisis() }
                case .chat:
                    NavigationStack { ChatView() }
                }
            }
    }

    @ViewBuilder
    private func content(_ model: VoiceRootViewModel) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Keep the halo out from under the overlaid header, and out of
                // the status bar — that was the clipped-ring bug.
                Color.clear.frame(height: 44)
                Spacer(minLength: 0)
                cal(model)
                transcript(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                controls(model)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            header
                .padding(.horizontal)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    /// Emergency stays one tap, grouped with the trailing menu so the orb
    /// isn't flanked by chrome.
    private var header: some View {
        HStack {
            Spacer()

            Button {
                presented = .emergency
            } label: {
                Label("Emergency help", systemImage: "lifepreserver")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .tint(.red)
            .accessibilityIdentifier("emergency-button")

            Menu {
                Button {
                    presented = .chat
                } label: {
                    Label("Type instead", systemImage: "keyboard")
                }
                .accessibilityIdentifier("type-instead")

                Divider()

                Button {
                    router.open(.practices)
                } label: {
                    Label("Breathwork", systemImage: "wind")
                }
                .accessibilityIdentifier("dest-practices")

                Button {
                    router.open(.practice(slug: "study-reset", autoStart: true))
                } label: {
                    Label("Quick Reset", systemImage: "sparkles")
                }
                .accessibilityIdentifier("quick-reset")

                Button {
                    router.open(.study)
                } label: {
                    Label("Study", systemImage: "timer")
                }
                .accessibilityIdentifier("dest-study")

                Button {
                    router.open(.navigate(query: ""))
                } label: {
                    Label("Campus map", systemImage: "map")
                }
                .accessibilityIdentifier("dest-map")

                Button {
                    router.presentCheckInForm()
                } label: {
                    Label("Check in", systemImage: "checklist")
                }
                .accessibilityIdentifier("start-checkin")

                Divider()

                Button {
                    router.open(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("dest-settings")
            } label: {
                Label("Open menu", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("home-menu")
        }
    }

    // MARK: Cal

    @ViewBuilder
    private func cal(_ model: VoiceRootViewModel) -> some View {
        VStack(spacing: 12) {
            CalAvatar(.hero, halo: session.orbHalo, activity: session.orbActivity)
                .animation(.easeInOut(duration: 0.4), value: model.state)

            if model.failure == nil {
                Text(model.state.label)
                    .font(.headline)
                    .foregroundStyle(Surface.inkSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("voice-state")
            }

            suggestionChips(model)
        }
    }

    @ViewBuilder
    private func suggestionChips(_ model: VoiceRootViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Ask me a question") {
                    Task { await model.sendSuggestion("Ask me a question and I'll get an idea.") }
                }
                .accessibilityIdentifier("chip-ask")

                chip("Check in") {
                    router.presentCheckInForm()
                }
                .accessibilityIdentifier("chip-checkin")

                chip("Quick breath") {
                    router.open(.practice(slug: "study-reset", autoStart: true))
                }
                .accessibilityIdentifier("chip-breath")
            }
        }
        .accessibilityIdentifier("suggestion-chips")
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcript(_ model: VoiceRootViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                    if !model.partialStudent.isEmpty {
                        TurnRow(
                            turn: .init(speaker: .student, text: model.partialStudent),
                            isPartial: true
                        )
                        .id(Self.partialStudentID)
                    }
                    if !model.partialCal.isEmpty {
                        TurnRow(
                            turn: .init(speaker: .cal, text: model.partialCal),
                            isPartial: true
                        )
                        .id(Self.partialCalID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("voice-transcript")
            .onChange(of: model.turns.count) { _, _ in
                guard let last = model.turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.partialCal) { _, text in
                guard !text.isEmpty else { return }
                proxy.scrollTo(Self.partialCalID, anchor: .bottom)
            }
        }
    }

    private static let partialStudentID = "partial-student"
    private static let partialCalID = "partial-cal"

    // MARK: Controls

    @ViewBuilder
    private func controls(_ model: VoiceRootViewModel) -> some View {
        VStack(spacing: 12) {
            if let failure = model.failure {
                FailureCard(
                    failure: failure,
                    onRetry: failure.isWorthRetrying ? { Task { await model.restart() } } : nil,
                    onType: { presented = .chat }
                )
            } else if model.acceptsTextInput {
                if model.isLive {
                    HStack(spacing: 8) {
                        TextField("Message Cal", text: Binding(
                            get: { model.draft },
                            set: { model.draft = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { Task { await model.sendDraft() } }
                        .accessibilityIdentifier("voice-composer")

                        Button {
                            Task { await model.sendDraft() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("voice-send")
                    }

                    Button("End conversation", role: .destructive) {
                        Task { await model.stop() }
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("end-session")
                } else if case .ended = model.state {
                    Button {
                        Task { await model.restart() }
                    } label: {
                        Label("Message Cal", systemImage: "bubble.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("start-session")
                }
            } else {
                if model.isLive {
                    Button("End conversation", role: .destructive) {
                        Task { await model.stop() }
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("end-session")
                } else if case .ended = model.state {
                    Button {
                        Task { await model.restart() }
                    } label: {
                        Label("Talk to Cal", systemImage: "mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("start-session")
                }
            }
        }
    }
}

// MARK: - Rows

private struct TurnRow: View {
    let turn: VoiceRootViewModel.Turn
    var isPartial = false

    var body: some View {
        switch turn.speaker {
        case .student:
            Text(turn.text)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(isPartial ? Surface.inkSecondary : Surface.inkPrimary)
                .accessibilityLabel("You said: \(turn.text)")

        case .cal:
            Text(turn.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isPartial ? Surface.inkSecondary : Surface.inkPrimary)
                .accessibilityLabel("Cal said: \(turn.text)")

        case .action:
            Label(turn.text, systemImage: "arrow.turn.down.right")
                .font(.footnote)
                .foregroundStyle(Surface.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Cal: \(turn.text)")
        }
    }
}

private struct FailureCard: View {
    let failure: VoiceFailure
    let onRetry: (() -> Void)?
    let onType: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(VoiceFailureCopy.headline(for: failure))
                .font(.headline)
            Text(VoiceFailureCopy.body(for: failure))
                .font(.subheadline)
                .foregroundStyle(Surface.inkSecondary)

            HStack {
                if failure.isResolvedInSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("voice-retry")
                }
                Button("Type instead", action: onType)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Surface.card, in: .rect(cornerRadius: 14))
        .accessibilityIdentifier("voice-failure")
    }
}
