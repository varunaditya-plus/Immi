import MapKit
import SwiftUI

@MainActor
struct PhotoMapView: View {
    var assetIDs: Set<String>?
    var initialBounds: PhotoMapBounds?
    private let markerLoader: (@MainActor () async throws -> [MapMarkerDTO])?
    private let assetLoader: (@MainActor () async throws -> [AssetLite])?

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model: PhotoMapViewModel
    @State private var position: MapCameraPosition = .automatic
    @State private var viewport: PhotoMapBounds?
    @State private var viewportSize = CGSize(width: 390, height: 844)
    @State private var mode = PhotoMapDisplayMode.map
    @State private var focusedIDs: Set<String>?
    @State private var focusedTitle: String?
    @State private var showsNearby = false
    @State private var choosingMap = false
    @State private var hasPositioned = false
    @State private var isSelecting = false
    @AppStorage("photoMap.style") private var mapStyle = PhotoMapStyle.explore.rawValue
    @Namespace private var mapScope

    init(assetIDs: Set<String>? = nil, initialBounds: PhotoMapBounds? = nil,
         model: PhotoMapViewModel? = nil,
         markerLoader: (@MainActor () async throws -> [MapMarkerDTO])? = nil,
         assetLoader: (@MainActor () async throws -> [AssetLite])? = nil) {
        self.assetIDs = assetIDs
        self.initialBounds = initialBounds
        self.markerLoader = markerLoader
        self.assetLoader = assetLoader
        _model = State(initialValue: model ?? PhotoMapViewModel())
    }

