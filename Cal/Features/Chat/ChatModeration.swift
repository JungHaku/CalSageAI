import CalAI
import CalDesign
import CalKit
import Foundation
import Observation
import SwiftUI

/// Guideline 1.2, applied to what Cal says.
///
/// 1.2 is written for user-generated content, and reviewers apply it to AI output
/// — tightened in February 2026 and again that June. It asks for four things, and
/// a submission is expected to ship all four rather than pick:
///
/// 1. **A method for filtering objectionable content.** `Filter` below, plus the
///    system prompt and the provider's own moderation upstream of it.
/// 2. **A mechanism to report, with timely responses.** `ReportSheet`, reachable
///    from every single reply.
/// 3. **A way to block.** `ModerationStore.isBlocked` — it stops Cal entirely and
///    survives relaunch.
/// 4. **Published contact information.** `Support.contactEmail`, shown in the
///    report flow and in Settings.
///
/// Deliberately local-first. A report has to be recordable with no network and no
/// account, because the moment someone wants to report something is not the moment
/// to ask them to sign in. Forwarding to `safety_events` server-side can come
/// later; losing the report if the request fails would be worse than storing it
/// here.
enum Support {
    /// Read from `Info.plist` so it is configuration, not a constant buried in a
    /// view. **This must be an address someone actually reads** — 1.2 asks for
    /// *timely* responses, and review has been known to send a test message.
    static var contactEmail: String {
        Bundle.main.object(forInfoDictionaryKey: "CalSupportEmail") as? String
            ?? "support@example.com"
    }

    static var mailtoURL: URL? {
        URL(string: "mailto:\(contactEmail)?subject=C.A.L%20support")
    }
}

/// Why someone is reporting a reply. Apple wants a report *mechanism*; giving
/// reasons makes the reports triageable instead of an undifferentiated pile.
enum ReportReason: String, CaseIterable, Identifiable, Codable {
    case harmful = "Harmful or unsafe advice"
    case offensive = "Offensive or inappropriate"
    case wrong = "Factually wrong"
    case medical = "Gave medical advice"
    case other = "Something else"

    var id: String { rawValue }
}

/// One filed report. Kept verbatim, including the text, because a report about a
/// reply nobody can read afterwards is not actionable.
struct ContentReport: Codable, Identifiable {
    let id: UUID
    let messageID: UUID
    let reason: ReportReason
    let note: String
    let reportedText: String
    let createdAt: Date
}

/// The blocked flag and the report log. Both persist.
@Observable
@MainActor
final class ModerationStore {
    private static let blockedKey = "cal.moderation.calBlocked"
    private static let reportsKey = "cal.moderation.reports"

    /// When true, Cal will not answer at all. This is the 1.2 "block" affordance:
    /// the only party generating content here is Cal, so blocking Cal *is*
    /// blocking the content source. Reversible from Settings — a block someone
    /// cannot undo is a broken feature, not a safe one.
    private(set) var isBlocked: Bool
    private(set) var reports: [ContentReport]

    init() {
        isBlocked = UserDefaults.standard.bool(forKey: Self.blockedKey)
        reports =
            (UserDefaults.standard.data(forKey: Self.reportsKey))
            .flatMap { try? JSONDecoder().decode([ContentReport].self, from: $0) } ?? []
    }

    func setBlocked(_ blocked: Bool) {
        isBlocked = blocked
        UserDefaults.standard.set(blocked, forKey: Self.blockedKey)
    }

    func report(_ message: CoachMessage, reason: ReportReason, note: String) {
        reports.append(
            ContentReport(
                id: UUID(),
                messageID: message.id,
                reason: reason,
                note: note,
                reportedText: message.text,
                createdAt: Date()
            )
        )
        if let encoded = try? JSONEncoder().encode(reports) {
            UserDefaults.standard.set(encoded, forKey: Self.reportsKey)
        }
    }

    /// The last-resort output filter.
    ///
    /// Honest about what it is: the real filtering happens in the system prompt
    /// and in the provider's moderation, both upstream. This catches the narrow
    /// case where something slips through, and it exists so the app has a filter
    /// *of its own* rather than pointing at a vendor's.
    ///
    /// It is deliberately tiny. A big blocklist in a mental-health app is worse
    /// than none — students write about self-harm, and suppressing that text is
    /// exactly the wrong response. That path is `CrisisDetector`'s, and it routes
    /// to a human rather than hiding anything.
    enum Filter {
        private static let disallowed = [
            "kill yourself", "kys", "you should die", "worthless piece of",
        ]

        static func isObjectionable(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return disallowed.contains { lowered.contains($0) }
        }

        /// Shown in place of a reply that failed the filter.
        static let replacement =
            "Something went wrong with that reply and I've held it back. "
            + "Please report it if you saw anything troubling."
    }
}

/// The report flow. One reason, an optional note, and the contact address in
/// plain sight so someone who wants a human has one.
struct ReportSheet: View {
    let message: CoachMessage
    let onSubmit: (ReportReason, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .harmful
    @State private var note = ""
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            Form {
                if submitted {
                    Section {
                        Label("Report sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CoherenceScale.textTint(for: .high))
                        Text("Thanks — we review every report. If you'd like a reply, email us.")
                            .font(.footnote)
                            .foregroundStyle(Surface.inkSecondary)
                    }
                } else {
                    Section("What was wrong?") {
                        Picker("Reason", selection: $reason) {
                            ForEach(ReportReason.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section("Anything else? (optional)") {
                        TextField("Add detail", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                            .accessibilityIdentifier("report-note")
                    }

                    Section("The message you're reporting") {
                        // Stripped, not raw. Cal writes markdown, and quoting it
                        // back with the asterisks in shows the person something
                        // they never saw — which makes them doubt they are
                        // reporting the right thing.
                        Text(CoachMarkdown.plain(message.text))
                            .font(.footnote)
                            .foregroundStyle(Surface.inkSecondary)
                    }
                }

                Section {
                    if let url = Support.mailtoURL {
                        Link("Contact us: \(Support.contactEmail)", destination: url)
                            .accessibilityIdentifier("report-contact")
                    } else {
                        Text("Contact us: \(Support.contactEmail)")
                    }
                } footer: {
                    Text("We aim to respond within two business days.")
                }
            }
            .navigationTitle("Report a reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submitted ? "Done" : "Cancel") { dismiss() }
                }
                if !submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit") {
                            onSubmit(reason, note)
                            submitted = true
                        }
                        .accessibilityIdentifier("report-submit")
                    }
                }
            }
        }
    }
}

#Preview("report") {
    ReportSheet(
        message: CoachMessage(role: .assistant, text: "Let's take one slow breath together."),
        onSubmit: { _, _ in }
    )
}
