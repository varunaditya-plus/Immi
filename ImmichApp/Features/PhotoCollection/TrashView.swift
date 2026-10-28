import SwiftUI

/// Tong sampah: grid berkelompok per bulan, dengan dua aksi menyeluruh di menu
/// elipsis — kembalikan semua, atau kosongkan permanen.
///
/// Layarnya sendiri, bukan `AssetCollectionView` dengan satu bendera lagi: di
/// sini "hapus" berarti permanen dan "keluarkan dari koleksi" berarti
/// mengembalikan. Keduanya arti yang berbeda dari koleksi mana pun.
struct TrashView: View {
    @Environment(SessionManager.self) private var session
    @State private var vm: AssetGridViewModel?
    @State private var trashRepo: TrashRepository?
    @State private var showEmptyConfirm = false
    @State private var showRestoreAllConfirm = false

    var body: some View {
        screen
            .confirmationDialog(
                "Permanently delete everything in the trash?",
                isPresented: $showEmptyConfirm,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) { emptyTrash() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .confirmationDialog(
                "Restore everything in the trash?",
                isPresented: $showRestoreAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore All") { restoreAll() }
                Button("Cancel", role: .cancel) {}
            }
            .task { await start() }
    }

    private var screen: some View {
        collectionScreen(using: vm, repository: trashRepo)
    }

    func collectionScreen(using model: AssetGridViewModel?, repository: TrashRepository?) -> PhotoCollectionScreen<some View> {
        let actions: TrashViewerActions?
        if let model, let repository {
            actions = viewerActions(using: model, repository: repository)
        } else { actions = nil }
        return PhotoCollectionScreen(
            title: "Trash",
            layout: .monthly,
            assets: model?.assets ?? [],
            phase: model?.phase ?? .loading,
            actionError: Binding(
                get: { model?.actionError },
                set: { model?.actionError = $0 }),
            emptyState: PhotoCollectionEmptyState(
                title: "Trash is Empty",
                systemImage: "trash",
                description: "Deleted photos will appear here."),
            onRetry: { Task { await model?.load() } },
            onToggleFavorite: { await model?.toggleFavorite($0) },
            // Sudah di tong sampah, jadi "hapus" di sini memang permanen.
            onDelete: { await model?.delete($0, permanently: true) },
            shareURLs: { await model?.shareURLs(for: $0) ?? [] },
            // Restore jadi tombolnya SENDIRI, bukan pilihan di dalam dialog
            // hapus. Foto di tong sampah cuma punya dua jalan keluar — kembali
            // atau hilang selamanya — dan menyembunyikan salah satunya di balik
            // tombol yang bergambar sampah membuat yang tidak merusak terlihat
            // seperti bagian dari yang merusak.
            onRestoreSelection: { ids in
                guard let repository else { return }
                await model?.restore(ids, using: repository)
            },
            // Berbagi isi tong sampah tidak berarti apa pun.
            allowsSelectionShare: false,
            deletesPermanently: true,
            trashViewerActions: actions,
            removalScope: .trash,
            options: { trashMenu })
    }

    func viewerActions(using model: AssetGridViewModel, repository: TrashRepository) -> TrashViewerActions {
        var viewerError: String?
        return TrashViewerActions(
            restore: {
                viewerError = nil
                let accepted = await model.restore([$0], using: repository)
                if !accepted { viewerError = model.actionError }
                model.actionError = nil
                return accepted
            },
            deletePermanently: {
                viewerError = nil
                let accepted = await model.delete([$0], permanently: true)
                if !accepted { viewerError = model.actionError }
                model.actionError = nil
                return accepted
            },
            errorMessage: { viewerError })
    }

    @ViewBuilder
    private var trashMenu: some View {
        Button {
            showRestoreAllConfirm = true
        } label: {
            Label("Restore All", systemImage: "arrow.uturn.backward")
        }

        Divider()

        Button(role: .destructive) {
            showEmptyConfirm = true
        } label: {
            Label("Empty Trash", systemImage: "trash.slash")
        }
    }

    private func start() async {
        if vm == nil {
            let api = APIClient(session: session)
            let repository = TrashRepository(api: api)
            trashRepo = repository
            vm = AssetGridViewModel(
                assetRepo: AssetDetailRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                snapshotKey: LocalSnapshot.Key.trash,
                loader: {
                    try await repository.assets().map(AssetLite.init)
                })
        }
        // Setiap kali — penyegarannya tak terlihat, dan itu yang memberi jalan
        // keluar kalau permintaan pertama gagal. Lihat AssetCollectionView.
        await vm?.load()
    }

    private func emptyTrash() {
        guard let trashRepo else { return }
        Task { await vm?.emptyTrash(using: trashRepo) }
    }

    private func restoreAll() {
        guard let trashRepo else { return }
        Task { await vm?.restoreAll(using: trashRepo) }
    }
}
