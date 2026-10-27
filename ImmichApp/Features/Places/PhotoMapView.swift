import MapKit
import SwiftUI

/// Peta layar penuh berisi seluruh foto yang punya koordinat.
struct PhotoMapView: View {
    @State private var snapshotGeneration = LocalSnapshot.generation

    @Environment(SessionManager.self) private var session
    @State private var markers: [MapMarkerDTO]
    @State private var isLoading: Bool
    @State private var selected: AssetLite?
    /// Gagal memuat DAN tidak ada potret untuk ditampilkan.
    @State private var loadError: String?
    @Namespace private var sourceNamespace

    /// Potret lokal dibaca di `init`, bukan di `task`.
    ///
    /// `task` berjalan setelah render pertama, jadi membacanya di sana berarti
    /// peta sempat tergambar kosong berikut spinnernya satu frame — padahal
    /// isinya sudah ada di disk sejak awal. Spinner awalnya pun ditentukan dari
    /// situ: ada penanda berarti tidak ada yang perlu ditunggu.
    init() {
        let cached = LocalSnapshot.load(
            [MapMarkerDTO].self, for: LocalSnapshot.Key.places) ?? []
        _markers = State(initialValue: cached)
        _isLoading = State(initialValue: cached.isEmpty)
    }

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
        var seen = Set<String>()
        var result: [MapMarkerDTO] = []
        for marker in markers {
            let key = String(format: "%.2f,%.2f", marker.lat, marker.lon)
            if seen.insert(key).inserted { result.append(marker) }
        }
        return result
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
        Task {
            let repo = AssetDetailRepository(api: APIClient(session: session))
            guard let dto = try? await repo.fetchAsset(marker.id) else { return }
            selected = AssetLite(dto)
        }
    }

    /// Peta sudah berpenghuni dari potret; ini penyegarannya, diam-diam.
    private func load() async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        // Dibersihkan di AWAL, bukan hanya saat berhasil: dipanggil ulang dari
        // tombol Retry, layar errornya harus berganti jadi spinner supaya
        // ketukannya terasa dijawab.
        loadError = nil
        if markers.isEmpty { isLoading = true }

        let repo = PlacesRepository(api: APIClient(session: session))
        do {
            let fetched = try await repo.markers()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            // Hanya dipasang ulang kalau isinya memang berbeda — memasang
            // penanda yang sama persis membuat seluruh pin digambar ulang, dan
            // tiap pin memuat thumbnail sendiri.
            if LocalSnapshot.save(fetched, for: LocalSnapshot.Key.places, expectedGeneration: snapshotGeneration) || markers.isEmpty {
                markers = fetched
            }
        } catch {
            // `[]` yang sah (memang tidak ada foto berkoordinat) tidak pernah
            // sampai ke sini — hanya kegagalan sungguhan. Dan kegagalan itu cuma
            // berarti sesuatu kalau tidak ada apa pun untuk digambar.
            if markers.isEmpty {
                loadError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to load places")
            }
        }
        isLoading = false
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "mappin.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if isLoading {
            ProgressView()
        }
    }
}
