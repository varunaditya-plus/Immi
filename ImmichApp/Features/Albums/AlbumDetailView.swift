import SwiftUI

/// Detail album: sampul besar + grid, memakai `PhotoCollectionScreen`.
///
/// Yang tersisa di sini hanyalah hal-hal yang MEMANG khas album — menu Edit /
/// Add User / Shared Link / Delete, sheet menambah foto, dan arti khusus
/// "keluarkan dari album". Tata letak, mode pilih, dan context menu-nya dipakai
/// bersama dengan Favorites dan foto per orang.
struct AlbumDetailView: View {
    let album: AlbumResponseDTO
    /// Library memakai daftar aset yang sudah benar di layar ini untuk menambal
    /// count dan cover tanpa menunggu halaman induk dimuat ulang.
    var onContentsChanged: (([AssetLite]) -> Void)? = nil
    /// Metadata album yang berhasil disimpan dikirim kembali ke list/grid yang
    /// membuka detail ini.
    var onAlbumChanged: ((AlbumResponseDTO) -> Void)? = nil
    /// Sidebar memakai callback ini untuk menghapus tab album yang baru saja
    /// dihapus dan kembali ke All Albums.
    var onDeleted: (() -> Void)? = nil

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AlbumDetailViewModel?
    @State private var showAddSheet = false
    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var showAddUserSheet = false
    @State private var sharedLink: SharedLinkPresentation?
    @State private var albumPickerSelection: SelectedAssetIDs?
    @State private var albumPickerAsset: AssetLite?
    @State private var actionMessage: ErrorEvent?
    /// Salinan lokal album, supaya hasil sunting langsung terlihat di sampul
    /// tanpa menunggu daftar album di layar sebelumnya dimuat ulang.
    @State private var editedAlbum: AlbumResponseDTO?

    var body: some View {
        screen
            .sheet(isPresented: $showAddSheet) { addSheet }
            .sheet(isPresented: $showEditSheet) { editSheet }
            .sheet(isPresented: $showAddUserSheet) { addUserSheet }
            .sheet(item: $sharedLink) { link in
                ShareSheet(url: link.url)
            }
            .sheet(item: $albumPickerAsset) { asset in
                albumPicker(for: [asset.id])
            }
            .sheet(item: $albumPickerSelection) { selection in
                albumPicker(for: selection.ids)
            }
            .errorToast($actionMessage)
            .task { await start() }
            .onChange(of: assets.count) { _, _ in reportContents() }
            .onDisappear { reportContents() }
    }

    private var screen: some View {
        PhotoCollectionScreen(
            title: LocalizedStringKey(currentAlbum.albumName),
            subtitle: currentAlbum.description,
            assets: assets,
            phase: vm?.phase ?? .loading,
            onRetry: { Task { await vm?.retry(album.id) } },
            onToggleFavorite: { await vm?.toggleFavorite($0) },
            onDelete: { await vm?.deleteAssets($0) },
            shareURLs: { await vm?.shareURLs(for: $0) ?? [] },
            onAddPhotos: { showAddSheet = true },
            removal: PhotoCollectionRemoval(title: "Remove from Album") { ids in
                await vm?.removeAssets(ids, from: album.id)
            },
            onAddToAlbum: { albumPickerAsset = $0 },
            onFavoriteSelection: { await vm?.setFavorite($0, to: true) },
            onArchiveSelection: { await vm?.setArchived($0, to: true) },
            onMoveToLocked: { await vm?.setLocked($0) },
            onShareLink: { createAssetLink(for: $0) },
            keepsTabBarVisibleOnRegularWidth: true,
            selectionMenu: selectionMenu,
            optionsConfirmation: SelectionConfirmation(
                title: String(localized: "Delete “\(currentAlbum.albumName)”?"),
                message: String(localized: "The photos will stay in your library."),
                options: [SelectionConfirmationOption(
                    title: String(localized: "Delete Album"),
                    isDestructive: true,
                    handler: deleteAlbum)]),
            optionsConfirmationPresented: $showDeleteConfirm,
            options: {
                // Isinya sama persis dengan context menu di daftar album —
                // lihat AlbumActionsMenu.
                AlbumActionsMenu(
                    onEdit: { showEditSheet = true },
                    onAddUser: { showAddUserSheet = true },
                    onCreateLink: { createSharedLink() },
                    onDelete: { showDeleteConfirm = true })
            })
    }

    private func start() async {
        if vm == nil {
            let api = APIClient(session: session)
            vm = AlbumDetailViewModel(
                timelineRepo: TimelineRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                assetRepo: AssetDetailRepository(api: api))
        }
        await vm?.loadAlbumDetail(
            album.id,
            expectedAssetCount: album.assetCount)
    }

    private var assets: [AssetLite] {
        vm?.assets ?? []
    }

    private var currentAlbum: AlbumResponseDTO {
        editedAlbum ?? album
    }

    private func reportContents() {
        guard let vm, case .loaded = vm.phase else { return }
        onContentsChanged?(vm.assets)
    }

    // MARK: - Sheet khas album

