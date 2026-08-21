import SwiftUI

/// Emergency help. Three hard rules, from ARCHITECTURE.md §9.2 Layer D:
///
/// 1. **Fully offline.** Every number is compiled in. No fetch, no spinner, no
///    dependency on the AI or the network being reachable — this screen has to
///    work precisely when nothing else does.
/// 2. **One tap from anywhere.** Presented from the toolbar on every tab.
/// 3. **No unverified numbers.** A wrong crisis number is the worst bug this app
///    can ship, so a number appears here only once a human has dialled it.
struct EmergencyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EmergencyContact.verified) { contact in
                        ContactRow(contact: contact)
                    }
                } header: {
                    Text("Talk to someone now")
                } footer: {
                    Text("988 is the Suicide & Crisis Lifeline. Call or text, 24 hours a day.")
                }

                // Rendered as disabled placeholders rather than omitted, so the
                // gap is visible in review instead of being quietly forgotten.
                Section("Campus resources") {
                    ForEach(EmergencyContact.pendingVerification) { contact in
                        Label(contact.label, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .badge("unverified")
                    }
                }

                Section {
                    Text(
                        """
                        C.A.L is a coherence coach, not a therapist, and not a \
                        substitute for medical care. If you are in danger, call 911.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Emergency help")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ContactRow: View {
    let contact: EmergencyContact

    var body: some View {
        // `tel:` and `sms:` hand off to iOS, which shows its own confirmation —
        // so the app never places a call without an explicit user action.
        Link(destination: contact.url) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.label).foregroundStyle(.primary)
                    Text(contact.detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: contact.systemImage)
            }
        }
        .accessibilityIdentifier("emergency-\(contact.id)")
    }
}

struct EmergencyContact: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let systemImage: String
    let urlString: String

    var url: URL { URL(string: urlString)! }

    /// Nationally standard and unambiguous, so these are safe to compile in.
    static let verified: [EmergencyContact] = [
        .init(
            id: "988-call", label: "Call 988",
            detail: "Suicide & Crisis Lifeline", systemImage: "phone.fill",
            urlString: "tel:988"
        ),
        .init(
            id: "988-text", label: "Text 988",
            detail: "If you'd rather not talk", systemImage: "message.fill",
            urlString: "sms:988"
        ),
        .init(
            id: "988-chat", label: "Chat online",
            detail: "988lifeline.org", systemImage: "bubble.left.fill",
            urlString: "https://988lifeline.org/chat/"
        ),
        .init(
            id: "911", label: "Call 911",
            detail: "Immediate danger", systemImage: "exclamationmark.triangle.fill",
            urlString: "tel:911"
        ),
    ]

    /// ⚠️ BLOCKED ON HUMAN VERIFICATION — see ARCHITECTURE.md §9.3.
    ///
    /// UC Berkeley's own pages disagree on the after-hours counselling number:
    /// `crisisresponse.berkeley.edu` prints (855) 817-8667 while
    /// `uhs.berkeley.edu/after-hours` prints (855) 817-5667. Rather than ship a
    /// coin-flip, these render as visibly unverified until someone dials both and
    /// confirms. Do not fill in digits from a search result.
    static let pendingVerification: [EmergencyContact] = [
        .init(
            id: "caps", label: "Counselling & Psychological Services",
            detail: "number disputed across UC pages", systemImage: "questionmark.circle",
            urlString: "https://uhs.berkeley.edu/"
        ),
        .init(
            id: "ucpd", label: "UCPD",
            detail: "pending verification", systemImage: "questionmark.circle",
            urlString: "https://ucpd.berkeley.edu/"
        ),
    ]
}

#Preview {
    EmergencyView()
}

#Preview("dark") {
    EmergencyView().preferredColorScheme(.dark)
}
