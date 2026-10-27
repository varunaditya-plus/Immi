import Foundation
import Observation

@MainActor
@Observable
final class AlbumListViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var albums: [AlbumResponseDTO] = []
    /// Kegagalan aksi sheet — sunting, tambah pengguna. Sengaja TERPISAH dari
    /// `phase`: itu milik daftar album, dan mengubahnya berarti seluruh daftar
    /// berganti jadi layar error hanya karena satu sheet gagal.
    var actionError: String?
    var phase: LoadingPhase<Void> = .idle
    var showCreateSheet = false

    private let repo: AlbumRepository

    init(repo: AlbumRepository) {
        self.repo = repo
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    ///
    /// Layar ini memanggilnya SETIAP kali dibuka, jadi tanpa potret, setiap
    /// kunjungan saat offline berakhir di "Failed to Load" — padahal daftar
    /// albumnya sudah pernah ada di layar ini beberapa detik sebelumnya.
    func loadAlbums() async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        if albums.isEmpty {
            // ADA potret dan potret yang BERISI adalah dua hal berbeda —
            // pengguna baru yang belum punya album menyimpan potret `[]`, dan
            // itu jawaban yang sah.
            if let cached = LocalSnapshot.load(
                [AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList) {
                albums = cached
                phase = .loaded(())
            } else {
                phase = .loading
            }
        }

        do {
            let fetched = try await repo.all()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if LocalSnapshot.save(fetched, for: LocalSnapshot.Key.albumsList, expectedGeneration: snapshotGeneration) || albums.isEmpty {
                albums = fetched
            }
            phase = .loaded(())
        } catch {
            // Sudah ada jawaban yang SAH di layar — entah dari potret, entah
            // dari muatan sebelumnya — jadi kegagalannya diam.
            //
            // Diperiksa lewat `phase`, bukan lewat "daftarnya kosong": potret
            // `[]` juga jawaban yang sah — pengguna yang memang belum punya
            // album. Menukarnya dengan "Failed to Load" begitu offline adalah
            // kebohongan yang persis hendak dihindari cache ini.
            if case .loaded = phase { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load albums"))
        }
    }

    /// Potretnya ikut ditulis ulang setiap daftarnya berubah di sini.
    ///
    /// Tanpa ini, album yang dihapus muncul lagi — dengan nama lamanya — saat
    /// layar dibuka offline, dan cache-nya terasa rusak alih-alih membantu.
    private func persist() {
        LocalSnapshot.save(albums, for: LocalSnapshot.Key.albumsList, expectedGeneration: snapshotGeneration)
    }

    /// - Returns: pesan kesalahan; nil berarti berhasil.
    ///
    /// Kesalahannya DIKEMBALIKAN, tidak disimpan di `phase`. `phase` milik daftar
    /// album — mengubahnya berarti seluruh daftar berganti jadi layar error hanya
    /// karena satu sheet gagal.
    func createAlbum(
        name: String,
        description: String,
        assetIds: [String]
    ) async -> String? {
        guard !name.isEmpty else { return nil }
        do {
            let newAlbum = try await repo.create(
                name: name,
                description: description.isEmpty ? nil : description,
                assetIds: assetIds)
            albums.append(newAlbum)
            persist()
            return nil
        } catch {
            return (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to create album")
        }
    }

    /// - Returns: pesan kesalahan; nil berarti perubahan sudah dikonfirmasi.
    func update(_ id: String, name: String, description: String) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }

        do {
            try await repo.update(
                id,
                name: trimmedName,
                description: .some(trimmedDescription.isEmpty ? nil : trimmedDescription))
            if let index = albums.firstIndex(where: { $0.id == id }) {
                // Ganti NILAI elemennya secara utuh. Mutasi field bersarang
                // tidak selalu memicu registrar Observation milik array,
                // sehingga List/LazyVGrid dapat tetap menampilkan nama lama.
                var updated = albums[index]
                updated.albumName = trimmedName
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

    /// Dipakai detail album untuk mengirim metadata yang baru disimpan kembali
    /// ke list/grid/sidebar yang membukanya.
    func applyAlbumUpdate(_ updated: AlbumResponseDTO) {
        guard let index = albums.firstIndex(where: { $0.id == updated.id }) else { return }
        albums[index] = updated
        persist()
    }

    func addUsers(_ userIDs: [String], to albumId: String) async {
        guard !userIDs.isEmpty else { return }
        do {
            try await repo.addUsers(userIDs, to: albumId)
            // Status `shared` ikut berubah di server, jadi daftarnya dimuat
            // ulang supaya filter Shared/Personal tetap benar.
            await loadAlbums()
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add user")
        }
    }

    func deleteAlbum(_ id: String) async {
        do {
            try await repo.delete(id)
            albums.removeAll { $0.id == id }
            persist()
            // Potret ISI album itu juga dibuang, bukan cuma barisnya dari
            // daftar. Tanpa ini berkasnya tertinggal selamanya — tidak pernah
            // dibaca, tidak pernah dibersihkan.
            LocalSnapshot.remove(LocalSnapshot.Key.album(id), expectedGeneration: snapshotGeneration)
        } catch {
            // Handle error silently for now
        }
    }

    /// Menambal jumlah dan cover dari detail album tanpa request daftar baru.
    /// Detail sudah memegang daftar aset yang benar, jadi hasilnya dapat muncul
    /// seketika di baris sidebar dan kartu All Albums.
    func applyContents(_ assets: [AssetLite], to id: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }

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
        else { return }

        updated.assetCount = assets.count
        updated.albumThumbnailAssetId = nextCover
        albums[index] = updated
        AlbumCoverStore.shared.invalidate(id)
        persist()
    }

    /// Detail album sudah menghapusnya di server. Yang tersisa di sini hanya
    /// membuang representasi bersama yang dipakai sidebar dan All Albums.
    func removeDeletedAlbum(_ id: String) {
        albums.removeAll { $0.id == id }
        persist()
    }

    func retry() async {
        await loadAlbums()
    }

    var myAlbums: [AlbumResponseDTO] {
        albums.filter { !$0.shared }
    }

    var sharedAlbums: [AlbumResponseDTO] {
        albums.filter { $0.shared }
    }
}