    var body: some View {
        ZStack {
            if mode == .map {
                map
            } else {
                grid
            }
        }
        .navigationTitle(mode == .map ? Text("") : Text("Map"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarVisibility(.visible, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isSelecting, (mode == .grid || !markers.isEmpty || assetIDs != nil) {
                VStack(spacing: 10) {
                    if assetIDs != nil || focusedIDs != nil || showsNearby {
                        Button(showsNearby ? "Hide Nearby Photos" : "Show Nearby Photos") {
                            showsNearby.toggle()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                    }
                    PhotoMapModePicker(selection: Binding(
                        get: { mode }, set: { value in
                            if value == .grid { focusedIDs = nil; focusedTitle = nil }
                            mode = value
                        }))
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $choosingMap) {
            PhotoMapStylePicker(selection: Binding(
                get: { PhotoMapStyle(rawValue: mapStyle) ?? .explore },
                set: { mapStyle = $0.rawValue }), bounds: bounds)
        }
        .task(id: session.accountGeneration) { await load() }
        .onChange(of: session.accountGeneration) { _, _ in dismiss() }
        .onChange(of: SwiftDataManager.shared.assetMutationRevision) { _, _ in
            Task { await load() }
        }
        .onChange(of: LocalPhotoLibrary.shared.photos) { _, _ in positionIfNeeded() }
        .onChange(of: mode) { _, value in
            isSelecting = false
            if value == .map, let viewport { position = .region(viewport.region) }
        }
        .onDisappear { model.cancelAssetLoading() }
    }

    private var markers: [MapMarkerDTO] {
        model.markers(forAssetIDs: showsNearby ? nil : assetIDs)
    }

    private var bounds: PhotoMapBounds {
        viewport ?? initialBounds ?? PhotoMapBounds.fitting(markers)
            ?? PhotoMapBounds(centerLatitude: 20, centerLongitude: 0, latitudeDelta: 100, longitudeDelta: 200)
    }

    private var clusters: [PhotoMapCluster] {
        PhotoMapClustering.clusters(in: markers, bounds: bounds,
            viewportWidth: viewportSize.width, viewportHeight: viewportSize.height)
    }

    private var gridIDs: Set<String> {
        let visible = Set(markers.map(\.id))
        if let focusedIDs, !showsNearby { return focusedIDs.intersection(visible) }
        return Set(markers.filter(bounds.contains).map(\.id))
    }

    private var map: some View {
        GeometryReader { geometry in
            Map(position: $position, scope: mapScope) {
                ForEach(clusters) { cluster in
                    Annotation(cluster.title,
                        coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude),
                        anchor: .bottom) {
                        PhotoMapPin(cluster: cluster, thumbnailID: model.thumbnailID(for: cluster.coverID)) {
                            focusedIDs = cluster.memberIDs
                            focusedTitle = cluster.title
                            mode = .grid
                        }
                    }
                    .annotationTitles(.hidden)
                }
                UserAnnotation()
            }
            .mapStyle((PhotoMapStyle(rawValue: mapStyle) ?? .explore).style)
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { context in
                viewport = PhotoMapBounds(context.region)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Button { choosingMap = true } label: {
                        Image(systemName: "map.fill").font(.title3)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Choose Map")
                    Divider().frame(width: 24)
                    MapUserLocationButton(scope: mapScope)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)
                .padding(.trailing, 16)
                .padding(.top, geometry.safeAreaInsets.top + 16)
            }
            .overlay { statusOverlay }
            .overlay(alignment: .bottom) {
                if let error = model.refreshError ?? (markers.isEmpty ? nil : model.loadError) {
                    HStack(spacing: 12) {
                        Text(error).font(.footnote)
                        Button("Retry") { Task { await load() } }.font(.subheadline.bold())
                    }
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .padding()
                }
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .mapScope(mapScope)
    }

    private var grid: some View {
        let ids = gridIDs
        return DerivedCollectionView(title: LocalizedStringKey(focusedTitle ?? String(localized: "Map")),
            assets: { model.cachedAssets(for: ids) },
            assetLoader: {
                try await model.assets(for: ids) {
                    if let assetLoader { return try await assetLoader() }
                    return try await PhotoMapAssetRepository(api: APIClient(session: session)).allAssets()
                }
            }, layout: .monthly, keepsTabBarVisible: true,
            onSelectionChanged: { isSelecting = $0 },
            dataManager: model.store, localPhotos: { model.selectedLocalPhotos })
            .id(ids)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let error = model.loadError, markers.isEmpty {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "mappin.slash")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
            }
            .background(.regularMaterial)
        } else if model.isLoading, markers.isEmpty {
            ProgressView().padding(20).background(.regularMaterial, in: .circle)
        } else if markers.isEmpty {
            ContentUnavailableView("No Photos with Location", systemImage: "mappin.slash",
                description: Text("Photos and videos with location information appear here."))
                .allowsHitTesting(false)
        }
    }

    private func load() async {
        await model.load {
            if let markerLoader { return try await markerLoader() }
            return try await PlacesRepository(api: APIClient(session: session)).markers()
        }
        positionIfNeeded()
    }

    private func positionIfNeeded() {
        guard !hasPositioned, let fit = initialBounds ?? PhotoMapBounds.fitting(markers) else { return }
        hasPositioned = true
        viewport = fit
        position = .region(fit.region)
    }
}

enum PhotoMapDisplayMode: String, CaseIterable, Identifiable {
    case map, grid
    var id: Self { self }
    var title: String { self == .map ? String(localized: "Map") : String(localized: "Grid") }
}

struct PhotoMapModePicker: View {
    @Binding var selection: PhotoMapDisplayMode
    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(PhotoMapDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("photoMap.mode")
    }
}

struct PhotoMapPin: View {
    let cluster: PhotoMapCluster
    var thumbnailID: String? = nil
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            AuthImage(assetId: thumbnailID ?? cluster.coverID)
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white, lineWidth: 3) }
                .overlay(alignment: .bottom) {
                    Text(cluster.count, format: .number)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: .capsule)
                        .offset(y: 7)
                }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cluster.title)
        .accessibilityValue(String(localized: "\(cluster.count) items"))
        .accessibilityHint("View photos and videos from this location")
    }
}

enum PhotoMapStyle: String, CaseIterable, Identifiable {
    case explore, satellite
    var id: Self { self }
    var title: String { self == .explore ? String(localized: "Explore") : String(localized: "Satellite") }
    var style: MapStyle { self == .explore ? .standard(elevation: .realistic) : .imagery(elevation: .realistic) }
}

struct PhotoMapStylePicker: View {
    @Binding var selection: PhotoMapStyle
    let bounds: PhotoMapBounds
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Choose Map").font(.title2.bold())
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
            }
            HStack(spacing: 16) {
                ForEach(PhotoMapStyle.allCases) { style in
                    Button { selection = style } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Map(initialPosition: .region(bounds.region), interactionModes: []) {}
                                .mapStyle(style.style)
                                .mapControls {}
                                .frame(height: 100)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            Text(style.title).font(.body).padding(12)
                        }
                        .background(.background)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selection == style ? Color.accentColor : .clear, lineWidth: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

extension PhotoMapBounds {
    init(_ region: MKCoordinateRegion) {
        self.init(centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
    }
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }
}
