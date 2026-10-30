import MapKit
import SwiftUI

struct RecentDaysListView: View {
    let days: [RecentDayCollection]
    var refreshedDays: (@MainActor @Sendable () -> [RecentDayCollection])? = nil
    var refreshSources: @MainActor @Sendable () -> Void = {}

    private var visibleDays: [RecentDayCollection] {
        let policy = AssetVisibilityPolicy(scope: .timeline)
        return (refreshedDays?() ?? days).compactMap { $0.filteringAssets(using: policy) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                ForEach(visibleDays) { day in
                    NavigationLink {
                        RecentDayDestination(day: day,
                            previewAssets: { [refreshedDays, days] in (refreshedDays?() ?? days).first(where: { $0.id == day.id })?.assets ?? [] },
                            refreshSources: { [refreshSources] in refreshSources() })
                    } label: {
                        RecentDayCard(day: day, height: 220)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle("Recent Days")
        .onChange(of: LocalPhotoLibrary.shared.revision) { _, _ in refreshSources() }
        .onChange(of: SwiftDataManager.shared.assetMutationRevision) { _, _ in refreshSources() }
        .overlay {
            if visibleDays.isEmpty {
                ContentUnavailableView("No Recent Days", systemImage: "calendar")
            }
        }
    }
}

struct RecentDayDestination: View {
    let day: RecentDayCollection
    var previewAssets: (@MainActor @Sendable () -> [AssetLite])? = nil
    var refreshSources: @MainActor @Sendable () -> Void = {}

    var body: some View {
        DerivedCollectionView(
            title: LocalizedStringKey(day.start.formatted(.dateTime.year().month(.wide).day())),
            assets: { [previewAssets, day] in previewAssets?() ?? day.assets },
            dateInterval: DateInterval(start: day.start, end: day.end),
            refreshSources: { [refreshSources] in refreshSources() })
    }
}

struct RecentDayCard: View {
    let day: RecentDayCollection
    var width: CGFloat? = nil
    var height: CGFloat = 240
    @Environment(\.locale) private var locale

    var body: some View {
        if let admitted = day.filteringAssets(using: AssetVisibilityPolicy(scope: .timeline)) {
            card(admitted)
        }
    }

    private func card(_ day: RecentDayCollection) -> some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let asset = day.cover {
                    AuthImage(assetId: asset.id, size: "preview", thumbhash: asset.thumbhash, pixelSize: 800)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.start.formatted(.dateTime.month(.wide).day().locale(locale))).font(.headline).lineLimit(2).minimumScaleFactor(0.65)
                    Text("^[\(day.assets.count) item](inflect: true)").font(.caption).lineLimit(1).minimumScaleFactor(0.65)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
}

struct CollectionsMapPreview: View {
    let marker: MapMarkerDTO?

    var body: some View {
        Map(initialPosition: position, interactionModes: []) {}
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .id(marker?.id)
    }

    private var position: MapCameraPosition {
        if let marker {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
        }
        return .automatic
    }
}
