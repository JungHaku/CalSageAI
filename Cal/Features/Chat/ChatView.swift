import CalAI
import CalDesign
import CalKit
import SwiftUI

/// "Chat with Cal".
///
/// Works today against `MockCoachClient` — no API key, no backend, no network.
/// The real client is an Edge Function behind the same `CoachClient` protocol
/// (Phase B step 7), and nothing on this screen changes when it arrives.
struct ChatView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: ChatViewModel?
    @State private var showingEmergency = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let model {
                conversation(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Chat with Cal")
        .task {
            if model == nil {
                model = ChatViewModel(
                    coach: container.coach, store: container.store, dates: container.dates
                )
            }
        }
        .sheet(isPresented: $showingEmergency) { EmergencyView() }
    }

    private func conversation(_ model: ChatViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    disclosure

                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if !model.streamingText.isEmpty {
                        MessageBubble(
                            message: CoachMessage(role: .assistant, text: model.streamingText),
                            isStreaming: true
                        )
                        .id(Self.streamingAnchor)
                    } else if model.isStreaming {
                        thinking
                    }

                    if model.crisis == .acute {
                        crisisCard(model).id(Self.crisisAnchor)
                    }
                    if model.failed { failureNotice }
                }
                .padding()
                // Clearance under the last item so the crisis card's bottom edge
                // isn't flush against the composer when scrolled fully down.
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in scroll(proxy, to: model) }
            // Follows the reply as it arrives. Bound to length rather than to the
            // string so it fires once per chunk rather than once per character.
            .onChange(of: model.streamingText.count) { _, _ in scroll(proxy, to: model) }
            // The crisis card is taller than a bubble and is appended *after* the
            // messages, so scrolling to the last message leaves its dismiss button
            // hidden behind the composer — which is exactly the control someone
            // who was misread needs to reach. Scroll to the card itself.
            .onChange(of: model.crisis) { _, severity in
                guard severity == .acute else { return }
                // Anchored to the card's TOP, not its bottom. `.bottom` aligns
                // with the scroll view's own bottom edge, which sits underneath
                // the composer's safe-area inset — so the card's last few points
                // stayed tucked behind it. From the top the whole card is visible,
                // dismiss control included.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.crisisAnchor, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer(model) }
    }

    private static let streamingAnchor = "streaming"
    private static let crisisAnchor = "crisis"

    private func scroll(_ proxy: ScrollViewProxy, to model: ChatViewModel) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !model.streamingText.isEmpty {
                proxy.scrollTo(Self.streamingAnchor, anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: Disclosure

    /// Cal says it is software, in the conversation, before anything else.
    ///
    /// California SB 243 requires a clear disclosure that the person is not
    /// talking to a human, and App Store guideline 1.4.1 wants a wellness app to
    /// point at real care rather than imply it provides it. Both are satisfied by
    /// saying so plainly and permanently at the top of the thread rather than in a
    /// one-time alert somebody dismisses and forgets.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cal is AI, not a person", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))
            Text(
                """
                It can help you notice patterns and settle your nervous system. It \
                is not therapy or medical care. If something is urgent, use \
                Emergency help — it works offline.
                """
            )
            .font(.footnote)
            .foregroundStyle(Surface.inkSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-ai-disclosure")
    }

    // MARK: Crisis

    /// Layer D. The model has been suppressed and this is what replaces it.
    ///
    /// It does not invent new crisis copy: it routes to `EmergencyView`, the
    /// surface that already carries the verified 988 call, text and chat options
    /// and works with no network. One considered crisis surface, reached from
    /// everywhere, beats two that can drift apart.
    ///
    /// The conversation is **not** ended and the card is dismissible. Someone who
    /// was misread — "this exam is killing me" will trip an on-device keyword
    /// filter — must not find the app has locked them out of the thing they opened
    /// it for.
    private func crisisCard(_ model: ChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Support is available right now", systemImage: "lifepreserver.fill")
                .font(.headline)

            Text(
                """
                It sounds like this is really heavy. Cal isn't the right help for \
                this — a person is. Talking to someone is free, confidential, and \
                available any hour.
                """
            )
            .font(.subheadline)

            Button {
                showingEmergency = true
            } label: {
                Label("Talk to someone now", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("crisis-get-help")

            Button("Not what I meant") { model.acknowledgeCrisis() }
                .font(.subheadline)
                .frame(minHeight: 44)
                .accessibilityIdentifier("crisis-dismiss")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CoherenceScale.textTint(for: .low), lineWidth: 2)
        )
        .accessibilityIdentifier("crisis-card")
    }

    private var failureNotice: some View {
        Label("That didn't send. Try again in a moment.", systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Surface.inkSecondary)
            .accessibilityIdentifier("chat-failed")
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Cal is thinking…").font(.footnote).foregroundStyle(Surface.inkSecondary)
        }
        .accessibilityIdentifier("chat-thinking")
    }

    // MARK: Composer

    private func composer(_ model: ChatViewModel) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("What's going on?", text: Binding(
                get: { model.draft },
                set: { model.draft = $0 }
            ), axis: .vertical)
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Surface.card, in: .capsule)
            .focused($composerFocused)
            .accessibilityIdentifier("chat-input")

            Button {
                composerFocused = false
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat-send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: CoachMessage
    var isStreaming = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            // Cal writes markdown; SwiftUI does not interpret it for a String
            // variable. See `CoachMarkdown` for why, and for why the whitespace
            // option matters to a line-by-line practice script.
            Text(CoachMarkdown.rendered(message.text))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(background, in: .rect(cornerRadius: 18))
                .foregroundStyle(message.role == .user ? Color.white : Surface.inkPrimary)
                // VoiceOver would otherwise re-announce the whole reply on every
                // token as the label changes. `.updatesFrequently` tells it this
                // is a live region and to stop interrupting itself.
                .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
                // Spoken from the stripped text, so VoiceOver doesn't read the
                // markup out as "star star Thursday star star".
                .accessibilityLabel(
                    message.role == .user
                        ? "You said: \(CoachMarkdown.plain(message.text))"
                        : "Cal said: \(CoachMarkdown.plain(message.text))"
                )

            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .accessibilityIdentifier(message.role == .user ? "chat-user-message" : "chat-cal-message")
    }

    private var background: Color {
        message.role == .user ? ChartPalette.primary : Surface.card
    }
}

#Preview("conversation") {
    NavigationStack { ChatView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
