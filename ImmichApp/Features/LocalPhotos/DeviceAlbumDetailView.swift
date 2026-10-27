import SwiftUI

/// Detail album perangkat — sampul besar + grid, sama seperti detail album
/// server, lewat `PhotoCollectionScreen` yang sama.
///
/// Yang dibedakan bukan tampilannya melainkan aksinya, dan itu bukan pilihan
/// gaya: favorite, archive, dan album adalah gagasan milik SERVER. Foto yang
/// belum pernah diunggah tidak punya tempat untuk menyimpannya. Yang tersisa
/// adalah yang memang bisa dilakukan di sini — mengunggah, membagikan, dan
/// menghapus.
struct DeviceAlbumDetailView: View {
    let album: LocalAlbum

    @Environment(SessionManager.self) private var session
    @State private var backup = BackupService.shared
    @State private var photos: [LocalPhoto] = []
    @State private var uploadedIDs: Set<String> = []
    @State private var phase: LoadingPhase<Void> = .loading
    @State private var actionError: ErrorEvent?
    @State private var deviceRemoval: Task<Void, Never>?

    var body: some View {
        PhotoCollectionScreen(
            title: LocalizedStringKey(album.title),
            subtitle: subtitle,
            assets: assets,
            phase: phase,
            onRetry: { Task { await load() } },
            // Foto ini belum tentu ada di server, jadi tidak ada yang bisa
            // difavoritkan.
            onToggleFavorite: { _ in },
            onDelete: { await delete($0) },
            shareURLs: { await shareURLs(for: $0) },
            onUpload: { await upload($0) },
            // Menghapus dari perangkat itu PERMANEN — tidak ada Trash milik
            // Immich yang menampungnya. Yang menampungnya "Recently Deleted"
            // milik iOS, dan itu di luar jangkauan aplikasi ini.
            deletesPermanently: true,
            selectionMenu: { selectionMenu(for: $0) })
            .task {
                backup.configure(session: session)
                await load()
            }
            .errorToast($actionError)
            .cancelDeviceCopyRemoval { deviceRemoval?.cancel() }
            // Unggahan yang selesai — dari sini maupun dari pencadangan latar —
            // mengubah lencana dan isi menunya.
            .onChange(of: backup.backedUp) { _, _ in refreshUploaded() }
            // Penghapusan dari Photos/aplikasi lain harus langsung membuang
            // petaknya dan pilihan "Delete from Device" yang sudah tidak sah.
            .onChange(of: LocalPhotoLibrary.shared.revision) { _, _ in
                Task { await load() }
            }
    }

    private var subtitle: String? {
        // Jumlahnya diambil dari yang BENAR-BENAR terbaca, bukan dari `count`
        // milik album: keduanya berbeda kalau ada foto yang dihapus di antara
        // daftar album dibaca dan album ini dibuka.
        photos.isEmpty ? nil : String(localized: "\(photos.count) items on this device")
    }

    /// Urutan dibalik jadi MENURUN.
    ///
    /// `fetchPhotos` mengembalikannya menaik karena linimasa menggabungkannya
    /// dengan cache server yang juga menaik. Di layar, yang terbaru harus di
    /// atas — sama seperti album mana pun.
    private var assets: [AssetLite] {
        photos.reversed().map { photo in
            AssetLite(
                id: LocalPhotoLibrary.assetID(for: photo.id),
                isVideo: photo.isVideo,
                ratio: photo.ratio,
                thumbhash: nil,
                createdAt: photo.createdAt,
                duration: photo.duration,
                // Inilah yang menentukan isi menunya: yang belum terunggah dapat
                // "Upload", yang sudah dapat "Delete from Device".
                origin: uploadedIDs.contains(photo.id) ? .both : .device)
        }
    }

    private func load() async {
        if photos.isEmpty { phase = .loading }
        let fetched = await LocalPhotoLibrary.shared.photos(inAlbum: album.id)
        guard !Task.isCancelled else { return }
        photos = fetched
        refreshUploaded()
        phase = .loaded(())
    }

    private func refreshUploaded() {
        uploadedIDs = SwiftDataManager.shared.uploadedLocalIdentifiers()
    }

    // MARK: - Aksi mode pilih

    /// Menu elipsis mode pilih: hanya yang berlaku untuk seleksinya.
    ///
    /// Dirakit dari isi seleksi, bukan ditampilkan selalu lalu dimatikan.
    /// "Upload" pada seleksi yang semuanya sudah terunggah adalah tombol yang
    /// tidak melakukan apa-apa, dan tombol semacam itu membuat orang menekan
    /// dua kali untuk memastikan.
    private func selectionMenu(for ids: Set<String>) -> [SelectionMenuAction] {
        let locals = ids.map(LocalPhotoLibrary.localIdentifier(from:))
        var items: [SelectionMenuAction] = []

        if locals.contains(where: { !uploadedIDs.contains($0) }) {
            items.append(SelectionMenuAction(
                title: "Upload",
                systemImage: "arrow.up.circle"
            ) {
                Task { await upload(Array(ids)) }
            })
        }

        if locals.contains(where: { uploadedIDs.contains($0) }) {
            items.append(SelectionMenuAction(
                title: "Delete from Device",
                systemImage: "iphone.slash",
                isDestructive: true
            ) {
                deleteFromDevice(Array(ids))
            })
        }

        return items
    }

    // MARK: - Aksi

    private func upload(_ ids: [String]) async {
        await backup.uploadNow(ids)
        refreshUploaded()
    }

    /// Hanya yang SUDAH ada di server yang benar-benar dihapus.
    ///
    /// Seleksi bisa bercampur, dan menghapus yang belum terunggah berarti
    /// membuang satu-satunya salinannya — bukan itu yang diminta orang yang
    /// menekan "Delete from Device".
    private func deleteFromDevice(_ ids: [String]) {
        guard deviceRemoval == nil else { return }
        let localIDs = ids.map(LocalPhotoLibrary.localIdentifier(from:)).filter(uploadedIDs.contains)
        guard !localIDs.isEmpty else { return }
        let service = FreeUpSpaceService(session: session)
        actionError = nil
        deviceRemoval = Task {
            defer { deviceRemoval = nil }
            do {
                try Task.checkCancellation()
                let removed = try await DeviceCopyDeletion.perform(localIdentifiers: localIDs, using: service)
                guard !Task.isCancelled, removed > 0 else { return }
                await load()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                actionError = ErrorEvent(error.localizedDescription)
            }
        }
    }

    private func delete(_ ids: [String]) async {
        guard await LocalPhotoLibrary.shared.delete(ids) else { return }
        let removed = Set(ids.map(LocalPhotoLibrary.localIdentifier(from:)))
        photos.removeAll { removed.contains($0.id) }
    }

    /// Berkas asli disalin ke direktori sementara.
    ///
    /// `UIActivityViewController` menuntut URL yang bisa dibaca prosesnya, dan
    /// URL milik PhotoKit bukan itu — isinya harus diminta lebih dulu, dan untuk
    /// foto yang aslinya masih di iCloud itu berarti mengunduhnya.
    private func shareURLs(for ids: [String]) async -> [URL] {
        var urls: [URL] = []
        for id in ids {
            guard let file = await LocalPhotoLibrary.shared.originalData(for: id) else {
                continue
            }
            if let url = try? TemporaryMediaStore.createShareFile(
                data: file.data,
                suggestedFilename: file.filename) {
                urls.append(url)
            }
        }
        return urls
    }
}
