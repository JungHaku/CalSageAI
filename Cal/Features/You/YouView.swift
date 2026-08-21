import CalDesign
import SwiftUI

/// YOU tab root (`PLAN-cal-sage-shell.md` §4): journey, insights, settings.
struct YouView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your journey, insights, and account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                destinations
            }
            .padding()
        }
        .navigationTitle("You")
        .accessibilityIdentifier("you-root")
    }

    private var destinations: some View {
        VStack(spacing: 0) {
            NavigationLink(value: VoiceRoute.settings) {
                YouRow(
                    title: "Settings",
                    subtitle: "Reminder and your data",
                    icon: "gear",
                    identifier: "dest-settings"
                )
            }
        }
        .buttonStyle(.plain)
        .background(Surface.card, in: .rect(cornerRadius: 14))
    }
}

private struct YouRow: View {
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
    NavigationStack { YouView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
