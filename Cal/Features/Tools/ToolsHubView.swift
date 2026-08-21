import CalDesign
import CalKit
import SwiftUI

/// TOOLS tab root (`PLAN-cal-sage-shell.md` §4–5): breathwork, study, map, check-in.
///
/// Sleep, the curated resource directory, and Sacred Care Fund are listed in the
/// blueprint but have no screens yet — omitted rather than stubbed as dead ends.
struct ToolsHubView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Practices and campus tools when you need them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                destinations
            }
            .padding()
        }
        .navigationTitle("Tools")
        .accessibilityIdentifier("tools-root")
    }

    private var destinations: some View {
        VStack(spacing: 0) {
            NavigationLink(value: VoiceRoute.practices) {
                ToolsRow(
                    title: "Breathwork",
                    subtitle: "Guided coherence sessions",
                    icon: "wind",
                    identifier: "dest-practices"
                )
            }
            Divider()
            NavigationLink(value: VoiceRoute.study) {
                ToolsRow(
                    title: "Study",
                    subtitle: "Focus block with a reset",
                    icon: "timer",
                    identifier: "dest-study"
                )
            }
            Divider()
            NavigationLink(value: VoiceRoute.navigate(query: "")) {
                ToolsRow(
                    title: "Campus map",
                    subtitle: "Find places on Berkeley campus",
                    icon: "map",
                    identifier: "dest-map"
                )
            }
        }
        .buttonStyle(.plain)
        .background(Surface.card, in: .rect(cornerRadius: 14))
    }
}

private struct ToolsRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let identifier: String
    var isLocked = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(Surface.inkSecondary)
            }
            Spacer()
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Requires C.A.L+")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    NavigationStack { ToolsHubView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
