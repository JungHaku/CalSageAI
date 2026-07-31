import CalKit
import SwiftUI

/// Today's schedule, read from the calendars the student already has on their
/// phone (`SPEC-free.md` §6).
///
/// EventKit rather than Google or Canvas OAuth: if they've added their Google
/// account to iOS — most have — it's already here, with one iOS permission prompt
/// and no verification process, no 100-user cap, no weekly token expiry
/// (ARCHITECTURE.md §13).
struct PlannerView: View {
    @Environment(AppContainer.self) private var container
    @State private var authorization: CalendarAuthorization = .notDetermined
    @State private var events: [PlannerEvent] = []
    @State private var didLoad = false

    var body: some View {
        Group {
            switch authorization {
            case .granted: schedule
            case .denied, .restricted: denied
            case .notDetermined: connect
            }
        }
        .navigationTitle("Today")
        .task { await load() }
    }

    // MARK: States

    private var connect: some View {
        ContentUnavailableView {
            Label("Your schedule", systemImage: "calendar")
        } description: {
            // Says plainly what the prompt will ask for. Apple offers no
            // read-only calendar tier, so a display-only feature still requests
            // read *and* write — better to be upfront than to look like an
            // overreach at the prompt.
            Text(
                """
                Cal can show today's classes and deadlines from the calendars \
                already on your phone. iOS has no read-only option, so it will ask \
                for calendar access — Cal never changes anything.
                """
            )
        } actions: {
            Button("Connect calendar") {
                Task {
                    authorization = await container.calendars.requestAccess()
                    await reload()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("connect-calendar")
        }
        // The longest explanatory copy in the app, and it clips at accessibility
        // text sizes without this.
        .scrollableWhenLarge()
    }

    private var denied: some View {
        ContentUnavailableView {
            Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("Turn it on in iOS Settings if you'd like today's schedule here.")
        }
        .accessibilityIdentifier("calendar-denied")
    }

    @ViewBuilder
    private var schedule: some View {
        if events.isEmpty && didLoad {
            ContentUnavailableView(
                "Nothing scheduled today",
                systemImage: "checkmark.circle",
                description: Text("Enjoy the gap.")
            )
            .accessibilityIdentifier("planner-empty")
        } else {
            List(events) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.subheadline.weight(.medium))
                    Text(event.timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("event-\(event.id)")
            }
            .listStyle(.plain)
        }
    }

    private func load() async {
        authorization = await container.calendars.authorization()
        await reload()
    }

    private func reload() async {
        guard authorization.canRead else {
            didLoad = true
            return
        }
        events = await container.calendars.events(
            on: container.dates.today, calendar: container.dates.calendar
        )
        didLoad = true
    }
}

#Preview("planner") {
    NavigationStack { PlannerView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
