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

    var assets: [AssetLite] = []
    var phase: LoadingPhase<Void> = .idle

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
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if let snapshotKey {
                // Hanya dipasang ulang kalau isinya memang berbeda — lihat
                // alasannya di `LocalSnapshot.save`.
                if LocalSnapshot.save(fetched, for: snapshotKey, expectedGeneration: snapshotGeneration) || assets.isEmpty {
                    assets = fetched
                }
            } else {
                assets = fetched
            }
            phase = .loaded(())
        } catch {
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
        let newValue = !asset.isFavorite
        do {
            try await assetRepo.toggleFavorite(asset.id, to: newValue)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[index].isFavorite = newValue
            }
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite"))
        }
    }

    /// Mencabut favorit pada layar Favorites: fotonya keluar dari daftar, bukan
    /// sekadar berganti ikon hati — daftar itu memang isinya favorit saja.
    func unfavorite(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            try? await assetRepo.toggleFavorite(id, to: false)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
        }
        let removed = Set(ids)
        assets.removeAll { removed.contains($0.id) }
        persist()
    }

    /// Menghapus dari PERPUSTAKAAN — ke tong sampah, atau permanen kalau
    /// fotonya memang sudah ada di sana.
    func delete(_ ids: [String], permanently: Bool = false) async {
        guard !ids.isEmpty else { return }
        do {
            try await assetRepo.delete(ids, force: permanently)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photos"))
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
        guard !ids.isEmpty else { return false }
        // `defer`, bukan di ujung jalur sukses: kalau server menolak di tengah
        // daftar, yang terlanjur berubah di memori tetap harus sampai ke disk —
        // kalau tidak, layar dan potretnya berbeda sampai penulisan berikutnya.
        defer { persist() }
        do {
            for id in ids {
                try await assetRepo.toggleFavorite(id, to: value)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index].isFavorite = value
                }
            }
            return true
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite"))
            return false
        }
    }

    /// Memindahkan seleksi ke arsip — atau mengembalikannya ke linimasa.
    ///
    /// Fotonya keluar dari daftar apa pun setelah dipindah: layar arsip berisi
    /// yang diarsipkan, layar lain berisi yang tidak.
    @discardableResult
    func setArchived(_ ids: [String], to archived: Bool) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: archived ? .archive : .timeline)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
            }
            let moved = Set(ids)
            assets.removeAll { moved.contains($0.id) }
            persist()
            // Linimasa dirender dari cache lokal, jadi tanpa tambalan ini
            // mengembalikan foto dari arsip tidak terlihat di tab Photos sampai
            // sync berikutnya — dan kembali ke sana untuk memeriksa adalah hal
            // pertama yang dilakukan siapa pun setelah menekannya.
            try? dataManager.setTimelineVisibility(ids, inTimeline: !archived)
            return true
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to archive photos"))
            return false
        }
    }

    /// Memindahkan ke folder terkunci — dan itu MENGELUARKANNYA dari daftar
    /// mana pun yang sedang dibuka, karena itulah arti "terkunci".
    @discardableResult
    func setLocked(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: .locked)
                guard snapshotGeneration == LocalSnapshot.generation else { return false }
            }
            let moved = Set(ids)
            assets.removeAll { moved.contains($0.id) }
            persist()
            // Terkunci berarti keluar dari linimasa — lihat `setArchived`.
            try? dataManager.setTimelineVisibility(ids, inTimeline: false)
            return true
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to move photos"))
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

    /// Mengembalikan foto terpilih dari tong sampah.
    func restore(_ ids: [String], using repo: TrashRepository) async {
        guard !ids.isEmpty else { return }
        // DICATAT SEBELUM dibuang dari daftar: setelah `removeAll`, tidak ada
        // lagi tempat mengambil rasio dan thumbhash-nya untuk ditulis balik ke
        // cache linimasa.
        let restoredAssets = assets.filter { ids.contains($0.id) }
        do {
            try await repo.restore(ids)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            DeletedServerAssetRegistry.shared.restore(ids)
            let restored = Set(ids)
            assets.removeAll { restored.contains($0.id) }
            persist()
            // Aset yang dibuang sudah tidak ada di cache linimasa, jadi ini
            // menulisnya kembali — bukan sekadar menandai.
            try? dataManager.restoreToTimeline(restoredAssets)
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to restore photos"))
        }
    }

    func restoreAll(using repo: TrashRepository) async {
        do {
            try await repo.restoreAll()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            DeletedServerAssetRegistry.shared.restoreAllFromTrash()
            assets.removeAll()
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to restore photos"))
        }
    }

    func emptyTrash(using repo: TrashRepository) async {
        do {
            try await repo.empty()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            DeletedServerAssetRegistry.shared.emptyTrash()
            assets.removeAll()
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to empty trash"))
        }
    }

    /// Yang gagal diunduh dilewati, bukan membatalkan seluruh operasi.
    func shareURLs(for ids: [String]) async -> [URL] {
        var urls: [URL] = []
        for id in ids {
            guard let data = try? await assetRepo.downloadOriginal(id) else { continue }
            if let url = try? TemporaryMediaStore.createShareFile(
                data: data,
                suggestedFilename: "\(id).jpg") {
                urls.append(url)
            }
        }
        return urls
    }
}
