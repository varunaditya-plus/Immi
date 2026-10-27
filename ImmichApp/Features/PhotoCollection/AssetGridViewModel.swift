import Foundation
import Observation

/// View model untuk koleksi foto yang isinya sekadar "hasil satu permintaan".
///
/// Cara memuatnya disuntikkan sebagai closure, bukan diturunkan jadi beberapa
/// subclass: Favorites, Archived, Trash, foto per kota, dan foto per orang hanya
/// berbeda pada satu panggilan itu — seluruh aksinya setelah termuat sama persis.
@MainActor
@Observable
final class AssetGridViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadRevision = UUID()

    // AssetLite equality compares IDs; this storage also publishes metadata changes.
    private struct AssetStorage { var assets: [AssetLite] = [] }
    private var assetStorage = AssetStorage()
    var assets: [AssetLite] {
        get { assetStorage.assets }
        set { assetStorage = AssetStorage(assets: newValue) }
    }
    var phase: LoadingPhase<Void> = .idle
    var actionError: String?

    private let assetRepo: AssetDetailRepository
    private let albumRepo: AlbumRepository
    private let dataManager: SwiftDataManager
    private let loader: () async throws -> [AssetLite]
    /// Nama potret lokal layar ini; nil berarti tidak disimpan.
    private let snapshotKey: String?

    init(
        assetRepo: AssetDetailRepository,
        albumRepo: AlbumRepository,
        snapshotKey: String? = nil,
        dataManager: SwiftDataManager? = nil,
        loader: @escaping () async throws -> [AssetLite]
    ) {
        self.assetRepo = assetRepo
        self.albumRepo = albumRepo
        self.snapshotKey = snapshotKey
        self.dataManager = dataManager ?? .shared
        self.loader = loader
    }

    /// Potret lokal dulu, jaringan menyusul.
    ///
    /// Tiga akibat, dan ketiganya yang diminta:
    ///
    /// - Tidak ada spinner untuk layar yang isinya sudah pernah dilihat.
    /// - Offline bukan berarti kosong. Kegagalan jaringan hanya menjatuhkan
    ///   layar ke error kalau memang tidak ada apa-apa untuk ditampilkan.
    /// - Penyegarannya tidak berkedip: isi yang sama persis dengan yang sudah
    ///   tergambar tidak dipasang ulang sama sekali.
    func load() async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        let request = UUID()
        loadRevision = request
        let cacheRevision = dataManager.assetMutationRevision
        if assets.isEmpty {
            // ADA potret dan potret yang BERISI adalah dua hal berbeda.
            //
            // Trash yang sudah dikosongkan menyimpan potret `[]`, dan itu
            // jawaban yang sah — "memang tidak ada apa-apa di sini". Menyamakan
            // keduanya membuat layar yang benar-benar kosong berubah jadi
            // "Failed to Load" begitu offline.
            if let cached = snapshotKey.flatMap({ LocalSnapshot.load([AssetLite].self, for: $0) }) {
                assets = cached
                phase = .loaded(())
            } else {
                phase = .loading
            }
        }

        do {
            let fetched = try await loader()
            guard snapshotGeneration == LocalSnapshot.generation, loadRevision == request,
                  dataManager.assetMutationRevision == cacheRevision else { return }
            if let snapshotKey {
                LocalSnapshot.save(fetched, for: snapshotKey, expectedGeneration: snapshotGeneration)
            }
            // Another instance may already have written this snapshot. Compare
            // against this screen's content rather than the disk write result.
            if !assets.elementsEqual(fetched, by: { $0.hasSameContent(as: $1) }) {
                assets = fetched
            }
            phase = .loaded(())
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation, loadRevision == request,
                  dataManager.assetMutationRevision == cacheRevision else { return }
            // Sudah ada jawaban yang SAH di layar — entah dari potret, entah
            // dari muatan sebelumnya — jadi kegagalannya diam.
            //
            // Diperiksa lewat `phase`, bukan lewat "isinya kosong": potret `[]`
            // juga jawaban yang sah. Tong sampah yang sudah dikosongkan memang
            // kosong, dan menukarnya dengan "Failed to Load" begitu offline
            // adalah kebohongan yang persis hendak dihindari cache ini.
            if case .loaded = phase { return }
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to load photos"))
        }
    }

    /// Status favorit ditambal di tempat, bukan lewat muat ulang — hanya satu
    /// nilai boolean yang berubah.
    func toggleFavorite(_ asset: AssetLite) async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        actionError = nil
        let newValue = !asset.isFavorite
        do {
            try await assetRepo.toggleFavorite(asset.id, to: newValue)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[index].isFavorite = newValue
            }
            cacheFavoriteIfNeeded(asset.id, value: newValue)
            persist()
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
        }
    }

    /// Mencabut favorit pada layar Favorites: fotonya keluar dari daftar, bukan
    /// sekadar berganti ikon hati — daftar itu memang isinya favorit saja.
    func unfavorite(_ ids: [String]) async {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return }
        actionError = nil
        var firstFailure: String?
        defer {
            persist()
            if snapshotGeneration == LocalSnapshot.generation { actionError = firstFailure }
        }
        for id in ids {
            do {
                try Task.checkCancellation()
                try await assetRepo.toggleFavorite(id, to: false)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
                assets.removeAll { $0.id == id }
                cacheFavoriteIfNeeded(id, value: false)
            } catch {
                guard snapshotGeneration == LocalSnapshot.generation else { return }
                if firstFailure == nil {
                    firstFailure = (error as? APIError)?.errorDescription
                        ?? String(localized: "Failed to update favorite")
                }
                if error is CancellationError || Task.isCancelled { return }
            }
        }
    }

    /// Menghapus dari PERPUSTAKAAN — ke tong sampah, atau permanen kalau
    /// fotonya memang sudah ada di sana.
    func delete(_ ids: [String], permanently: Bool = false) async {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return }
        actionError = nil
        do {
            try await assetRepo.delete(ids, force: permanently)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            loadRevision = UUID()
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photos")
        }
    }

    /// Favorit MASSAL selalu menyalakan, bukan membalik satu per satu.
    ///
    /// Seleksi bisa berisi campuran; membalik masing-masing akan menghasilkan
    /// separuh menyala separuh padam — hasil yang tidak diminta siapa pun. Tombol
    /// "Favorite" pada seleksi berarti "jadikan favorit".
    /// - Returns: true kalau semuanya diterima server.
    @discardableResult
    func setFavorite(_ ids: [String], to value: Bool) async -> Bool {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return false }
        actionError = nil
        // `defer`, bukan di ujung jalur sukses: kalau server menolak di tengah
        // daftar, yang terlanjur berubah di memori tetap harus sampai ke disk —
        // kalau tidak, layar dan potretnya berbeda sampai penulisan berikutnya.
        defer { persist() }
        do {
            for id in ids {
                try Task.checkCancellation()
                try await assetRepo.toggleFavorite(id, to: value)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index].isFavorite = value
                }
                cacheFavoriteIfNeeded(id, value: value)
            }
            return true
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
            return false
        }
    }

    /// Memindahkan seleksi ke arsip — atau mengembalikannya ke linimasa.
    ///
    /// Fotonya keluar dari daftar apa pun setelah dipindah: layar arsip berisi
    /// yang diarsipkan, layar lain berisi yang tidak.
    @discardableResult
    func setArchived(_ ids: [String], to archived: Bool) async -> Bool {
        await move(ids, to: archived ? .archive : .timeline,
            failure: String(localized: "Failed to archive photos"))
    }

    /// Memindahkan ke folder terkunci — dan itu MENGELUARKANNYA dari daftar
    /// mana pun yang sedang dibuka, karena itulah arti "terkunci".
    @discardableResult
    func setLocked(_ ids: [String]) async -> Bool {
        await move(ids, to: .locked, failure: String(localized: "Failed to move photos"))
    }

    private func move(_ ids: [String], to visibility: AssetDetailRepository.Visibility, failure: String) async -> Bool {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return false }
        actionError = nil
        defer { persist() }
        do {
            for id in ids {
                try Task.checkCancellation()
                try await assetRepo.setVisibility(id, to: visibility)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
                assets.removeAll { $0.id == id }
                cacheVisibilityIfNeeded(id, inTimeline: visibility == .timeline)
            }
            return true
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            actionError = (error as? APIError)?.errorDescription ?? failure
            return false
        }
    }

    /// Potretnya ikut diperbarui setiap kali daftarnya berubah di sini.
    ///
    /// Tanpa ini, foto yang dihapus akan muncul lagi saat layarnya dibuka
    /// offline — potret di disk masih memuatnya, dan itu justru membuat cache
    /// terasa rusak alih-alih membantu.
    private func persist() {
        guard let snapshotKey else { return }
        LocalSnapshot.save(assets, for: snapshotKey, expectedGeneration: snapshotGeneration)
    }

    private func cacheFavoriteIfNeeded(_ id: String, value: Bool) {
        loadRevision = UUID()
        if let cached = dataManager.getCachedAsset(id: id), cached.isFavorite != value {
            try? dataManager.patchCachedAsset(id, isFavorite: value)
        }
    }

    private func cacheVisibilityIfNeeded(_ id: String, inTimeline: Bool) {
        loadRevision = UUID()
        if dataManager.nonTimelineAssetIDs.contains(id) != !inTimeline
            || dataManager.getCachedAsset(id: id).map({ $0.isArchived != !inTimeline }) == true {
            try? dataManager.setTimelineVisibility([id], inTimeline: inTimeline)
        }
    }

    /// - Returns: pesan untuk pengguna; nil berarti semuanya masuk tanpa cerita.
    @discardableResult
    func addToAlbum(_ ids: [String], album: AlbumResponseDTO) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard let duplicates = try? await albumRepo.addAssets(ids, to: album.id) else {
            return String(localized: "Failed to add to album")
        }
        guard !duplicates.isEmpty else { return nil }
        // Sebagian masuk, sebagian sudah ada — dan itu dua kabar yang berbeda.
        return duplicates.count == ids.count
            ? String(localized: "Already in this album")
            : String(localized: "\(duplicates.count) already in this album")
    }

    func albums() async -> [AlbumResponseDTO] {
        (try? await albumRepo.all()) ?? []
    }

    // MARK: - Tong sampah

    private func restorable(_ candidates: [AssetLite]) -> [AssetLite] {
        RemovedAssets.shared.filter(candidates, scope: .trash)
            .filter { !DeletedServerAssetRegistry.shared.isPermanentlyDeleted($0.id) }
    }

    /// Mengembalikan foto terpilih dari tong sampah.
    func restore(_ ids: [String], using repo: TrashRepository) async {
        guard !ids.isEmpty else { return }
        actionError = nil
        // DICATAT SEBELUM dibuang dari daftar: setelah `removeAll`, tidak ada
        // lagi tempat mengambil rasio dan thumbhash-nya untuk ditulis balik ke
        // cache linimasa.
        let selected = Set(ids)
        let candidates = restorable(assets).filter { selected.contains($0.id) }
        let requestedIDs = candidates.map(\.id)
        guard !requestedIDs.isEmpty else { return }
        do {
            try await repo.restore(requestedIDs)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            loadRevision = UUID()
            let restoredAssets = restorable(candidates)
            let restoredIDs = restoredAssets.map(\.id)
            DeletedServerAssetRegistry.shared.restore(restoredIDs)
            RemovedAssets.shared.restore(restoredIDs)
            let restored = Set(requestedIDs)
            assets.removeAll { restored.contains($0.id) }
            persist()
            // Aset yang dibuang sudah tidak ada di cache linimasa, jadi ini
            // menulisnya kembali — bukan sekadar menandai.
            try? dataManager.restoreToTimeline(restoredAssets)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to restore photos")
        }
    }

    func restoreAll(using repo: TrashRepository) async {
        let candidates = restorable(assets)
        actionError = nil
        do {
            try await repo.restoreAll()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            loadRevision = UUID()
            let restoredAssets = restorable(candidates)
            DeletedServerAssetRegistry.shared.restoreAllFromTrash()
            RemovedAssets.shared.restoreAllFromTrash()
            assets.removeAll()
            persist()
            try? dataManager.restoreToTimeline(restoredAssets)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to restore photos")
        }
    }

    func emptyTrash(using repo: TrashRepository) async {
        let removedIDs = assets.map(\.id)
        actionError = nil
        do {
            try await repo.empty()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            loadRevision = UUID()
            DeletedServerAssetRegistry.shared.emptyTrash()
            RemovedAssets.shared.remove(removedIDs)
            RemovedAssets.shared.emptyTrash()
            assets.removeAll()
            persist()
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to empty trash")
        }
    }

    /// Yang gagal diunduh dilewati, bukan membatalkan seluruh operasi.
    func shareURLs(for ids: [String]) async -> [URL] {
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else { return [] }
        let urls = await assetRepo.shareFiles(ids)
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else {
            TemporaryMediaStore.remove(urls)
            return []
        }
        return urls
    }
}
