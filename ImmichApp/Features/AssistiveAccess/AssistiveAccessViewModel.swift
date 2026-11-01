import Foundation
import Observation

@MainActor
@Observable
final class AssistiveAccessViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    // AssetLite equality compares IDs; the container also publishes changed metadata.
    private struct Sources {
        var photos: [AssetLite] = []
        var favorites: [AssetLite] = []
        var album: [AssetLite] = []
    }
    private var source = Sources()
    private var loading = false
    private var loadID = UUID()

    var photos: [AssetLite] { admitted(source.photos, scope: .timeline) }
    var favorites: [AssetLite] { admitted(source.favorites, scope: .timeline) }
    var album: [AssetLite] { admitted(source.album, scope: .collection) }
    var isLoading: Bool { isCurrent && loading }
    var isCurrent: Bool {
        snapshotGeneration == LocalSnapshot.generation && session.snapshot == requestContext
    }

    @ObservationIgnored let thumbnails: PhotoThumbnailLoader
    @ObservationIgnored let previews: PhotoPreviewLoader
    @ObservationIgnored private let dataManager: SwiftDataManager
    @ObservationIgnored private let searchRepository: SearchRepository
    @ObservationIgnored private let timelineRepository: TimelineRepository
    @ObservationIgnored private let session: SessionManager
    @ObservationIgnored private let requestContext: SessionRequestContext
    @ObservationIgnored private let performSync: @MainActor @Sendable () async -> Void

    init(api: APIClient, dataManager: SwiftDataManager? = nil,
         performSync: (@MainActor @Sendable () async -> Void)? = nil) {
        let dataManager = dataManager ?? .shared
        let session = api.session
        self.session = session
        self.requestContext = session.snapshot
        self.dataManager = dataManager
        self.searchRepository = SearchRepository(api: api, dataManager: dataManager)
        self.timelineRepository = TimelineRepository(api: api, dataManager: dataManager)
        let syncViewModel = SyncViewModel(
            repo: SyncRepository(api: api, dataManager: dataManager),
            dataManager: dataManager)
        self.performSync = performSync ?? { await syncViewModel.performBackgroundSync() }
        self.thumbnails = PhotoThumbnailLoader(session: session)
        self.previews = PhotoPreviewLoader(session: session)
    }

    /// Cache lokal dipasang lebih dulu. Network refresh berjalan bersamaan dan
    /// kegagalannya tidak membuang foto yang masih sah untuk dilihat offline.
    func load(showsFavorites: Bool, albumID: String) async {
        guard isCurrent, !Task.isCancelled else { return }
        let request = UUID()
        loadID = request
        restorePhotos()
        if showsFavorites {
            let cached = LocalSnapshot.load(
                [AssetLite].self, for: LocalSnapshot.Key.favorites)
                ?? photos.filter(\.isFavorite)
            source.favorites = chronological(cached)
        } else {
            source.favorites = []
        }
        if !albumID.isEmpty {
            let cached = LocalSnapshot.load(
                [AssetLite].self, for: LocalSnapshot.Key.album(albumID)) ?? []
            source.album = chronological(cached)
        } else {
            source.album = []
        }

        loading = photos.isEmpty
            || (showsFavorites && favorites.isEmpty)
            || (!albumID.isEmpty && album.isEmpty)
        defer { if loadID == request { loading = false } }

        async let sync: Void = performSync()
        async let refreshedFavorites = fetchFavorites(if: showsFavorites)
        async let refreshedAlbum = fetchAlbum(id: albumID)

        let (_, favoriteResult, albumResult) = await (
            sync, refreshedFavorites, refreshedAlbum)
        guard isCurrent, !Task.isCancelled, loadID == request else { return }

        restorePhotos()
        if let favoriteResult {
            let ordered = chronological(favoriteResult)
            source.favorites = ordered
            LocalSnapshot.save(ordered, for: LocalSnapshot.Key.favorites, expectedGeneration: snapshotGeneration)
        }
        if let albumResult {
            let ordered = chronological(albumResult)
            source.album = ordered
            LocalSnapshot.save(ordered, for: LocalSnapshot.Key.album(albumID), expectedGeneration: snapshotGeneration)
        }
    }

    private func restorePhotos() {
        // Cache Timeline memang disimpan menaik. Urutan itu dipertahankan agar
        // foto terbaru berada di ujung bawah, sama seperti Photos utama.
        source.photos = dataManager.timelineAssets().map(\.asset)
    }

    private func admitted(_ assets: [AssetLite], scope: AssetVisibilityPolicy.Scope) -> [AssetLite] {
        guard isCurrent else { return [] }
        return AssetVisibilityPolicy(scope: scope, dataManager: dataManager).filter(assets)
    }

    private func fetchFavorites(if enabled: Bool) async -> [AssetLite]? {
        guard enabled else { return nil }
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
        guard !id.isEmpty else { return nil }
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
