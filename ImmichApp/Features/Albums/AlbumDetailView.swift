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
    var onContentsChanged: (([AssetLite]) -> Void)?
    /// Metadata album yang berhasil disimpan dikirim kembali ke list/grid yang
    /// membuka detail ini.
    var onAlbumChanged: ((AlbumResponseDTO) -> Void)?
    /// Sidebar memakai callback ini untuk menghapus tab album yang baru saja
    /// dihapus dan kembali ke All Albums.
    var onDeleted: (() -> Void)?
    var onShared: (() -> Void)?

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

    init(
        album: AlbumResponseDTO,
        onContentsChanged: (([AssetLite]) -> Void)? = nil,
        onAlbumChanged: ((AlbumResponseDTO) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil,
        onShared: (() -> Void)? = nil,
        viewModel: AlbumDetailViewModel? = nil
    ) {
        self.album = album
        self.onContentsChanged = onContentsChanged
        self.onAlbumChanged = onAlbumChanged
        self.onDeleted = onDeleted
        self.onShared = onShared
        _vm = State(initialValue: viewModel)
    }

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
    }

    private var screen: some View {
        PhotoCollectionScreen(
            title: LocalizedStringKey(currentAlbum.albumName),
            subtitle: currentAlbum.description,
            assets: assets,
            phase: vm?.phase ?? .loading,
            actionError: Binding(
                get: { vm?.actionError },
                set: { vm?.actionError = $0 }),
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
        vm?.observeContents(for: album.id, onChange: onContentsChanged)
        await vm?.loadAlbumDetail(album.id)
    }

    private var assets: [AssetLite] {
        vm?.assets ?? []
    }

    private var currentAlbum: AlbumResponseDTO {
        editedAlbum ?? album
    }

    // MARK: - Sheet khas album

    private var editSheet: some View {
        AlbumEditSheet(album: currentAlbum) { updated in
            editedAlbum = updated
            onAlbumChanged?(updated)
        }
    }

    private var addUserSheet: some View {
        AlbumAddUserSheet { userIDs in
            if await vm?.addUsers(userIDs, to: album.id) == true {
                var updated = currentAlbum
                updated.shared = true
                editedAlbum = updated
                onShared?()
            }
            defer { vm?.actionError = nil }
            return vm?.actionError
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
            do {
                let link = try await repo.create(assetIds: ids)
                guard let url = link.publicURL(base: session.baseURL) else {
                    throw APIError.invalidURL
                }
                sharedLink = SharedLinkPresentation(url: url)
            } catch {
                actionMessage = ErrorEvent((error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link"))
            }
        }
    }

    private func createSharedLink() {
        Task {
            guard let link = await vm?.createSharedLink(albumId: album.id) else { return }
            guard let url = link.publicURL(base: session.baseURL) else {
                vm?.actionError = String(localized: "Failed to create shared link")
                return
            }
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
    private var loadRevision = UUID()
    private var hasAuthoritativeContents = false
    private var contentsObserver: (albumID: String, notify: ([AssetLite]) -> Void)?
    private var lastReportedIDs: [String]?

    private var canWork: Bool {
        snapshotGeneration == LocalSnapshot.generation && !Task.isCancelled
    }

    func observeContents(for albumID: String, onChange: (([AssetLite]) -> Void)?) {
        guard canWork else { return }
        contentsObserver = onChange.map { (albumID, $0) }
        lastReportedIDs = nil
    }

    private func reportConfirmedContents() {
        guard canWork, hasAuthoritativeContents,
              let observer = contentsObserver, observer.albumID == albumId else { return }
        let ids = assets.map(\.id)
        guard lastReportedIDs != ids else { return }
        lastReportedIDs = ids
        observer.notify(assets)
    }

    private func reportMembershipMutation() async {
        guard canWork else { return }
        if hasAuthoritativeContents { reportConfirmedContents() }
        else if let albumId, contentsObserver?.albumID == albumId {
            // A successful action does not make an old disk snapshot complete.
            await loadAlbumDetail(albumId)
        }
    }


    // AssetLite equality compares IDs; this storage also publishes metadata changes.
    private struct AssetStorage { var assets: [AssetLite] = [] }
    private var assetStorage = AssetStorage()
    var assets: [AssetLite] {
        get { assetStorage.assets }
        set { assetStorage = AssetStorage(assets: newValue) }
    }
    var phase: LoadingPhase<Void> = .idle
    var actionError: String?

    private let timelineRepo: TimelineRepository
    private let albumRepo: AlbumRepository
    private let assetRepo: AssetDetailRepository
    private let dataManager: SwiftDataManager
    /// Album yang sedang dibuka; dipakai untuk menamai potret lokalnya.
    private var albumId: String?

    init(
        timelineRepo: TimelineRepository,
        albumRepo: AlbumRepository,
        assetRepo: AssetDetailRepository,
        dataManager: SwiftDataManager? = nil
    ) {
        self.timelineRepo = timelineRepo
        self.albumRepo = albumRepo
        self.assetRepo = assetRepo
        self.dataManager = dataManager ?? .shared
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

    @discardableResult
    func addUsers(_ userIDs: [String], to albumId: String) async -> Bool {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
              !userIDs.isEmpty else { return false }
        actionError = nil
        do {
            try await albumRepo.addUsers(userIDs, to: albumId)
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return false }
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  snapshotGeneration == LocalSnapshot.generation else { return false }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add user")
            return false
        }
    }

    func createSharedLink(albumId: String) async -> SharedLinkDTO? {
        actionError = nil
        do {
            return try await albumRepo.createSharedLink(albumId: albumId)
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to create shared link")
            return nil
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
                persist()
            }
            cacheFavoriteIfNeeded(asset.id, value: newValue)
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
        }
    }

    /// Favorit MASSAL selalu menyalakan, bukan membalik satu per satu: seleksi
    /// bisa berisi campuran, dan membalik masing-masing menghasilkan separuh
    /// menyala separuh padam.
    func setFavorite(_ ids: [String], to value: Bool) async {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return }
        actionError = nil
        // Lihat alasan `defer` di AssetGridViewModel.setFavorite.
        defer { persist() }
        do {
            for id in ids {
                try Task.checkCancellation()
                try await assetRepo.toggleFavorite(id, to: value)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index].isFavorite = value
                }
                cacheFavoriteIfNeeded(id, value: value)
            }
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to update favorite")
        }
    }

    /// Mengarsipkan TIDAK mengeluarkan foto dari album.
    ///
    /// Album adalah kumpulan pilihan pengguna; arsip adalah status foto itu di
    /// perpustakaan. Keduanya berdiri sendiri, jadi daftarnya dibiarkan utuh.
    func setArchived(_ ids: [String], to archived: Bool) async {
        guard !ids.isEmpty, snapshotGeneration == LocalSnapshot.generation else { return }
        actionError = nil
        do {
            for id in ids {
                try Task.checkCancellation()
                try await assetRepo.setVisibility(id, to: archived ? .archive : .timeline)
                guard snapshotGeneration == LocalSnapshot.generation else { return }
                cacheVisibilityIfNeeded(id, inTimeline: !archived)
            }
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to archive photos")
        }
    }

    /// Menghapus dari PERPUSTAKAAN, bukan sekadar mengeluarkan dari album.
    func deleteAssets(_ ids: [String]) async {
        guard !ids.isEmpty, canWork else { return }
        actionError = nil
        do {
            try await assetRepo.delete(ids)
            guard canWork else { return }
            loadRevision = UUID()
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
            await reportMembershipMutation()
        } catch {
            guard canWork else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete photos")
        }
    }

    /// Memindahkan ke folder terkunci; fotonya keluar dari album di layar ini.
    func setLocked(_ ids: [String]) async {
        guard !ids.isEmpty, canWork else { return }
        actionError = nil
        var changed = false
        do {
            for id in ids {
                try Task.checkCancellation()
                try await assetRepo.setVisibility(id, to: .locked)
                guard canWork else { return }
                assets.removeAll { $0.id == id }
                cacheVisibilityIfNeeded(id, inTimeline: false)
                persist()
                changed = true
                reportConfirmedContents()
            }
        } catch {
            guard canWork else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to move photos")
        }
        if changed, !hasAuthoritativeContents { await reportMembershipMutation() }
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

    /// Hanya id yang dikonfirmasi server dikeluarkan dari daftar lokal.
    ///
    /// Memuat ulang berarti menarik seluruh bucket lagi hanya untuk kehilangan
    /// beberapa baris — dan grid akan berkedip kosong sesaat.
    func removeAssets(_ ids: [String], from albumId: String) async {
        guard canWork, !ids.isEmpty else { return }
        actionError = nil
        do {
            try await albumRepo.removeAssets(ids, from: albumId)
            guard canWork else { return }
            loadRevision = UUID()
            let removed = Set(ids)
            assets.removeAll { removed.contains($0.id) }
            persist()
            await reportMembershipMutation()
        } catch {
            guard canWork else { return }
            if let mutation = error as? AlbumMutationError {
                let confirmed = mutation.succeededIDs.intersection(ids)
                if !confirmed.isEmpty { loadRevision = UUID() }
                assets.removeAll { confirmed.contains($0.id) }
                if !confirmed.isEmpty {
                    persist()
                    await reportMembershipMutation()
                }
            }
            guard canWork else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to remove photos")
        }
    }

    /// Setelah menambah, album dimuat ulang — urutan aset baru ditentukan
    /// server, jadi menyisipkannya sendiri berisiko meleset dari urutan asli.
    func addAssets(_ ids: [String], to albumId: String) async {
        guard canWork, !ids.isEmpty else { return }
        actionError = nil
        // Duplikat di layar album itu sendiri sengaja DIABAIKAN: sheet
        // penambah foto sudah menyaring yang sudah ada (`existingIDs`), jadi
        // kalau sampai muncul, itu balapan dengan perubahan dari perangkat lain
        // — dan hasilnya tetap benar setelah dimuat ulang di bawah.
        do {
            _ = try await albumRepo.addAssets(ids, to: albumId)
            guard canWork else { return }
            hasAuthoritativeContents = false
            if !(await loadAlbumDetail(albumId)) {
                guard canWork else { return }
                actionError = String(localized: "Failed to load album")
            }
        } catch {
            guard canWork else { return }
            if let mutation = error as? AlbumMutationError,
               !mutation.succeededIDs.isEmpty || !mutation.duplicateIDs.isEmpty {
                hasAuthoritativeContents = false
                await loadAlbumDetail(albumId)
            }
            guard canWork else { return }
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to add to album")
        }
    }

    @discardableResult
    func deleteAlbum(_ id: String) async -> Bool {
        actionError = nil
        do {
            try await albumRepo.delete(id)
            guard snapshotGeneration == LocalSnapshot.generation else { return false }
            loadRevision = UUID()
            // Potretnya ikut dibuang. Album yang sudah tidak ada tidak boleh
            // meninggalkan berkas yang akan terus dibaca kalau id-nya kebetulan
            // dipakai lagi.
            LocalSnapshot.remove(LocalSnapshot.Key.album(id), expectedGeneration: snapshotGeneration)
            return true
        } catch {
            actionError = (error as? APIError)?.errorDescription
                ?? String(localized: "Failed to delete album")
            return false
        }
    }

    /// Potret lokal dulu, jaringan menyusul — lihat `LocalSnapshot`.
    ///
    /// Album disegarkan lewat pencarian metadata publik dengan pagination.
    /// Potret lokal tetap dipasang lebih dulu agar offline tidak berarti kosong.
    @discardableResult
    func loadAlbumDetail(_ albumId: String) async -> Bool {
        guard canWork else { return false }
        let request = UUID()
        loadRevision = request
        let cacheRevision = dataManager.assetMutationRevision
        if let previousID = self.albumId, previousID != albumId {
            assets = []
            phase = .idle
        }
        if contentsObserver?.albumID != albumId {
            contentsObserver = nil
            lastReportedIDs = nil
        }
        self.albumId = albumId
        hasAuthoritativeContents = false
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
            let fetched = try await timelineRepo.albumAssets(albumId)
            guard canWork, loadRevision == request,
                  dataManager.assetMutationRevision == cacheRevision else { return false }
            LocalSnapshot.save(fetched, for: key, expectedGeneration: snapshotGeneration)
            if !assets.elementsEqual(fetched, by: { $0.hasSameContent(as: $1) }) {
                assets = fetched
            }
            phase = .loaded(())
            hasAuthoritativeContents = true
            reportConfirmedContents()
            return true
        } catch {
            guard canWork, loadRevision == request,
                  dataManager.assetMutationRevision == cacheRevision else { return false }
            // Sudah ada jawaban yang sah di layar — potret maupun muatan
            // sebelumnya — jadi kegagalannya diam. Album yang memang kosong pun
            // punya potret `[]` yang sah, jadi yang diperiksa `phase`, bukan
            // "isinya kosong".
            if case .loaded = phase { return false }
            phase = .failed((error as? APIError)?.errorDescription ?? String(localized: "Failed to load album"))
            return false
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
