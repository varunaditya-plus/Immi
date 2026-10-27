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
        PhotoCollectionScreen(
            title: "Trash",
            layout: .monthly,
            assets: vm?.assets ?? [],
            phase: vm?.phase ?? .loading,
            emptyState: PhotoCollectionEmptyState(
                title: "Trash is Empty",
                systemImage: "trash",
                description: "Deleted photos will appear here."),
            onRetry: { Task { await vm?.load() } },
            onToggleFavorite: { await vm?.toggleFavorite($0) },
            // Sudah di tong sampah, jadi "hapus" di sini memang permanen.
            onDelete: { await vm?.delete($0, permanently: true) },
            shareURLs: { await vm?.shareURLs(for: $0) ?? [] },
            // Restore jadi tombolnya SENDIRI, bukan pilihan di dalam dialog
            // hapus. Foto di tong sampah cuma punya dua jalan keluar — kembali
            // atau hilang selamanya — dan menyembunyikan salah satunya di balik
            // tombol yang bergambar sampah membuat yang tidak merusak terlihat
            // seperti bagian dari yang merusak.
            onRestoreSelection: { ids in
                guard let trashRepo else { return }
                await vm?.restore(ids, using: trashRepo)
            },
            // Berbagi isi tong sampah tidak berarti apa pun.
            allowsSelectionShare: false,
            deletesPermanently: true,
            removalScope: .trash,
            options: { trashMenu })
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
            let searchRepo = SearchRepository(api: api)
            trashRepo = TrashRepository(api: api)
            vm = AssetGridViewModel(
                assetRepo: AssetDetailRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                snapshotKey: LocalSnapshot.Key.trash,
                loader: {
                    // `withDeleted` SAJA tidak cukup — itu berarti "ikut
                    // sertakan yang di trash", bukan "hanya yang di trash",
                    // sehingga foto baru dari server pun ikut muncul di sini.
                    // `trashedAfter` yang menyaringnya: aset yang tidak pernah
                    // dibuang tidak punya tanggal buang, jadi tidak satu pun
                    // dari mereka yang lolos.
                    let items = try await searchRepo.allMetadata(
                        SearchRequestDTO(
                            size: 200,
                            withDeleted: true,
                            trashedAfter: trashEpoch))
                    return items.map(AssetLite.init)
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

/// Batas bawah "kapan dibuang" yang pasti melingkupi seluruh isi trash.
///
/// Bukan tanggal yang berarti apa-apa — ia cuma cara menyatakan "yang pernah
/// dibuang, kapan pun itu".
private let trashEpoch = "1970-01-01T00:00:00.000Z"
