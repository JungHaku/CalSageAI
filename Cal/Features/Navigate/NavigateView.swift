import CalContent
import CalDesign
import CalKit
import MapKit
import SwiftUI

/// Campus map and place search.
///
/// The list is not a fallback — it's the primary way to *find* something, and the
/// map answers "where is that". A map of 231 identical pins is close to unusable
/// with VoiceOver, so the searchable list is the accessible path by design rather
/// than as an afterthought.
struct NavigateView: View {
    @Environment(AppContainer.self) private var container

    @State private var places: [CampusPlace] = []
    @State private var query = ""
    @State private var category: CampusPlaceCategory?
    @State private var selected: CampusPlace?
    @State private var camera: MapCameraPosition = .region(Self.campusRegion)

    /// Results from semantic search, used only when substring matching found
    /// nothing. Kept separate from `places` so the offline list is never
    /// replaced by something that needed a network to arrive.
    @State private var semanticMatches: [CampusPlace] = []
    @State private var isSearchingSemantically = false

    /// Frames main campus. Deliberately fixed rather than fitted to the data —
    /// the seed includes genuinely off-campus UCB properties (the Richmond library
    /// facilities), and fitting to those would zoom the map out to uselessness.
    static let campusRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.8719, longitude: -122.2585),
        span: MKCoordinateSpan(latitudeDelta: 0.016, longitudeDelta: 0.016)
    )

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Substring matching, computed synchronously on every keystroke. Instant,
    /// offline, and the path that must never regress.
    private var localMatches: [CampusPlace] {
        trimmedQuery.isEmpty ? places : places.filter { $0.matches(trimmedQuery) }
    }

    /// Semantic results stand in only when the literal search came up empty —
    /// which is exactly the case it helps with. "Wheeler" is answered locally;
    /// "where's the gym" matches no building name at all.
    private var isShowingSemanticResults: Bool {
        !trimmedQuery.isEmpty && localMatches.isEmpty && !semanticMatches.isEmpty
    }

    private var filtered: [CampusPlace] {
        (isShowingSemanticResults ? semanticMatches : localMatches)
            .filter { category == nil || $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            map
            filterRow
            list
        }
        .searchable(text: $query, prompt: "Search campus or describe it")
        .navigationTitle("Navigate")
        .task { await load() }
        // `.task(id:)` cancels the in-flight search when the query changes, so
        // the debounce below is a real debounce rather than a queue of stale
        // requests all landing at once.
        .task(id: query) { await searchSemantically() }
        .sheet(item: $selected) { place in
            PlaceDetailSheet(place: place)
                .presentationDetents([.medium])
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            // Only the filtered set is annotated. Rendering all 231 at once is
            // both slow and unreadable; the filter is what makes the map legible.
            ForEach(filtered) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    Button {
                        selected = place
                    } label: {
                        Image(systemName: place.category.symbolName)
                            .font(.caption2)
                            .padding(6)
                            .background(Brand.action, in: .circle)
                            .foregroundStyle(Brand.onAction)
                    }
                    .accessibilityLabel(place.name)
                }
                .annotationTitles(filtered.count <= 25 ? .automatic : .hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 260)
        .accessibilityHidden(true)  // the list below is the accessible path
    }

    // MARK: Filter

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isOn: category == nil) { category = nil }
                ForEach(availableCategories) { option in
                    FilterChip(
                        title: option.displayName,
                        systemImage: option.symbolName,
                        isOn: category == option
                    ) {
                        category = category == option ? nil : option
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("category-filter")
    }

    /// Only categories that actually have places, so the row doesn't offer an
    /// empty "Dining" filter.
    private var availableCategories: [CampusPlaceCategory] {
        let present = Set(places.map(\.category))
        return CampusPlaceCategory.allCases.filter { present.contains($0) && $0 != .building }
    }

    // MARK: List

    private var list: some View {
        List {
            if isSearchingSemantically {
                // Only ever shown when the literal search already came up empty,
                // so this replaces "No results" rather than delaying results the
                // student could otherwise be reading.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for places that match what you meant…")
                        .font(.footnote)
                        .foregroundStyle(Surface.inkSecondary)
                }
                .accessibilityIdentifier("semantic-searching")
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Section {
                    ForEach(filtered) { place in
                        Button {
                            selected = place
                        } label: {
                            Label {
                                Text(place.name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: place.category.symbolName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("place-\(place.slug)")
                    }
                } header: {
                    if isShowingSemanticResults {
                        // Say why these matched. Nothing here contains the words
                        // that were typed, so without a note the list reads as if
                        // the search is broken.
                        Label("Closest matches by meaning, not by name", systemImage: "sparkles")
                            .font(.footnote)
                            .textCase(nil)
                            .accessibilityIdentifier("semantic-results-header")
                    }
                } footer: {
                    Text(footerText)
                }
            }
        }
        .listStyle(.plain)
    }

    private var footerText: String {
        if isShowingSemanticResults {
            return "\(filtered.count) suggested for “\(trimmedQuery)”. Categories are auto-derived and still being checked."
        }
        return "\(filtered.count) of \(places.count) places. Categories are auto-derived and still being checked."
    }

    private func load() async {
        places = ((try? CampusPlaceSeed.load()) ?? []).sorted { $0.name < $1.name }
    }

    /// Asks the endpoint only when substring matching has already failed.
    ///
    /// Three properties worth keeping: a building name never waits on a network
    /// round trip, an offline device behaves exactly as it did before semantic
    /// search existed, and we spend an embedding only on queries the local index
    /// genuinely cannot serve.
    private func searchSemantically() async {
        semanticMatches = []
        let asked = trimmedQuery
        guard !asked.isEmpty, localMatches.isEmpty else { return }

        // Typing "recreational" passes through four failing prefixes on the way.
        // Without this each one is a request.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isSearchingSemantically = true
        defer { isSearchingSemantically = false }

        let found = await container.placeSearch.search(asked, in: places)
        // The query may have moved on while this was in flight.
        guard !Task.isCancelled, asked == trimmedQuery else { return }
        semanticMatches = found
    }
}

private struct FilterChip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.caption2) }
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Brand.action : Color.secondary.opacity(0.18), in: .capsule)
            .foregroundStyle(isOn ? Brand.onAction : Surface.inkPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

private struct PlaceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let place: CampusPlace

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(place.category.displayName, systemImage: place.category.symbolName)
                    Button {
                        // Hand off to Maps rather than building routing — walking
                        // directions across a campus are Apple's problem, not ours.
                        place.mapItem.openInMaps(
                            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
                        )
                    } label: {
                        Label("Walking directions", systemImage: "figure.walk")
                    }
                    .accessibilityIdentifier("walking-directions")
                } footer: {
                    if place.verifiedAt == nil {
                        // Same rule as the crisis numbers: say when something
                        // hasn't been checked by a person.
                        Text("Location from the campus map, not yet verified on foot.")
                    }
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension CampusPlace {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

#Preview("navigate") {
    NavigationStack { NavigateView() }
        .environment(AppContainer.live(arguments: ["-CalUseMockCoach", "1"]))
}
