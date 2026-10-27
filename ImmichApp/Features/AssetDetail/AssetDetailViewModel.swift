import Foundation
import Observation

@MainActor
@Observable
final class AssetDetailViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var detail: AssetResponseDTO?
    var phase: LoadingPhase<Void> = .idle
    /// Kegagalan aksi terakhir yang dipicu pengguna.
    ///
    /// `ErrorEvent`, bukan `String?`: dua kegagalan yang berbunyi sama harus
    /// tetap terhitung dua kejadian — lihat alasannya di `ErrorEvent`.
    var actionError: ErrorEvent?
    var albums: [AlbumResponseDTO] = []
    /// Album yang MEMUAT foto ini — untuk panel info, bukan untuk menu tambah.
    ///
    /// Dipisah dari `albums` karena artinya berbeda: yang satu "ke mana foto ini
    /// bisa ditambahkan", yang ini "foto ini sudah ada di mana saja". Menyatukan
    /// keduanya berarti menu tambah cuma menampilkan album yang sudah memuatnya.
    var containingAlbums: [AlbumResponseDTO] = []

    private let repo: AssetDetailRepository
    private let albumRepo: AlbumRepository?

    struct Selection: Equatable {
        let id: String
        fileprivate let revision: UUID
    }

    private enum Mutation: Hashable {
        case favorite, description, date, location, visibility, edits, delete
    }

    private struct MutationKey: Hashable {
        let id: String
        let kind: Mutation
    }

    private struct MutationContext {
        let key: MutationKey
        let revision: UUID
        let selection: Selection?
        let originalDetail: AssetResponseDTO?
    }

    private var selection: Selection?
    private var detailRequest = UUID()
    private var containingAlbumsRequest = UUID()
    private var albumListRequest = UUID()
    private var latestMutations: [MutationKey: UUID] = [:]
    private var mutationTasks: [MutationKey: (revision: UUID, task: Task<Bool, Error>)] = [:]
    private var mutationVersions: [String: UInt64] = [:]
    private var invalidatedSnapshots = Set<String>()

    init(repo: AssetDetailRepository, albumRepo: AlbumRepository? = nil) {
        self.repo = repo
        self.albumRepo = albumRepo
    }

    /// Admission happens before the view schedules its asynchronous work. A
    /// return visit to the same photo must not accept its previous visit's reads.
    @discardableResult
    func selectAsset(_ id: String) -> Selection {
        guard snapshotGeneration == LocalSnapshot.generation else {
            return Selection(id: id, revision: UUID())
        }
        if let selection, selection.id == id { return selection }
        let next = Selection(id: id, revision: UUID())
        selection = next
        detailRequest = UUID()
        containingAlbumsRequest = UUID()
        containingAlbums = []
        detail = LocalPhotoLibrary.isLocal(id) ? nil : cachedDetail(for: id)
        phase = LocalPhotoLibrary.isLocal(id) || detail != nil ? .loaded(()) : .loading
        return next
    }

    func isCurrent(_ selected: Selection) -> Bool {
        snapshotGeneration == LocalSnapshot.generation && selection == selected
    }

    func invalidateSelection() {
        selection = nil
        detailRequest = UUID()
        containingAlbumsRequest = UUID()
        albumListRequest = UUID()
        detail = nil
        containingAlbums = []
        phase = .idle
    }

    /// Daftar album untuk menu "Add to Album"; cukup dimuat sekali.
    func loadAlbumsIfNeeded() async {
        guard snapshotGeneration == LocalSnapshot.generation, albums.isEmpty, let albumRepo else { return }
        let request = UUID()
        albumListRequest = request
        let fetched = (try? await albumRepo.all()) ?? []
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled, albumListRequest == request else { return }
        albums = fetched
    }

    /// Album yang memuat foto ini. Dimuat ulang setiap kali fotonya berganti.
    ///
    /// Kegagalan dibiarkan senyap: ini keterangan tambahan di bagian paling bawah
    /// panel, dan memunculkan alert karena satu daftar tidak datang akan lebih
    /// mengganggu daripada barisnya yang tidak ada.
    func loadContainingAlbums(_ id: String?) async {
        guard let id, !LocalPhotoLibrary.isLocal(id) else {
            containingAlbumsRequest = UUID()
            containingAlbums = []
            return
        }
        let selected = selection ?? selectAsset(id)
        guard selected.id == id else { return }
        await loadContainingAlbums(selected)
    }

    func loadContainingAlbums(_ selected: Selection) async {
        guard isCurrent(selected), !LocalPhotoLibrary.isLocal(selected.id) else { return }
        guard let albumRepo else { return }
        let request = UUID()
        containingAlbumsRequest = request
        let fetched = (try? await albumRepo.albums(containing: selected.id)) ?? []
        guard !Task.isCancelled, isCurrent(selected), containingAlbumsRequest == request else { return }
        containingAlbums = fetched
    }

    func addToAlbum(_ id: String, album: AlbumResponseDTO) async {
        guard let albumRepo else { return }
        let selected = selection
        do {
            let duplicates = try await albumRepo.addAssets([id], to: album.id)
            // Toast yang sama dipakai untuk kabar biasa, bukan cuma kegagalan:
            // "sudah ada di album" bukan error, tapi tetap harus terdengar —
            // tanpa itu, menekan "Add to Album" untuk foto yang sudah ada di
            // sana tidak menghasilkan apa pun yang terlihat.
            if !duplicates.isEmpty {
                reportActionError(String(localized: "Already in this album"), id: id, selected: selected)
            }
        } catch {
            reportActionError(Self.describe(error), id: id, selected: selected)
        }
    }

    /// Potret lokal dulu, jaringan menyusul — dan kegagalannya DIAM.
    ///
    /// Memuat detail bukan sesuatu yang diminta pengguna; ia terjadi sendiri
    /// saat foto dibuka dan sekali lagi setiap kali digeser. Mengabarkan
    /// kegagalannya berarti satu kabar per geseran — dan di perjalanan tanpa
    /// sinyal, itu berubah jadi rentetan yang menghalangi hal yang justru sedang
    /// dilakukan pengguna. Yang bersuara hanya kegagalan yang MEREKA picu
    /// sendiri: favorit, bagikan, arsip, hapus.
    func load(_ id: String) async {
        await load(selectAsset(id))
    }

    func load(_ selected: Selection) async {
        guard isCurrent(selected), !Task.isCancelled else { return }
        let id = selected.id
        let request = UUID()
        detailRequest = request
        let mutationVersion = mutationVersions[id, default: 0]
        // Foto perangkat tidak punya detail di server, dan menanyakannya bukan
        // sekadar sia-sia: jawabannya 404, dan itu membuat petaknya dibuang dari
        // linimasa. Panel info-nya memang kosong — yang diketahui tentang foto
        // ini semuanya sudah ada di `AssetLite`.
        guard !LocalPhotoLibrary.isLocal(id) else {
            detail = nil
            containingAlbums = []
            phase = .loaded(())
            return
        }

        let key = LocalSnapshot.Key.assetDetail(id)

        // Foto lain, jadi detail foto SEBELUMNYA harus lepas dulu.
        //
        // Tanpa ini, satu geseran yang gagal meninggalkan panel info yang masih
        // menampilkan metadata foto lama di bawah foto yang baru — kebohongan
        // yang jauh lebih buruk daripada panel kosong.
        if detail?.id != id {
            detail = cachedDetail(for: id)
        }
        phase = detail == nil ? .loading : .loaded(())

        do {
            let fetched = try await repo.fetchAsset(id)
            guard !Task.isCancelled, isCurrent(selected), detailRequest == request else { return }
            guard mutationVersion == mutationVersions[id, default: 0] else {
                await load(selected)
                return
            }
            guard fetched.id == id else { throw APIError.unknown }
            detail = fetched
            invalidatedSnapshots.remove(id)
            LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration)
            phase = .loaded(())
        } catch {
            guard !Task.isCancelled, isCurrent(selected), detailRequest == request else { return }
            guard mutationVersion == mutationVersions[id, default: 0] else {
                await load(selected)
                return
            }
            let message = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to load asset")
            phase = .failed(message)
            // Kalau alasannya aset itu memang tidak bisa dibaca lagi, ia juga
            // dibuang dari linimasa — kalau tidak, petaknya tetap di sana dan
            // pesan ini muncul lagi setiap kali ditekan.
            UnreadableAssets.shared.report(id, error: error)
            if (error as? APIError)?.meansAssetIsUnreadable == true {
                LocalSnapshot.remove(key, expectedGeneration: snapshotGeneration)
            }
        }
    }

    /// A superseded favorite must not overwrite a newer intent in the viewer.
    /// Leaving the page does not invalidate a successful targeted write.
    @discardableResult
    func toggleFavorite(_ id: String, to value: Bool? = nil) async -> Bool {
        let mutation = beginMutation(id, kind: .favorite)
        let newValue = value ?? !(mutation.originalDetail?.isFavorite ?? false)
        do {
            return try await performMutation(mutation, patch: { $0.isFavorite = newValue }) {
                try await self.repo.toggleFavorite(id, to: newValue)
            }
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    @discardableResult
    func updateDescription(_ id: String, to text: String) async -> Bool {
        let mutation = beginMutation(id, kind: .description)
        do {
            return try await performMutation(mutation, patch: { $0.setDescription(text) }) {
                try await self.repo.updateDescription(id, to: text)
            }
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    /// Tanggal & lokasi tersimpan di beberapa field turunan (`fileCreatedAt`,
    /// `localDateTime`, `exifInfo`), jadi lebih aman memuat ulang detailnya
    /// daripada menambal satu per satu di sisi klien.
    @discardableResult
    func updateDate(_ id: String, to date: Date) async -> Bool {
        let mutation = beginMutation(id, kind: .date)
        do {
            let accepted = try await performMutation(mutation) {
                try await self.repo.updateDate(id, to: date)
            }
            if accepted, let selected = selection, selected.id == id {
                await load(selected)
            }
            return accepted
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    @discardableResult
    func updateLocation(_ id: String, latitude: Double, longitude: Double) async -> Bool {
        let mutation = beginMutation(id, kind: .location)
        do {
            let accepted = try await performMutation(mutation) {
                try await self.repo.updateLocation(id, latitude: latitude, longitude: longitude)
            }
            if accepted, let selected = selection, selected.id == id {
                await load(selected)
            }
            return accepted
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    /// Memindahkan aset keluar dari timeline (arsip / locked folder).
    /// Mengembalikan true kalau berhasil, supaya view bisa menutup layarnya —
    /// asetnya memang tidak lagi ada di daftar yang sedang dibuka.
    @discardableResult
    func move(_ id: String, to visibility: AssetDetailRepository.Visibility) async -> Bool {
        let mutation = beginMutation(id, kind: .visibility)
        do {
            return try await performMutation(mutation) {
                try await self.repo.setVisibility(id, to: visibility)
            }
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    func toggleArchive(_ id: String) async {
        let mutation = beginMutation(id, kind: .visibility)
        let newValue = !(mutation.originalDetail?.isArchived ?? false)
        do {
            _ = try await performMutation(mutation, patch: {
                $0.isArchived = newValue
                $0.visibility = newValue ? "archive" : "timeline"
            }) {
                try await self.repo.toggleArchive(id, to: newValue)
            }
        } catch {
            reportMutationError(error, mutation)
        }
    }

    /// Mengembalikan true kalau server mengonfirmasi penghapusan,
    /// supaya view bisa menutup layarnya.
    func delete(_ id: String) async -> Bool {
        let mutation = beginMutation(id, kind: .delete)
        do {
            try await repo.delete(id)
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            // Fotonya sudah tidak ada; potret detailnya tidak boleh menunggu
            // seseorang membukanya lagi untuk dibersihkan.
            if completeMutation(mutation) {
                latestMutations = latestMutations.filter { $0.key.id != id }
                LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
                if selection?.id == id || (selection == nil && detail?.id == id) {
                    detail = nil
                    containingAlbums = []
                }
            }
            return true
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    func downloadOriginalFile(_ id: String, filename: String) async -> URL? {
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else { return nil }
        let selected = selection
        do {
            let file = try await repo.downloadOriginalFile(id, filename: filename)
            guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled else {
                TemporaryMediaStore.remove(file)
                return nil
            }
            return file
        } catch {
            reportActionError(Self.describe(error), id: id, selected: selected)
            return nil
        }
    }

    @discardableResult
    func applyEdits(_ edits: [AssetEditCommand], to id: String) async -> Bool {
        let mutation = beginMutation(id, kind: .edits)
        do {
            let accepted = try await performMutation(mutation) {
                if edits.isEmpty {
                    try await self.repo.removeEdits(from: id)
                } else {
                    try await self.repo.applyEdits(edits, to: id)
                }
            }
            if accepted, let selected = selection, selected.id == id {
                await load(selected)
            }
            return accepted
        } catch {
            reportMutationError(error, mutation)
            return false
        }
    }

    func edits(for id: String) async -> [AssetEditRecord]? {
        let selected = selection
        do {
            return try await repo.edits(for: id)
        } catch {
            reportActionError(Self.describe(error), id: id, selected: selected)
            return nil
        }
    }

    @discardableResult
    func setProfileImage(_ data: Data, filename: String) async -> Bool {
        let selected = selection
        do {
            try await repo.setProfileImage(data, filename: filename)
            return snapshotGeneration == LocalSnapshot.generation && !Task.isCancelled
        } catch {
            if snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled, selection == selected {
                actionError = ErrorEvent(Self.describe(error))
            }
            return false
        }
    }

    func retry(_ id: String) async {
        let selected = selection ?? selectAsset(id)
        guard selected.id == id else { return }
        await load(selected)
    }

    private func cachedDetail(for id: String) -> AssetResponseDTO? {
        guard snapshotGeneration == LocalSnapshot.generation,
              let cached = LocalSnapshot.load(AssetResponseDTO.self, for: LocalSnapshot.Key.assetDetail(id)),
              cached.id == id else { return nil }
        return cached
    }

    /// Writes to the same field run in invocation order, including their cache
    /// updates. Different fields and different photos remain independent.
    private func performMutation(
        _ mutation: MutationContext,
        patch: ((inout AssetResponseDTO) -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) async throws -> Bool {
        let previous = mutationTasks[mutation.key]?.task
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            guard self.snapshotGeneration == LocalSnapshot.generation,
                  self.latestMutations[mutation.key] != nil else { return false }
            try await operation()
            return self.completeMutation(mutation, patch: patch)
        }
        mutationTasks[mutation.key] = (mutation.revision, task)
        defer {
            if mutationTasks[mutation.key]?.revision == mutation.revision {
                mutationTasks[mutation.key] = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginMutation(_ id: String, kind: Mutation) -> MutationContext {
        let key = MutationKey(id: id, kind: kind)
        let revision = UUID()
        latestMutations[key] = revision
        return MutationContext(key: key, revision: revision, selection: selection,
            originalDetail: detail?.id == id ? detail : cachedDetail(for: id))
    }

    @discardableResult
    private func completeMutation(
        _ mutation: MutationContext, patch: ((inout AssetResponseDTO) -> Void)? = nil
    ) -> Bool {
        guard snapshotGeneration == LocalSnapshot.generation,
              let latest = latestMutations[mutation.key] else { return false }
        let isLatest = latest == mutation.revision
        if isLatest { latestMutations[mutation.key] = nil }
        let id = mutation.key.id
        mutationVersions[id, default: 0] &+= 1
        if let patch, var updated = detail?.id == id ? detail : (cachedDetail(for: id) ?? mutation.originalDetail) {
            patch(&updated)
            // A different field may have changed server-derived metadata since
            // this DTO was captured. Only a fresh admitted read can restore it.
            if !invalidatedSnapshots.contains(id) {
                LocalSnapshot.save(updated, for: LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
            }
            if selection?.id == id || (selection == nil && detail?.id == id) { detail = updated }
        } else if patch == nil {
            // Date, location, edits and visibility affect server-derived fields.
            // An off-page success must not leave an obsolete offline snapshot.
            invalidatedSnapshots.insert(id)
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id), expectedGeneration: snapshotGeneration)
        }
        return isLatest
    }

    private func reportMutationError(_ error: Error, _ mutation: MutationContext) {
        guard latestMutations[mutation.key] == mutation.revision else { return }
        latestMutations[mutation.key] = nil
        reportActionError(Self.describe(error), id: mutation.key.id, selected: mutation.selection)
    }

    private func reportActionError(_ message: String, id: String, selected: Selection?) {
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled, selection == selected,
              selected == nil || selected?.id == id else { return }
        actionError = ErrorEvent(message)
    }

    private static func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
