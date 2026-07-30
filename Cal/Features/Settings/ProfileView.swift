import CalData
import CalKit
import SwiftUI

/// The profile from `SPEC-free.md` §13: name, major, graduation year, goals,
/// interests.
///
/// Every field is optional. A student who wants to check in without telling the
/// app anything about themselves should be able to, and nothing downstream
/// depends on these being filled in.
struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @State private var profile: Profile?
    @State private var interestsText = ""

    var body: some View {
        Form {
            if let profile {
                fields(profile)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Profile")
        .task {
            if profile == nil {
                profile = (try? await container.profiles.current()) ?? Profile()
                interestsText = profile?.interests.joined(separator: ", ") ?? ""
            }
        }
    }

    @ViewBuilder
    private func fields(_ profile: Profile) -> some View {
        Section("About you") {
            LabeledContent("Name") {
                TextField("Optional", text: binding(\.displayName))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("profile-name")
            }
            LabeledContent("Major") {
                TextField("Optional", text: binding(\.major))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("profile-major")
            }
            Picker("Graduation", selection: gradYearBinding) {
                Text("Not set").tag(Int?.none)
                ForEach(Array(Profile.validGradYears), id: \.self) { year in
                    Text(String(year)).tag(Int?.some(year))
                }
            }
            .accessibilityIdentifier("profile-grad-year")
        }

        Section {
            TextField("What are you working toward?", text: binding(\.goals), axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("profile-goals")
        } header: {
            Text("Goals")
        }

        Section {
            TextField("Climbing, ceramics, …", text: $interestsText)
                .accessibilityIdentifier("profile-interests")
                .onSubmit { commitInterests() }
        } header: {
            Text("Interests")
        } footer: {
            Text("Separate with commas. All of this is optional and stays on your phone.")
        }
    }

    /// Writes through to the store on every edit. There is no Save button because
    /// there is nothing to fail — it's a local write, and a student who backs out
    /// of this screen shouldn't silently lose what they typed.
    private func binding(_ keyPath: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(
            get: { profile?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var updated = profile else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                updated[keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
                profile = updated
                Task { try? await container.profiles.save(updated) }
            }
        )
    }

    private var gradYearBinding: Binding<Int?> {
        Binding(
            get: { profile?.gradYear },
            set: { newValue in
                guard var updated = profile else { return }
                updated.gradYear = newValue
                profile = updated
                Task { try? await container.profiles.save(updated) }
            }
        )
    }

    private func commitInterests() {
        guard var updated = profile else { return }
        updated.interests = interestsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        profile = updated
        Task { try? await container.profiles.save(updated) }
    }
}

#Preview("profile") {
    NavigationStack { ProfileView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
