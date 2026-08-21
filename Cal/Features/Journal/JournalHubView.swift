import CalData
import CalDesign
import CalKit
import SwiftUI

/// JOURNAL tab root (`PLAN-journal.md`): free write, guided prompts, history.
///
/// Local only in this pass — no AI reflection. Entries are the student's data
/// and are never gated. Navigation uses `VoiceRoute` on the shell stack.
struct JournalHubView: View {
    @Environment(AppContainer.self) private var container
    @State private var entries: [JournalEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Write freely, or start from a prompt. Your words stay on this device until you export them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                freeWrite

                guidedPrompts

                if !entries.isEmpty {
                    history
                }
            }
            .padding()
        }
        .navigationTitle("Journal")
        .accessibilityIdentifier("journal-root")
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private var freeWrite: some View {
        NavigationLink(value: VoiceRoute.journalCompose(promptID: nil)) {
            Label("Free write", systemImage: "square.and.pencil")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("journal-free-write")
    }

    private var guidedPrompts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guided prompts")
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(JournalPrompt.seed.enumerated()), id: \.element.id) { index, prompt in
                    if index > 0 { Divider() }
                    NavigationLink(value: VoiceRoute.journalCompose(promptID: prompt.id)) {
                        HStack(spacing: 14) {
                            Image(systemName: "text.quote")
                                .font(.title3)
                                .frame(width: 28)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(prompt.body)
                                    .font(.caption)
                                    .foregroundStyle(Surface.inkSecondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("journal-prompt-\(prompt.id)")
                }
            }
            .background(Surface.card, in: .rect(cornerRadius: 14))
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    NavigationLink(value: VoiceRoute.journalEntry(entry.id)) {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.preview)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(entry.localDate.iso)
                                    .font(.caption)
                                    .foregroundStyle(Surface.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("journal-entry-\(entry.id.uuidString)")
                }
            }
            .background(Surface.card, in: .rect(cornerRadius: 14))
        }
    }

    private func reload() async {
        let start = container.dates.today.adding(days: -365, in: container.dates.calendar)
        entries = (try? await container.journal.entries(
            from: start,
            to: container.dates.today.adding(days: 1, in: container.dates.calendar)
        )) ?? []
    }
}

/// Compose or edit one entry. Autosaves on disappear when there is text.
struct JournalEditorView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    var entryID: UUID?
    var promptID: String?

    @State private var entry: JournalEntry?
    @State private var draft = ""
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompt {
                Text(prompt.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            TextEditor(text: $draft)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("journal-editor")
        }
        .navigationTitle(prompt?.title ?? "Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("journal-save")
            }
        }
        .task { await load() }
        .onDisappear {
            // Persist a partial draft so leaving mid-thought doesn't lose words.
            guard didLoad, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await save() }
        }
    }

    private var prompt: JournalPrompt? {
        if let promptID { return JournalPrompt.seed(id: promptID) }
        if let id = entry?.promptID { return JournalPrompt.seed(id: id) }
        return nil
    }

    private func load() async {
        if let entryID,
           let existing = try? await container.journal.entry(id: entryID) {
            entry = existing
            draft = existing.body
        } else if entry == nil {
            entry = JournalEntry(
                localDate: container.dates.today,
                body: "",
                promptID: promptID,
                createdAt: container.dates.now,
                updatedAt: container.dates.now
            )
        }
        didLoad = true
    }

    private func save() async {
        guard var entry else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entry.body = draft
        entry.updatedAt = container.dates.now
        self.entry = entry
        try? await container.journal.save(entry)
    }
}

#Preview {
    NavigationStack {
        JournalHubView()
    }
    .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