    private var editSheet: some View {
        AlbumEditSheet(album: currentAlbum) { updated in
            editedAlbum = updated
            onAlbumChanged?(updated)
        }
    }

    private var addUserSheet: some View {
        AlbumAddUserSheet(album: currentAlbum) { userIDs in
            Task { await vm?.addUsers(userIDs, to: album.id) }
        }
    }

    private var addSheet: some View {
        AddPhotosToAlbumSheet(existingIDs: Set(assets.map(\.id))) { ids in
            Task { await vm?.addAssets(ids, to: album.id) }
        }
    }

    /// Menu elipsis mode pilih — isinya sama dengan Photos.
    ///
    /// "Move to Locked Folder" ditambahkan `PhotoCollectionScreen` sendiri dari
    /// `onMoveToLocked`, supaya semua layar memakai susunan yang sama.
    private func selectionMenu(_ ids: Set<String>) -> [SelectionMenuAction] {
        [
            SelectionMenuAction(title: "Share Link", systemImage: "link") {
                createAssetLink(for: Array(ids))
            },
            SelectionMenuAction(
                title: "Add to Album",
                systemImage: "rectangle.stack.badge.plus"
            ) {
                albumPickerSelection = SelectedAssetIDs(ids: Array(ids))
            },
        ]
    }

    private func albumPicker(for ids: [String]) -> some View {
        AlbumPickerLoader { album in
            Task {
                if let message = await vm?.addToOtherAlbum(ids, album: album) {
                    actionMessage = ErrorEvent(message)
                }
            }
        }
    }

    /// Tautan untuk FOTO, bukan untuk albumnya — dua hal berbeda di layar yang
    /// sama, jadi namanya dibedakan.
    private func createAssetLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            guard let link = try? await repo.create(assetIds: ids),
                  let url = link.publicURL(base: session.baseURL)
            else { return }
            sharedLink = SharedLinkPresentation(url: url)
        }
    }

    private func createSharedLink() {
        Task {
            guard let link = await vm?.createSharedLink(albumId: album.id),
                  let url = link.publicURL(base: session.baseURL)
            else { return }
            sharedLink = SharedLinkPresentation(url: url)
        }
    }

    private func deleteAlbum() {
        Task {
            if await vm?.deleteAlbum(album.id) == true {
                onDeleted?()
                dismiss()
            }
        }
    }
}

@MainActor
@Observable
final class AlbumDetailViewModel {
    private let snapshotGeneration = LocalSnapshot.generation

    var assets: [AssetLite] = []
    var phase: LoadingPhase<Void> = .idle

    private let timelineRepo: TimelineRepository
    private let albumRepo: AlbumRepository
    private let assetRepo: AssetDetailRepository
    /// Album yang sedang dibuka; dipakai untuk menamai potret lokalnya.
    private var albumId: String?
    /// Count dari daftar album adalah fallback pagination saat server tidak
    /// mengirim continuation metadata dengan benar.
    private var expectedAssetCount: Int?

    init(
        timelineRepo: TimelineRepository,
        albumRepo: AlbumRepository,
        assetRepo: AssetDetailRepository
    ) {
        self.timelineRepo = timelineRepo
        self.albumRepo = albumRepo
        self.assetRepo = assetRepo
    }

