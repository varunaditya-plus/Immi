import Foundation
import Observation

@MainActor
@Observable
final class AssistiveAccessViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    private(set) var photos: [AssetLite] = []
    private(set) var favorites: [AssetLite] = []
    private(set) var album: [AssetLite] = []
    private(set) var isLoading = false

    @ObservationIgnored let thumbnails: PhotoThumbnailLoader
    @ObservationIgnored let previews: PhotoPreviewLoader
    @ObservationIgnored private let dataManager: SwiftDataManager
    @ObservationIgnored private let searchRepository: SearchRepository
    @ObservationIgnored private let timelineRepository: TimelineRepository
    @ObservationIgnored private let syncViewModel: SyncViewModel

    init(session: SessionManager) {
        let api = APIClient(session: session)
        let dataManager = SwiftDataManager.shared
        self.dataManager = dataManager
        self.searchRepository = SearchRepository(api: api)
        self.timelineRepository = TimelineRepository(api: api)
        self.syncViewModel = SyncViewModel(
            repo: SyncRepository(api: api, dataManager: dataManager),
            dataManager: dataManager)
        self.thumbnails = PhotoThumbnailLoader(session: session)
        self.previews = PhotoPreviewLoader(session: session)
    }

    /// Cache lokal dipasang lebih dulu. Network refresh berjalan bersamaan dan
    /// kegagalannya tidak membuang foto yang masih sah untuk dilihat offline.
    func load(showsFavorites: Bool, albumID: String) async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        restorePhotos()
        if showsFavorites {
            let cached = LocalSnapshot.load(
                [AssetLite].self, for: LocalSnapshot.Key.favorites)
                ?? photos.filter(\.isFavorite)
            favorites = chronological(cached)
        } else {
            favorites = []
        }
        if !albumID.isEmpty {
            let cached = LocalSnapshot.load(
                [AssetLite].self, for: LocalSnapshot.Key.album(albumID)) ?? []
            album = chronological(cached)
        } else {
            album = []
        }

        isLoading = photos.isEmpty
            || (showsFavorites && favorites.isEmpty)
            || (!albumID.isEmpty && album.isEmpty)
        defer { isLoading = false }

        async let sync: Void = syncViewModel.performBackgroundSync()
        async let refreshedFavorites = fetchFavorites(if: showsFavorites)
        async let refreshedAlbum = fetchAlbum(id: albumID)

        let (_, favoriteResult, albumResult) = await (
            sync, refreshedFavorites, refreshedAlbum)
        guard snapshotGeneration == LocalSnapshot.generation else { return }

        restorePhotos()
        if let favoriteResult {
            let ordered = chronological(favoriteResult)
            favorites = ordered
            LocalSnapshot.save(ordered, for: LocalSnapshot.Key.favorites, expectedGeneration: snapshotGeneration)
        }
        if let albumResult {
            let ordered = chronological(albumResult)
            album = ordered
            LocalSnapshot.save(ordered, for: LocalSnapshot.Key.album(albumID), expectedGeneration: snapshotGeneration)
        }
    }

    private func restorePhotos() {
        // Cache Timeline memang disimpan menaik. Urutan itu dipertahankan agar
        // foto terbaru berada di ujung bawah, sama seperti Photos utama.
        photos = dataManager.timelineAssets().map(\.asset)
    }

    private func fetchFavorites(if enabled: Bool) async -> [AssetLite]? {
        guard enabled else { return [] }
        var request = SearchRequestDTO(
            page: 1,
            order: "asc",
            isFavorite: true,
            size: 1_000)
        request.visibility = "timeline"
        guard let assets = try? await searchRepository.allMetadata(request) else {
            return nil
        }
        return assets.map(AssetLite.init)
    }

    private func fetchAlbum(id: String) async -> [AssetLite]? {
        guard !id.isEmpty else { return [] }
        return try? await timelineRepository.albumAssets(id)
    }

    /// Semua sumber — network maupun snapshot lama — dinormalisasi supaya
    /// urutan tidak berubah tergantung layar mana yang pernah dibuka terakhir.
    private func chronological(_ assets: [AssetLite]) -> [AssetLite] {
        assets.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }
}
