import SwiftUI

/// Grid foto generik untuk tujuan-tujuan di Collections.
///
/// Satu layar dipakai ulang oleh Favorites, Videos, Archived, Trash, Locked
/// Folder, dan foto per kota — semuanya hanya berbeda pada filter pencariannya,
/// jadi memberi masing-masing layarnya sendiri cuma menggandakan kode yang sama.
struct AssetCollectionView: View {
    let title: LocalizedStringKey
    /// Filter yang membedakan satu koleksi dari lainnya.
    let request: SearchRequestDTO
    /// true hanya untuk layar Favorites, di mana "keluarkan dari koleksi"
    /// berarti mencabut favoritnya.
    var isFavoritesCollection = false
    var layout: PhotoCollectionLayout = .hero

    @Environment(SessionManager.self) private var session
    @State private var vm: AssetGridViewModel?
    @State private var albumPickerAsset: AssetLite?
    @State private var sharedLink: SharedLinkPresentation?
    /// Kabar singkat dari aksi — mis. "sudah ada di album ini".
    @State private var actionMessage: ErrorEvent?

    var body: some View {
        screen
            .sheet(item: $albumPickerAsset) { asset in
                AlbumPickerLoader { album in
                    Task {
                        if let message = await vm?.addToAlbum([asset.id], album: album) {
                            actionMessage = ErrorEvent(message)
                        }
                    }
                }
            }
            .sheet(item: $sharedLink) { ShareSheet(url: $0.url) }
            .errorToast($actionMessage)
            .task { await start() }
    }

    private var screen: some View {
        PhotoCollectionScreen(
            title: title,
            layout: layout,
            assets: vm?.assets ?? [],
            phase: vm?.phase ?? .loading,
            actionError: Binding(
                get: { vm?.actionError },
                set: { vm?.actionError = $0 }),
            emptyState: emptyState,
            onRetry: { Task { await vm?.load() } },
            onToggleFavorite: { asset in
                if isFavoritesCollection && asset.isFavorite {
                    await vm?.unfavorite([asset.id])
                } else {
                    await vm?.toggleFavorite(asset)
                }
            },
            onDelete: { await vm?.delete($0) },
            shareURLs: { await vm?.shareURLs(for: $0) ?? [] },
            removal: removal,
            onAddToAlbum: { albumPickerAsset = $0 },
            onFavoriteSelection: { await vm?.setFavorite($0, to: true) },
            onArchiveSelection: archiveSelection,
            onUnlockSelection: unlockSelection,
            onMoveToLocked: moveToLocked,
            onShareLink: { createSharedLink(for: $0) },
            selectionMenu: selectionMenu)
    }