    func updateAlbum(_ id: String, name: String, description: String) async -> String? {
        do {
            try await albumRepo.update(
                id,
                name: name,
                description: .some(description.isEmpty ? nil : description))
            return nil
        } catch {
            return (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update album")
        }
    }

    func addUsers(_ userIDs: [String], to albumId: String) async {
        guard !userIDs.isEmpty else { return }
        try? await albumRepo.addUsers(userIDs, to: albumId)
    }

    func createSharedLink(albumId: String) async -> SharedLinkDTO? {
        try? await albumRepo.createSharedLink(albumId: albumId)
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
                persist()
            }
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite"))
        }
    }

    /// Favorit MASSAL selalu menyalakan, bukan membalik satu per satu: seleksi
    /// bisa berisi campuran, dan membalik masing-masing menghasilkan separuh
    /// menyala separuh padam.
    func setFavorite(_ ids: [String], to value: Bool) async {
        guard !ids.isEmpty else { return }
        // Lihat alasan `defer` di AssetGridViewModel.setFavorite.
        defer { persist() }
        do {
            for id in ids {
                try await assetRepo.toggleFavorite(id, to: value)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index].isFavorite = value
                }
            }
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite"))
        }
    }

    /// Mengarsipkan TIDAK mengeluarkan foto dari album.
    ///
    /// Album adalah kumpulan pilihan pengguna; arsip adalah status foto itu di
    /// perpustakaan. Keduanya berdiri sendiri, jadi daftarnya dibiarkan utuh.
    func setArchived(_ ids: [String], to archived: Bool) async {
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: archived ? .archive : .timeline)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
            }
            // Linimasa dirender dari cache lokal — lihat AssetGridViewModel.
            try? SwiftDataManager.shared.setTimelineVisibility(ids, inTimeline: !archived)
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to archive photos"))
        }
    }

    /// Menghapus dari PERPUSTAKAAN, bukan sekadar mengeluarkan dari album.
    func deleteAssets(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await assetRepo.delete(ids)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photos"))
        }
    }

    /// Memindahkan ke folder terkunci; fotonya keluar dari album di layar ini.
    func setLocked(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try await assetRepo.setVisibility(id, to: .locked)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
            }
            let moved = Set(ids)
            assets.removeAll { moved.contains($0.id) }
            persist()
            // Linimasa dirender dari cache lokal — lihat AssetGridViewModel.
            try? SwiftDataManager.shared.setTimelineVisibility(ids, inTimeline: false)
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to move photos"))
        }
    }

    /// Menambahkan ke album LAIN dari dalam sebuah album.
    ///
    /// - Returns: pesan untuk pengguna; nil berarti semuanya masuk tanpa cerita.
    func addToOtherAlbum(_ ids: [String], album: AlbumResponseDTO) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard let duplicates = try? await albumRepo.addAssets(ids, to: album.id) else {
            return String(localized: "Failed to add to album")
        }
        guard !duplicates.isEmpty else { return nil }
        return duplicates.count == ids.count
            ? String(localized: "Already in this album")
            : String(localized: "\(duplicates.count) already in this album")
    }

    /// Potretnya ikut ditulis ulang setiap daftarnya berubah di sini — kalau
    /// tidak, foto yang sudah dikeluarkan muncul lagi saat album dibuka offline.
    private func persist() {
        guard let albumId else { return }
        LocalSnapshot.save(assets, for: LocalSnapshot.Key.album(albumId), expectedGeneration: snapshotGeneration)
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

    /// Aset dibuang dari daftar lokal lebih dulu, tanpa memuat ulang album.
    ///
    /// Memuat ulang berarti menarik seluruh bucket lagi hanya untuk kehilangan
    /// beberapa baris — dan grid akan berkedip kosong sesaat.
    func removeAssets(_ ids: [String], from albumId: String) async {
        guard !ids.isEmpty else { return }
        do {
            try await albumRepo.removeAssets(ids, from: albumId)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to remove photos"))
        }
    }

    /// Setelah menambah, album dimuat ulang — urutan aset baru ditentukan
    /// server, jadi menyisipkannya sendiri berisiko meleset dari urutan asli.
    func addAssets(_ ids: [String], to albumId: String) async {
        guard !ids.isEmpty else { return }
        // Duplikat di layar album itu sendiri sengaja DIABAIKAN: sheet
        // penambah foto sudah menyaring yang sudah ada (`existingIDs`), jadi
        // kalau sampai muncul, itu balapan dengan perubahan dari perangkat lain
        // — dan hasilnya tetap benar setelah dimuat ulang di bawah.
        _ = try? await albumRepo.addAssets(ids, to: albumId)
        await loadAlbumDetail(albumId)
    }

    @discardableResult
    func deleteAlbum(_ id: String) async -> Bool {
        do {
            try await albumRepo.delete(id)
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            // Potretnya ikut dibuang. Album yang sudah tidak ada tidak boleh
            // meninggalkan berkas yang akan terus dibaca kalau id-nya kebetulan
            // dipakai lagi.
            LocalSnapshot.remove(LocalSnapshot.Key.album(id), expectedGeneration: snapshotGeneration)
            return true
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete album"))
            return false
        }
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    ///
    /// Album disegarkan lewat pencarian metadata publik dengan pagination.
    /// Potret lokal tetap dipasang lebih dulu agar offline tidak berarti kosong.
    func loadAlbumDetail(
        _ albumId: String,
        expectedAssetCount: Int? = nil
    ) async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        self.albumId = albumId
        if let expectedAssetCount {
            self.expectedAssetCount = expectedAssetCount
        }
        let key = LocalSnapshot.Key.album(albumId)
        if assets.isEmpty {
            if let cached = LocalSnapshot.load([AssetLite].self, for: key) {
                assets = cached
                phase = .loaded(())
            } else {
                phase = .loading
            }
        }

        do {
            // GET /albums/{id} tidak lagi menyertakan daftar aset. Jangan pakai
            // `/timeline/*`: route itu Internal dan bisa berubah tanpa notice.
            let fetched = try await timelineRepo.albumAssets(
                albumId,
                expectedCount: self.expectedAssetCount)
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration) || assets.isEmpty {
                assets = fetched
            }
            phase = .loaded(())
        } catch {
            // Sudah ada jawaban yang sah di layar — potret maupun muatan
            // sebelumnya — jadi kegagalannya diam. Album yang memang kosong pun
            // punya potret `[]` yang sah, jadi yang diperiksa `phase`, bukan
            // "isinya kosong".
            if case .loaded = phase { return }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load album"))
        }
    }

    func retry(_ albumId: String) async {
        await loadAlbumDetail(albumId)
    }
}

#Preview {
    let album = AlbumResponseDTO(
        id: "album-1",
        albumName: "Summer Vacation",
        description: nil,
        assetCount: 42,
        albumThumbnailAssetId: nil,
        shared: false,
        createdAt: Date(),
        assets: nil
    )
    AlbumDetailView(album: album)
        .environment(SessionManager())
}
