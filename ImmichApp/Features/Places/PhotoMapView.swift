import MapKit
import SwiftUI

/// Peta layar penuh berisi seluruh foto yang punya koordinat.
@MainActor
struct PhotoMapView: View {
    @Environment(SessionManager.self) private var session
    @State private var model = PhotoMapViewModel()
    @State private var selected: AssetLite?
    @Namespace private var sourceNamespace

    var body: some View {
        map
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { statusOverlay }
            .task { await load() }
            .navigationDestination(item: $selected) { asset in
                AssetDetailView(currentAsset: asset, assets: [asset])
                    .navigationTransition(.zoom(sourceID: asset.id, in: sourceNamespace))
            }
            .onChange(of: selected.map {
                model.isCurrentAccount
                    && AssetVisibilityPolicy(scope: .timeline).allows(id: $0.id)
            } ?? true) { _, allowed in
                if !allowed { selected = nil }
            }
    }

    private var map: some View {
        Map(initialPosition: .automatic) {
            // Anotasi dibatasi supaya peta tetap lancar: setiap pin memuat
            // thumbnail sendiri, dan ribuan permintaan sekaligus akan membuat
            // gulirannya tersendat.
            ForEach(visibleMarkers) { marker in
                Annotation(
                    marker.city ?? "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: marker.lat, longitude: marker.lon)
                ) {
                    pin(for: marker)
                }
            }
        }
        .mapStyle(.standard)
    }

    /// Satu pin per koordinat yang dibulatkan, bukan per foto.
    ///
    /// Foto yang diambil di tempat yang sama menghasilkan puluhan titik yang
    /// bertumpuk persis — hanya yang teratas yang pernah terlihat, sisanya
    /// membebani peta tanpa terlihat sama sekali.
    private var visibleMarkers: [MapMarkerDTO] {
        guard model.isCurrentAccount else { return [] }
        return MapMarkerDTO.visible(in: model.markers, policy: AssetVisibilityPolicy(scope: .timeline))
    }

    private func pin(for marker: MapMarkerDTO) -> some View {
        Button {
            open(marker)
        } label: {
            AuthImage(assetId: marker.id)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white, lineWidth: 3)
                }
                .shadow(radius: 3)
                .matchedTransitionSource(id: marker.id, in: sourceNamespace)
        }
        .buttonStyle(.plain)
    }

    private func open(_ marker: MapMarkerDTO) {
        guard AssetVisibilityPolicy(scope: .timeline).allows(id: marker.id) else { return }
        Task {
            let repo = AssetDetailRepository(api: APIClient(session: session))
            guard let dto = try? await repo.fetchAsset(marker.id) else { return }
            guard !Task.isCancelled, model.isCurrentAccount,
                  dto.isTimelineVisible,
                  AssetVisibilityPolicy(scope: .timeline).allows(id: dto.id) else { return }
            selected = AssetLite(dto)
        }
    }

    /// Peta sudah berpenghuni dari potret; ini penyegarannya, diam-diam.
    private func load() async {
        let repo = PlacesRepository(api: APIClient(session: session))
        await model.load { try await repo.markers() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let loadError = model.loadError {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "mappin.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.isLoading {
            ProgressView()
        }
    }
}
