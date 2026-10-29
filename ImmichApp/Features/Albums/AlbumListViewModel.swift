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
    private var loadID = UUID()
    private var restoredSnapshot = false
    private var phaseBeforeLoad: LoadingPhase<Void> = .idle
    private var actionErrorID = UUID()

    init(repo: AlbumRepository) {
        self.repo = repo
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    ///
    /// Layar ini memanggilnya SETIAP kali dibuka, jadi tanpa potret, setiap
    /// kunjungan saat offline berakhir di "Failed to Load" — padahal daftar
    /// albumnya sudah pernah ada di layar ini beberapa detik sebelumnya.
    func loadAlbums() async {
        guard canPublish else { return }
        let requestID = UUID()
        loadID = requestID
        if !phase.isLoading { phaseBeforeLoad = phase }
        let canRestoreSnapshot = !restoredSnapshot
        restoredSnapshot = true
        if albums.isEmpty {
            // ADA potret dan potret yang BERISI adalah dua hal berbeda —
            // pengguna baru yang belum punya album menyimpan potret `[]`, dan
            // itu jawaban yang sah.
            if canRestoreSnapshot, let cached = LocalSnapshot.load(
                [AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList) {
                albums = cached
                phase = .loaded(())
            } else if phase.isIdle || phase.errorMessage != nil {
                phase = .loading
            }
        }

        do {
            let fetched = try await repo.all()
            guard isCurrentLoad(requestID) else { return }
            try Task.checkCancellation()
            LocalSnapshot.save(fetched, for: LocalSnapshot.Key.albumsList, expectedGeneration: snapshotGeneration)
            albums = fetched
            phase = .loaded(())
            phaseBeforeLoad = phase
        } catch {
            guard isCurrentLoad(requestID) else { return }
            guard !Task.isCancelled, !(error is CancellationError) else {
                if phase.isLoading { phase = phaseBeforeLoad }
                return
            }
            // Sudah ada jawaban yang SAH di layar — entah dari potret, entah
            // dari muatan sebelumnya — jadi kegagalannya diam.
            //
            // Diperiksa lewat `phase`, bukan lewat "daftarnya kosong": potret
            // `[]` juga jawaban yang sah — pengguna yang memang belum punya
            // album. Menukarnya dengan "Failed to Load" begitu offline adalah
            // kebohongan yang persis hendak dihindari cache ini.
            if case .loaded = phase { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load albums"))
            phaseBeforeLoad = phase
        }
    }

    private var canPublish: Bool {
        !Task.isCancelled && snapshotGeneration == LocalSnapshot.generation
    }

    private func isCurrentLoad(_ id: UUID) -> Bool {
        snapshotGeneration == LocalSnapshot.generation && loadID == id
    }

    private func invalidateLoads() {
        loadID = UUID()
        phase = .loaded(())
        phaseBeforeLoad = phase
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
        assetIds: [String],
        onCreated: ((AlbumResponseDTO) -> Void)? = nil
    ) async -> String? {
        guard canPublish, !name.isEmpty else { return nil }
        do {
            let newAlbum = try await repo.create(
                name: name,
                description: description.isEmpty ? nil : description,
                assetIds: assetIds)
            guard canPublish else { return nil }
            invalidateLoads()
            if !albums.contains(where: { $0.id == newAlbum.id }) { albums.append(newAlbum) }
            persist()
            onCreated?(newAlbum)
            return nil
        } catch {
            guard canPublish else { return nil }
            return (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to create album")
        }
    }

    /// Dipakai detail album untuk mengirim metadata yang baru disimpan kembali
    /// ke list/grid/sidebar yang membukanya.
    func applyAlbumUpdate(_ updated: AlbumResponseDTO) {
        guard canPublish else { return }
        invalidateLoads()
        guard let index = albums.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = albums[index]
        merged.albumName = updated.albumName
        merged.description = updated.description
        merged.updatedAt = updated.updatedAt
        albums[index] = merged
        persist()
    }

    func addUsers(
        _ userIDs: [String], to albumId: String,
        onShared: ((String) -> Void)? = nil
    ) async {
        guard canPublish, !userIDs.isEmpty else { return }
        let errorID = UUID()
        actionErrorID = errorID
        actionError = nil
        do {
            try await repo.addUsers(userIDs, to: albumId)
            guard canPublish else { return }
            applyAlbumSharing(albumId)
            onShared?(albumId)
            // Preserve the confirmed sharing change even if reconciliation
            // fails or a later action invalidates its response.
            await loadAlbums()
        } catch {
            guard canPublish, actionErrorID == errorID else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add user")
        }
    }

    func applyAlbumSharing(_ id: String) {
        guard canPublish else { return }
        invalidateLoads()
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        var updated = albums[index]
        updated.shared = true
        albums[index] = updated
        persist()
    }

    @discardableResult
    func deleteAlbum(_ id: String) async -> Bool {
        guard canPublish else { return false }
        let errorID = UUID()
        actionErrorID = errorID
        actionError = nil
        do {
            try await repo.delete(id)
            guard canPublish else { return false }
            removeDeletedAlbum(id)
            return true
        } catch {
            guard canPublish, actionErrorID == errorID else { return false }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete album")
            return false
        }
    }

    /// Menambal jumlah dan cover dari detail album tanpa request daftar baru.
    /// Detail sudah memegang daftar aset yang benar, jadi hasilnya dapat muncul
    /// seketika di baris sidebar dan kartu All Albums.
    func applyContents(_ assets: [AssetLite], to id: String) {
        guard canPublish else { return }
        invalidateLoads()
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
        guard canPublish else { return }
        invalidateLoads()
        albums.removeAll { $0.id == id }
        persist()
        LocalSnapshot.remove(LocalSnapshot.Key.album(id), expectedGeneration: snapshotGeneration)
        AlbumCoverStore.shared.invalidate(id)
    }

    func retry() async {
        await loadAlbums()
    }
}
