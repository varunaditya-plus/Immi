import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadRequest = UUID()
    private var albumRequest = UUID()
    private var peopleRequest = UUID()
    private var albumUpdates: [String: UUID] = [:]
    private var actionErrorID = UUID()
    private var restoredSnapshots = false

    private var loadedMemories: [MemoryStory] = []
    var memories: [MemoryStory] {
        get {
            guard snapshotGeneration == LocalSnapshot.generation else { return [] }
            let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
            return loadedMemories.compactMap { $0.filteringAssets(using: policy) }
        }
        set { loadedMemories = newValue }
    }
    var albums: [AlbumResponseDTO] = []
    var recentAlbums: [AlbumResponseDTO] { Array(albums.prefix(Self.rowLimit)) }
    // AssetLite equality compares IDs; this storage also publishes metadata changes.
    private struct FavoriteStorage { var assets: [AssetLite] = [] }
    private var favoriteStorage = FavoriteStorage()
    var favorites: [AssetLite] {
        get {
            guard snapshotGeneration == LocalSnapshot.generation else { return [] }
            return AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).filter(favoriteStorage.assets)
        }
        set { favoriteStorage = FavoriteStorage(assets: newValue) }
    }
    private struct FavoriteResponse {
        let revision: UUID
        let assets: [AssetLite]
    }
    private var favoriteRequest = UUID()
    var people: [PersonDTO] = []
    var actionError: String?

    /// Isinya sudah pernah selesai dimuat.
    ///
    /// Dibaca view untuk membedakan "belum tahu" dari "memang kosong". Sebelum
    /// ini ada, baris album dan orang menampilkan "Nothing here yet" pada
    /// pembukaan pertama — pernyataan yang tegas padahal permintaannya bahkan
    /// belum dikirim.
    private(set) var hasLoaded = false

    private let memoriesRepo: MemoriesRepository
    private let albumRepo: AlbumRepository
    private let peopleRepo: PeopleRepository
    private let searchRepo: SearchRepository
    private let assetRepo: AssetDetailRepository
    private let dataManager: SwiftDataManager

    init(
        memoriesRepo: MemoriesRepository,
        albumRepo: AlbumRepository,
        peopleRepo: PeopleRepository,
        searchRepo: SearchRepository,
        assetRepo: AssetDetailRepository,
        dataManager: SwiftDataManager? = nil
    ) {
        self.memoriesRepo = memoriesRepo
        self.albumRepo = albumRepo
        self.peopleRepo = peopleRepo
        self.searchRepo = searchRepo
        self.assetRepo = assetRepo
        self.dataManager = dataManager ?? .shared
    }

    /// Dipakai `task` layar, yang berjalan ulang SETIAP KALI tab dibuka lagi.
    ///
    /// Tanpa penjaga ini, berpindah ke Library selalu berarti empat permintaan
    /// jaringan baru — dan layarnya menunggu sampai keempatnya selesai. Isinya
    /// jarang berubah dalam hitungan detik; menyegarkannya cukup lewat tarikan.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Semua bagian dimuat BERSAMAAN, bukan berurutan.
    ///
    /// Masing-masing berdiri sendiri dan mengisi baris yang berbeda; menunggu
    /// satu per satu hanya menambah jeda tanpa alasan. Kegagalan salah satu
    /// juga tidak menjatuhkan yang lain — barisnya sekadar tampil kosong.
    func load() async {
        guard canPublish else { return }
        let request = UUID()
        loadRequest = request
        let albumsID = UUID()
        albumRequest = albumsID
        let peopleID = UUID()
        peopleRequest = peopleID
        let favoritesID = UUID()
        favoriteRequest = favoritesID
        // POTRET LOKAL DULU — sebelum satu permintaan pun dikirim.
        //
        // Ini yang membuat Library terasa mulus dan tidak lagi kosong saat
        // offline. Kegagalan jaringan di bawah menghasilkan `nil`, bukan `[]`,
        // sehingga yang sudah tergambar dibiarkan berdiri; `[]` yang tegas hanya
        // datang dari server yang benar-benar menjawab "memang tidak ada".
        restoreSnapshots()

        async let memories = fetchMemories()
        async let albums = fetchAlbums()
        async let favorites = fetchFavorites(revision: favoritesID)
        async let people = fetchPeople()

        // Ditunggu SEKALIGUS lalu dipasang bersama, bukan `self.x = await x`
        // berturut-turut.
        //
        // Tiap `await` adalah satu titik henti, dan tiap pemasangan sesudahnya
        // memicu render tersendiri — barisnya jadi terisi satu per satu dari
        // atas ke bawah, terlihat seperti animasi yang tidak pernah diminta.
        let (loadedMemories, loadedAlbums, loadedFavorites, loadedPeople) =
            await (memories, albums, favorites, people)
        guard canPublish, loadRequest == request else { return }

        // Kenangan TIDAK dipotret: isinya "hari ini, tahun-tahun sebelumnya",
        // jadi potret kemarin bukan sekadar basi — ia salah tanggal.
        if let loadedMemories { self.memories = loadedMemories }

        let acceptedAlbums = albumRequest == albumsID ? loadedAlbums : nil
        let acceptedPeople = peopleRequest == peopleID ? loadedPeople : nil
        let acceptedFavorites = loadedFavorites?.revision == favoriteRequest ? loadedFavorites : nil
        apply(acceptedAlbums, to: \.albums, key: LocalSnapshot.Key.libraryAlbums)
        applyFavorites(acceptedFavorites)
        apply(acceptedPeople, to: \.people, key: LocalSnapshot.Key.libraryPeople)

        // Hanya kalau ADA yang benar-benar dijawab server. Menyalakannya setelah
        // keempatnya gagal berarti dua hal buruk sekaligus: barisnya menulis
        // "Nothing here yet" atas nama server yang tidak pernah bicara, dan
        // `loadIfNeeded` tidak akan pernah mencoba lagi.
        if loadedMemories != nil || acceptedAlbums != nil
            || acceptedFavorites != nil || acceptedPeople != nil {
            hasLoaded = true
        }
    }

    private func restoreSnapshots() {
        guard !restoredSnapshots else { return }
        restoredSnapshots = true
        if albums.isEmpty,
           let cached = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums) {
            albums = cached
        }
        if favoriteStorage.assets.isEmpty,
           let cached = LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.libraryFavorites) {
            favorites = cached
        }
        if people.isEmpty,
           let cached = LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople) {
            people = cached
        }
        // `hasLoaded` SENGAJA tidak disentuh di sini.
        //
        // Artinya "server sudah menjawab", dan view memakainya untuk memutuskan
        // kapan boleh menulis "Nothing here yet". Menyalakannya karena satu
        // potret kebetulan ada akan membuat baris LAIN — yang potretnya belum
        // pernah tersimpan — langsung menyatakan dirinya kosong padahal
        // permintaannya masih berjalan. Baris yang punya isi tidak butuh
        // bendera ini: isinya sendiri yang membuatnya tidak kosong.
    }

    private var canPublish: Bool {
        !Task.isCancelled && snapshotGeneration == LocalSnapshot.generation
    }

    /// A disk snapshot is a best-effort copy of an admitted response.
    private func apply<T: Codable>(
        _ fetched: [T]?,
        to keyPath: ReferenceWritableKeyPath<LibraryViewModel, [T]>,
        key: String
    ) {
        guard let fetched, canPublish else { return }
        LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration)
        self[keyPath: keyPath] = fetched
    }

    // MARK: - Aksi album

    /// - Returns: pesan kesalahan; nil berarti perubahan sudah dikonfirmasi.
    func updateAlbum(_ id: String, name: String, description: String) async -> String? {
        guard canPublish else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let action = UUID()
        albumUpdates[id] = action
        defer { finishAlbumUpdate(id, action: action) }

        do {
            try await albumRepo.update(
                id,
                name: trimmed,
                description: .some(trimmedDescription.isEmpty ? nil : trimmedDescription))
            guard isCurrentAlbumUpdate(id, action: action) else { return nil }
            albumRequest = UUID()
            // Kartu diperbarui di tempat, bukan lewat muat ulang: sampul album
            // tidak berubah karena namanya berubah, dan memuat ulang seluruh
            // baris hanya membuatnya berkedip.
            if let index = albums.firstIndex(where: { $0.id == id }) {
                var updated = albums[index]
                updated.albumName = trimmed
                updated.description = trimmedDescription.isEmpty ? nil : trimmedDescription
                updated.updatedAt = Date()
                applyAlbumUpdate(updated)
            }
            return nil
        } catch {
            guard isCurrentAlbumUpdate(id, action: action), !(error is CancellationError) else { return nil }
            return (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update album")
        }
    }

    /// Detail/daftar album hidup dengan view model sendiri. Metadata hasil edit
    /// dikirim kembali lewat metode ini supaya kartu Library tidak menunggu
    /// refresh jaringan berikutnya.
    func applyAlbumUpdate(_ updated: AlbumResponseDTO) {
        guard canPublish else { return }
        albumRequest = UUID()
        albumUpdates[updated.id] = nil
        guard let index = albums.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = albums[index]
        merged.albumName = updated.albumName
        merged.description = updated.description
        merged.updatedAt = updated.updatedAt ?? merged.updatedAt
        albums[index] = merged
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
    }

    func applyAlbumCreation(_ album: AlbumResponseDTO) {
        guard canPublish else { return }
        albumRequest = UUID()
        guard !albums.contains(where: { $0.id == album.id }) else { return }
        albums.append(album)
        albums.sort { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
    }

    func applyAlbumSharing(_ id: String) {
        guard canPublish else { return }
        albumRequest = UUID()
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        var updated = albums[index]
        updated.shared = true
        albums[index] = updated
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
    }

    func addUsers(_ userIDs: [String], to albumId: String) async {
        guard canPublish, !userIDs.isEmpty else { return }
        let errorID = UUID()
        actionErrorID = errorID
        actionError = nil
        do {
            try await albumRepo.addUsers(userIDs, to: albumId)
            guard canPublish else { return }
            applyAlbumSharing(albumId)
            await refreshAlbums()
        } catch {
            guard canPublish, actionErrorID == errorID, !(error is CancellationError) else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add user")
        }
    }

    func deleteAlbum(_ id: String) async {
        guard canPublish else { return }
        let errorID = UUID()
        actionErrorID = errorID
        actionError = nil
        do {
            try await albumRepo.delete(id)
            guard canPublish else { return }
            removeDeletedAlbum(id)
        } catch {
            guard canPublish, actionErrorID == errorID, !(error is CancellationError) else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete album")
            return
        }
    }

    func removeDeletedAlbum(_ id: String) {
        guard canPublish else { return }
        albumRequest = UUID()
        albumUpdates[id] = nil
        albums.removeAll { $0.id == id }
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
        LocalSnapshot.remove(LocalSnapshot.Key.album(id), expectedGeneration: snapshotGeneration)
        AlbumCoverStore.shared.invalidate(id)
    }

    /// Menambal kartu album seketika dari daftar aset yang sudah benar di layar
    /// detail. Nilai balik true berarti ada perubahan yang perlu direkonsiliasi
    /// lagi dengan `/albums` di belakang layar.
    @discardableResult
    func applyAlbumContents(_ assets: [AssetLite], to id: String) -> Bool {
        guard canPublish else { return false }
        albumRequest = UUID()
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return false }

        var updated = albums[index]
        let remainingIDs = Set(assets.map(\.id))
        let newestID = assets.max(by: { $0.createdAt < $1.createdAt })?.id
        let currentCoverStillExists = updated.albumThumbnailAssetId
            .map(remainingIDs.contains) ?? false
        let nextCover = currentCoverStillExists
            ? updated.albumThumbnailAssetId
            : newestID

        guard updated.assetCount != assets.count
                || updated.albumThumbnailAssetId != nextCover
        else { return false }

        updated.assetCount = assets.count
        updated.albumThumbnailAssetId = nextCover
        var patched = albums
        patched[index] = updated
        albums = patched
        AlbumCoverStore.shared.invalidate(id)
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
        return true
    }

    /// Hanya menyegarkan baris album; perubahan dari Album Detail tidak perlu
    /// menembak ulang Memories, Favorites, dan People.
    func refreshAlbums(invalidatingCoverFor id: String? = nil) async {
        guard canPublish else { return }
        if let id { AlbumCoverStore.shared.invalidate(id) }
        let request = UUID()
        albumRequest = request
        let fetched = await fetchAlbums()
        guard canPublish, albumRequest == request else { return }
        apply(fetched, to: \.albums, key: LocalSnapshot.Key.libraryAlbums)
    }

    private func isCurrentAlbumUpdate(_ id: String, action: UUID) -> Bool {
        canPublish && albumUpdates[id] == action
    }

    private func finishAlbumUpdate(_ id: String, action: UUID) {
        if albumUpdates[id] == action { albumUpdates[id] = nil }
    }

    func applyPersonRename(_ id: String, to name: String) {
        guard canPublish else { return }
        peopleRequest = UUID()
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        var updated = people[index]
        updated.name = name
        people[index] = updated
        LocalSnapshot.save(people, for: LocalSnapshot.Key.libraryPeople, expectedGeneration: snapshotGeneration)
    }

    func refreshFavorites() async {
        guard canPublish else { return }
        let request = UUID()
        favoriteRequest = request
        applyFavorites(await fetchFavorites(revision: request))
    }

    private func applyFavorites(_ fetched: FavoriteResponse?) {
        guard let fetched, snapshotGeneration == LocalSnapshot.generation,
              !Task.isCancelled, fetched.revision == favoriteRequest else { return }
        LocalSnapshot.save(fetched.assets, for: LocalSnapshot.Key.libraryFavorites,
            expectedGeneration: snapshotGeneration)
        if !favoriteStorage.assets.elementsEqual(fetched.assets, by: { $0.hasSameContent(as: $1) }) {
            favorites = fetched.assets
        }
    }

    private func removeFavorite(_ id: String) {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        favoriteRequest = UUID()
        favoriteStorage = FavoriteStorage(assets: favoriteStorage.assets.filter { $0.id != id })
        LocalSnapshot.save(favoriteStorage.assets, for: LocalSnapshot.Key.libraryFavorites,
            expectedGeneration: snapshotGeneration)
    }

    // MARK: - Aksi foto

    /// Baris Favorites berisi HANYA foto favorit, jadi mencabut favorit berarti
    /// foto itu keluar dari baris — bukan sekadar berganti ikon hati.
    func toggleFavorite(_ asset: AssetLite) async {
        actionError = nil
        let newValue = !asset.isFavorite
        do {
            try await assetRepo.toggleFavorite(asset.id, to: newValue)
            if newValue {
                await refreshFavorites()
            } else {
                removeFavorite(asset.id)
            }
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
        }
    }

    func archive(_ asset: AssetLite) async {
        actionError = nil
        do {
            try await assetRepo.toggleArchive(asset.id, to: true)
            removeFavorite(asset.id)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to archive photo")
        }
    }

    func delete(_ asset: AssetLite) async -> Bool {
        actionError = nil
        do {
            try await assetRepo.delete(asset.id)
            removeFavorite(asset.id)
            return true
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photo")
            return false
        }
    }

    func addToAlbum(_ asset: AssetLite, album: AlbumResponseDTO) async {
        actionError = nil
        do {
            let duplicates = try await albumRepo.addAssets([asset.id], to: album.id)
            if !duplicates.isEmpty {
                // "Sudah ada di album" bukan kegagalan, tapi tetap harus
                // terdengar — tanpa itu aksinya tidak menghasilkan apa pun
                // yang terlihat.
                actionError = String(localized: "Already in this album")
            }
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add to album")
        }
    }

    /// Unduh berkas asli ke lokasi sementara untuk dibagikan lewat share sheet
    /// (URL server polos akan kena 401).
    func shareURL(for asset: AssetLite) async -> URL? {
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
              AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: asset.id) else { return nil }
        do {
            let url = try await assetRepo.shareFile(asset.id)
            guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
                  AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: asset.id) else {
                TemporaryMediaStore.remove(url)
                return nil
            }
            return url
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to prepare share")
            return nil
        }
    }

    /// Setiap baris di Library hanya deretan mendatar — belasan kartu sudah
    /// lebih dari cukup untuk digulir, dan sisanya ada di layar lengkapnya.
    /// Menarik seluruh isi perpustakaan ke sini membuat tab-nya lama terbuka
    /// tanpa ada yang benar-benar melihat kartu ke-200.
    private static let rowLimit = 15

    // Keempatnya mengembalikan OPSIONAL, dan itu bedanya dengan sebelumnya.
    //
    // Dulu kegagalan jaringan berubah jadi `[]` di sini, dan `[]` tidak bisa
    // dibedakan dari jawaban server yang memang kosong — akibatnya offline
    // selalu berarti "Nothing here yet" di setiap baris. `nil` berarti "tidak
    // ada kabar", dan pemanggilnya membiarkan yang sudah tergambar.

    private func fetchMemories() async -> [MemoryStory]? {
        guard let memories = try? await memoriesRepo.getMemories() else { return nil }
        return MemoryStory.build(from: memories, limit: Self.rowLimit)
    }

    /// Keep every album for the picker and offline snapshot. The Library row
    /// uses `recentAlbums` to show only the most recently updated albums.
    private func fetchAlbums() async -> [AlbumResponseDTO]? {
        guard let all = try? await albumRepo.all() else { return nil }
        return all.sorted { lhs, rhs in
            (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
        }
    }

    private func fetchPeople() async -> [PersonDTO]? {
        guard let all = try? await peopleRepo.all(size: Self.rowLimit) else { return nil }
        return all.filter { !$0.isHidden }
    }

    private func fetchFavorites(revision: UUID) async -> FavoriteResponse? {
        let request = SearchRequestDTO(page: 1, isFavorite: true, size: Self.rowLimit)
        guard let response = try? await searchRepo.metadataSearch(request) else { return nil }
        return FavoriteResponse(revision: revision,
            assets: response.assets.items.filter(\.isTimelineVisible).map(AssetLite.init))
    }
}