    /// Tautan publik tidak ditawarkan untuk arsip.
    ///
    /// Mengarsipkan berarti menyingkirkan foto dari pandangan sehari-hari;
    /// menawarkan tombol untuk menyebarkannya justru di layar itu bertentangan
    /// dengan alasan foto-foto itu ada di sana.
    private var selectionMenu: ((Set<String>) -> [SelectionMenuAction])? {
        guard request.visibility != "archive" else { return nil }
        return { ids in
            [SelectionMenuAction(title: "Share Link", systemImage: "link") {
                createSharedLink(for: Array(ids))
            }]
        }
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            vm?.actionError = nil
            do {
                let link = try await repo.create(assetIds: ids)
                guard let url = link.publicURL(base: session.baseURL) else {
                    vm?.actionError = String(localized: "Failed to create shared link")
                    return
                }
                sharedLink = SharedLinkPresentation(url: url)
            } catch {
                vm?.actionError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link")
            }
        }
    }

    /// Arsip punya arti KEBALIKAN di layar Archived.
    ///
    /// Tombol yang sama di layar yang isinya memang arsip berarti mengembalikan
    /// ke linimasa, bukan mengarsipkan lagi.
    ///
    /// Dua layar tidak mendapat tombolnya sama sekali. Trash, karena memindahkan
    /// sampah ke arsip tidak berarti apa pun. Dan Locked Folder — ini yang
    /// berbahaya: memindahkannya ke `archive` berarti MENGELUARKANNYA dari
    /// folder terkunci, kebalikan dari yang diharapkan siapa pun yang menekan
    /// tombol berlambang kotak arsip.
    private var archiveSelection: (([String]) async -> Void)? {
        guard request.withDeleted != true, request.visibility != "locked" else { return nil }
        let toArchive = request.visibility != "archive"
        return { ids in await vm?.setArchived(ids, to: toArchive) }
    }

    /// Mengeluarkan dari folder terkunci — hanya berarti DI folder itu.
    private var unlockSelection: (([String]) async -> Void)? {
        guard request.visibility == "locked" else { return nil }
        return { ids in await vm?.setArchived(ids, to: false) }
    }

    /// Memindahkan KE folder terkunci.
    ///
    /// Tidak ditawarkan di tong sampah (foto di sana tidak berada di
    /// perpustakaan) maupun di folder terkunci itu sendiri (sudah di sana).
    private var moveToLocked: (([String]) async -> Void)? {
        guard request.withDeleted != true, request.visibility != "locked" else { return nil }
        return { ids in await vm?.setLocked(ids) }
    }

    /// Hanya Favorites yang punya arti untuk "dikeluarkan tanpa dihapus".
    private var removal: PhotoCollectionRemoval? {
        guard isFavoritesCollection else { return nil }
        return PhotoCollectionRemoval(title: "Remove from Favorites") { ids in
            await vm?.unfavorite(ids)
        }
    }

    /// Layar ini dipakai ulang untuk Favorites, Archived, Locked Folder, dan
    /// foto per kota — potretnya dibedakan dari permintaan yang membentuknya,
    /// bukan dari judulnya, supaya "Balikpapan" dan "Bogor" tidak saling
    /// menimpa.
    private var snapshotKey: String? {
        if request.isFavorite == true { return LocalSnapshot.Key.favorites }
        switch request.visibility {
        case "archive": return LocalSnapshot.Key.archived
        // Folder terkunci sengaja TIDAK dipotret. Isinya justru yang paling
        // tidak boleh tergambar tanpa server mengizinkannya lebih dulu.
        case "locked": return nil
        default: break
        }
        if let city = request.city { return "collection.city.\(city)" }
        return nil
    }

    private var emptyState: PhotoCollectionEmptyState? {
        guard request.visibility == "archive" else { return nil }
        return PhotoCollectionEmptyState(
            title: "Archive is Empty",
            systemImage: "archivebox",
            description: "Archived photos will appear here.")
    }

    private func start() async {
        if vm == nil {
            let api = APIClient(session: session)
            let searchRepo = SearchRepository(api: api)
            let request = request
            vm = AssetGridViewModel(
                assetRepo: AssetDetailRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                snapshotKey: snapshotKey,
                loader: {
                    let items = try await searchRepo.allMetadata(request)
                    return items.map(AssetLite.init)
                })
        }
        // SETIAP kali, bukan sekali.
        //
        // Dulu dijaga `if case .idle` supaya kembali dari layar detail tidak
        // menarik ulang seluruh daftar. Penjaga itu sekarang justru merugikan:
        // `load()` menggambar dari potret lebih dulu, tidak pernah menampilkan
        // spinner, dan tidak memasang ulang apa pun kalau isinya sama — jadi
        // penyegarannya tak terlihat. Yang hilang bersama penjaga itu adalah
        // layar yang terkunci pada potret karena permintaan pertamanya gagal.
        await vm?.load()
    }
}

/// Pembungkus `AlbumPickerSheet` yang memuat daftar albumnya sendiri.
///
/// Layar yang tidak memelihara daftar album (Favorites, foto per orang) tidak
/// perlu menariknya di muka hanya untuk berjaga-jaga — sheet-nya mungkin tidak
/// pernah dibuka sama sekali.
struct AlbumPickerLoader: View {
    var onSelect: (AlbumResponseDTO) -> Void

    @Environment(SessionManager.self) private var session
    @State private var albums: [AlbumResponseDTO] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                AlbumPickerSheet(albums: albums, onSelect: onSelect)
            }
        }
        .task {
            let repo = AlbumRepository(api: APIClient(session: session))
            albums = (try? await repo.all()) ?? []
            isLoading = false
        }
    }
}
