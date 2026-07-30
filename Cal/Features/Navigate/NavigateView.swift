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

    /// Frames main campus. Deliberately fixed rather than fitted to the data —
    /// the seed includes genuinely off-campus UCB properties (the Richmond library
    /// facilities), and fitting to those would zoom the map out to uselessness.
    static let campusRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.8719, longitude: -122.2585),
        span: MKCoordinateSpan(latitudeDelta: 0.016, longitudeDelta: 0.016)
    )

    private var filtered: [CampusPlace] {
        places
            .filter { category == nil || $0.category == category }
            .filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            map
            filterRow
            list
        }
        .searchable(text: $query, prompt: "Search campus")
        .navigationTitle("Navigate")
        .task { await load() }
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
                            .background(ChartPalette.primary, in: .circle)
                            .foregroundStyle(.white)
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
            if filtered.isEmpty {
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
                } footer: {
                    Text("\(filtered.count) of \(places.count) places. Categories are auto-derived and still being checked.")
                }
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        places = ((try? CampusPlaceSeed.load()) ?? []).sorted { $0.name < $1.name }
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
            .background(isOn ? ChartPalette.primary : Color.secondary.opacity(0.18), in: .capsule)
            .foregroundStyle(isOn ? .white : .primary)
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
