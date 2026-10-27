import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var memories: [MemoryStory] = []
    var albums: [AlbumResponseDTO] = []
    var favorites: [AssetLite] = []
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

    init(
        memoriesRepo: MemoriesRepository,
        albumRepo: AlbumRepository,
        peopleRepo: PeopleRepository,
        searchRepo: SearchRepository,
        assetRepo: AssetDetailRepository
    ) {
        self.memoriesRepo = memoriesRepo
        self.albumRepo = albumRepo
        self.peopleRepo = peopleRepo
        self.searchRepo = searchRepo
        self.assetRepo = assetRepo
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
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        // POTRET LOKAL DULU — sebelum satu permintaan pun dikirim.
        //
        // Ini yang membuat Library terasa mulus dan tidak lagi kosong saat
        // offline. Kegagalan jaringan di bawah menghasilkan `nil`, bukan `[]`,
        // sehingga yang sudah tergambar dibiarkan berdiri; `[]` yang tegas hanya
        // datang dari server yang benar-benar menjawab "memang tidak ada".
        restoreSnapshots()

        async let memories = fetchMemories()
        async let albums = fetchAlbums()
        async let favorites = fetchFavorites()
        async let people = fetchPeople()

        // Ditunggu SEKALIGUS lalu dipasang bersama, bukan `self.x = await x`
        // berturut-turut.
        //
        // Tiap `await` adalah satu titik henti, dan tiap pemasangan sesudahnya
        // memicu render tersendiri — barisnya jadi terisi satu per satu dari
        // atas ke bawah, terlihat seperti animasi yang tidak pernah diminta.
        let (loadedMemories, loadedAlbums, loadedFavorites, loadedPeople) =
            await (memories, albums, favorites, people)
        guard snapshotGeneration == LocalSnapshot.generation else { return }

        // Kenangan TIDAK dipotret: isinya "hari ini, tahun-tahun sebelumnya",
        // jadi potret kemarin bukan sekadar basi — ia salah tanggal.
        if let loadedMemories { self.memories = loadedMemories }

        apply(loadedAlbums, to: \.albums, key: LocalSnapshot.Key.libraryAlbums)
        apply(loadedFavorites, to: \.favorites, key: LocalSnapshot.Key.libraryFavorites)
        apply(loadedPeople, to: \.people, key: LocalSnapshot.Key.libraryPeople)

        // Hanya kalau ADA yang benar-benar dijawab server. Menyalakannya setelah
        // keempatnya gagal berarti dua hal buruk sekaligus: barisnya menulis
        // "Nothing here yet" atas nama server yang tidak pernah bicara, dan
        // `loadIfNeeded` tidak akan pernah mencoba lagi.
        if loadedMemories != nil || loadedAlbums != nil
            || loadedFavorites != nil || loadedPeople != nil {
            hasLoaded = true
        }
    }

    private func restoreSnapshots() {
        if albums.isEmpty,
           let cached = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums) {
            albums = cached
        }
        if favorites.isEmpty,
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

    /// Hasil `nil` (gagal) dibiarkan; hasil yang sama persis tidak dipasang ulang.
    private func apply<T: Codable>(
        _ fetched: [T]?,
        to keyPath: ReferenceWritableKeyPath<LibraryViewModel, [T]>,
        key: String
    ) {
        guard let fetched, snapshotGeneration == LocalSnapshot.generation else { return }
        if LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration) || self[keyPath: keyPath].isEmpty {
            self[keyPath: keyPath] = fetched
        }
    }

    // MARK: - Aksi album

    /// - Returns: pesan kesalahan; nil berarti perubahan sudah dikonfirmasi.
    func updateAlbum(_ id: String, name: String, description: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        do {
            try await albumRepo.update(
                id,
                name: trimmed,
                description: .some(trimmedDescription.isEmpty ? nil : trimmedDescription))
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
            return (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update album")
        }
    }

    /// Detail/daftar album hidup dengan view model sendiri. Metadata hasil edit
    /// dikirim kembali lewat metode ini supaya kartu Library tidak menunggu
    /// refresh jaringan berikutnya.
    func applyAlbumUpdate(_ updated: AlbumResponseDTO) {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        guard let index = albums.firstIndex(where: { $0.id == updated.id }) else { return }
        albums[index] = updated
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
    }

    func addUsers(_ userIDs: [String], to albumId: String) async {
        guard !userIDs.isEmpty else { return }
        do {
            try await albumRepo.addUsers(userIDs, to: albumId)
            apply(await fetchAlbums(), to: \.albums, key: LocalSnapshot.Key.libraryAlbums)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add user")
        }
    }

    func deleteAlbum(_ id: String) async {
        do {
            try await albumRepo.delete(id)
            albums.removeAll { $0.id == id }
            LocalSnapshot.save(albums, for: LocalSnapshot.Key.libraryAlbums, expectedGeneration: snapshotGeneration)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete album")
        }
    }

    /// Menambal kartu album seketika dari daftar aset yang sudah benar di layar
    /// detail. Nilai balik true berarti ada perubahan yang perlu direkonsiliasi
    /// lagi dengan `/albums` di belakang layar.
    @discardableResult
    func applyAlbumContents(_ assets: [AssetLite], to id: String) -> Bool {
        guard snapshotGeneration == LocalSnapshot.generation else { return false }
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
        if let id { AlbumCoverStore.shared.invalidate(id) }
        apply(await fetchAlbums(), to: \.albums, key: LocalSnapshot.Key.libraryAlbums)
    }

    // MARK: - Aksi foto

    /// Baris Favorites berisi HANYA foto favorit, jadi mencabut favorit berarti
    /// foto itu keluar dari baris — bukan sekadar berganti ikon hati.
    func toggleFavorite(_ asset: AssetLite) async {
        let newValue = !asset.isFavorite
        do {
            try await assetRepo.toggleFavorite(asset.id, to: newValue)
            if newValue {
                apply(await fetchFavorites(), to: \.favorites, key: LocalSnapshot.Key.libraryFavorites)
            } else {
                favorites.removeAll { $0.id == asset.id }
                LocalSnapshot.save(favorites, for: LocalSnapshot.Key.libraryFavorites, expectedGeneration: snapshotGeneration)
            }
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
        }
    }

    func archive(_ asset: AssetLite) async {
        do {
            try await assetRepo.toggleArchive(asset.id, to: true)
            favorites.removeAll { $0.id == asset.id }
            LocalSnapshot.save(favorites, for: LocalSnapshot.Key.libraryFavorites, expectedGeneration: snapshotGeneration)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to archive photo")
        }
    }

    func delete(_ asset: AssetLite) async -> Bool {
        do {
            try await assetRepo.delete(asset.id)
            favorites.removeAll { $0.id == asset.id }
            LocalSnapshot.save(favorites, for: LocalSnapshot.Key.libraryFavorites, expectedGeneration: snapshotGeneration)
            return true
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photo")
            return false
        }
    }

    func addToAlbum(_ asset: AssetLite, album: AlbumResponseDTO) async {
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
        do {
            let data = try await assetRepo.downloadOriginal(asset.id)
            let filename = "\(asset.id).\(asset.isVideo ? "mov" : "jpg")"
            return try TemporaryMediaStore.createShareFile(
                data: data,
                suggestedFilename: filename)
        } catch {
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

    /// `/albums` tidak punya parameter batas, jadi pemotongannya di klien —
    /// tapi urutannya ditentukan di sini: yang paling baru disentuh lebih dulu.
    private func fetchAlbums() async -> [AlbumResponseDTO]? {
        guard let all = try? await albumRepo.all() else { return nil }
        let sorted = all.sorted { lhs, rhs in
            (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
        }
        return Array(sorted.prefix(Self.rowLimit))
    }

    private func fetchPeople() async -> [PersonDTO]? {
        guard let all = try? await peopleRepo.all(size: Self.rowLimit) else { return nil }
        return all.filter { !$0.isHidden }
    }

    private func fetchFavorites() async -> [AssetLite]? {
        let request = SearchRequestDTO(page: 1, isFavorite: true, size: Self.rowLimit)
        guard let response = try? await searchRepo.metadataSearch(request) else { return nil }
        return response.assets.items.map(AssetLite.init)
    }
}
