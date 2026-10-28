import SwiftUI

/// Aksi satu foto yang dipasok layar Search ke gridnya.
///
/// Dikumpulkan jadi satu tipe, bukan enam parameter lepas: yang mengeksekusinya
/// bukan grid melainkan `SearchView` — sebagiannya membuka sheet yang state-nya
/// dipegang di sana — dan daftar sepanjang itu di daftar parameter membuat titik
/// panggilnya tidak terbaca lagi.
struct SearchAssetActions {
    var share: (AssetLite) -> Void
    var toggleFavorite: (AssetLite) -> Void
    var archive: (AssetLite) -> Void
    var addToAlbum: (AssetLite) -> Void
    var delete: (AssetLite) -> Void
    /// Foto keluar dari perpustakaan lewat layar detail.
    var assetRemoved: (String) -> Void
    /// Status favorit berubah lewat layar detail.
    var favoriteChanged: (String, Bool) -> Void
}

/// Grid hasil pencarian: petaknya berlebar mengikuti rasio foto, tapi mesinnya
/// `UICollectionView` yang sama dengan linimasa.
///
/// **Kenapa bukan `ScrollView` + `LazyVStack` seperti sebelumnya.** Bukan soal
/// jumlah foto — hasil pencarian dibatasi paginasi, dan SwiftUI sanggup
/// menggambarnya. Soalnya seleksi-seret.
///
/// Menyeret untuk menandai banyak foto dan menyeret untuk menggulir adalah
/// gerakan yang sama persis di mata sistem, dan di SwiftUI tidak ada yang
/// berwenang memutuskan mana yang dimaksud: dua gestur berebut sentuhan yang
/// sama, dan siapa pun yang menang, yang kalah terasa rusak. Versi sebelumnya
/// menebaknya dari arah gerakan pertama lalu mematikan gulir — dan tebakan itu
/// meleset persis sesering pengguna menyeret miring.
///
/// `UICollectionView` punya wasitnya. `allowsMultipleSelectionDuringEditing`
/// memasang pengenal gestur milik UIKit sendiri yang berunding dengan pan milik
/// scroll view alih-alih melawannya — lengkap dengan gulir otomatis di tepi yang
/// sebelumnya harus ditulis tangan. Semuanya hilang bersama perpindahan ini:
/// ~165 baris gestur, penomor putaran, dan `@GestureState` penjaga pembatalan.
struct SearchResultsGrid: View {
    let assets: [AssetLite]
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<String>
    /// Aksi context menu per foto, dan kabar balik dari layar detail.
    let actions: SearchAssetActions
    let onReachEnd: () -> Void
    let onOpen: (String) -> Void

    @Environment(SessionManager.self) private var session
    @AppStorage(SettingsViewModel.gridColumnsKey) private var gridColumns = 3
    @State private var gridController: PhotoGridController?
    @State private var deviceDeleteID: String?

    var body: some View {
        PhotoGridView(
            sections: [section],
            configuration: configuration,
            isSelecting: $isSelecting,
            selectedIDs: $selectedIDs,
            onOpen: onOpen,
            detailScreen: { detailScreen(for: $0) },
            menuActions: { menuActions(for: $0) },
            onReachEnd: onReachEnd,
            onControllerReady: { gridController = $0 },
            session: session)
        .deleteFromDeviceAlert($deviceDeleteID)
        // SENGAJA tanpa `ignoresSafeArea`, tidak seperti linimasa dan koleksi.
        // Grid ini duduk di dalam `VStack` bersama baris penyaring, jadi
        // membiarkannya melebar ke seluruh layar akan menaruhnya di belakang
        // baris itu.
    }

    /// Satu section tanpa judul: hasil pencarian tidak dikelompokkan per bulan.
    private var section: TimelineSection {
        TimelineSection(
            id: "search", title: "", assets: assets, count: assets.count, startIndex: 0)
    }

    private var configuration: PhotoGridConfiguration {
        PhotoGridConfiguration(
            layoutStyle: .justified,
            columns: max(gridColumns, 1),
            showsSectionHeaders: false)
    }

    private func asset(for id: String) -> AssetLite? {
        assets.first { $0.id == id }
    }

    /// Layar detail DIPRESENTASIKAN oleh grid, bukan didorong ke NavigationStack.
    ///
    /// Itu kebetulan yang menguntungkan: kolom cari layar ini berlabuh di tab
    /// bar, dan mendorong layar berarti menyembunyikan tab bar — yang mengusir
    /// kolomnya ke bar atas dan tidak pernah mengembalikannya. Presentasi
    /// `.overFullScreen` milik grid menutupi tab bar tanpa menyembunyikannya,
    /// jadi tidak ada yang perlu diusir.
    private func detailScreen(for id: String) -> AnyView {
        guard let asset = asset(for: id) else { return AnyView(EmptyView()) }

        return AnyView(
            NavigationStack {
                AssetDetailView(
                    currentAsset: asset,
                    assets: assets,
                    isModal: true,
                    // Menutupnya harus mengecil ke foto yang SEDANG dilihat,
                    // bukan yang pertama dibuka.
                    onAssetChange: { gridController?.detailDidChangeAsset(to: $0.id) },
                    // Hasil pencarian ikut berubah SELAGI layar detail masih
                    // terbuka. Tanpa ini, foto yang dihapus di sana masih
                    // terpampang saat kembali — dan mengetuknya berujung
                    // "not found".
                    onAssetRemoved: { actions.assetRemoved($0) },
                    onFavoriteChanged: { actions.favoriteChanged($0, $1) })
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // WAJIB: hosting controller milik presentasi UIKit tidak mewarisi
            // environment.
            .environment(session)
        )
    }

    /// Menu dibangun dari ID saat ditekan, bukan dari salinan aset.
    ///
    /// Ini yang menghapus seluruh urusan "favorit basi" di versi sebelumnya.
    /// `AssetLite` beridentitas id saja, jadi membalik favorit tidak membuat
    /// daftarnya dianggap berubah; salinan yang dipegang grid tetap menyimpan
    /// status lama, labelnya tidak pernah berganti jadi "Unfavorite", dan
    /// toggle-nya mengirim `true` terus-menerus. Mencarinya ulang di `assets`
    /// pada saat ditekan selalu memberi yang terbaru.
    private func menuActions(for id: String) -> [PhotoGridMenuAction] {
        guard let asset = asset(for: id) else { return [] }
        var items: [PhotoGridMenuAction] = [
            PhotoGridMenuAction(title: "Share", systemImage: "square.and.arrow.up") {
                actions.share(asset)
            },
            PhotoGridMenuAction(
                title: asset.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: asset.isFavorite ? "heart.fill" : "heart"
            ) {
                actions.toggleFavorite(asset)
            },
            PhotoGridMenuAction(title: "Archive", systemImage: "archivebox") {
                actions.archive(asset)
            },
            PhotoGridMenuAction(
                title: "Add to Album", systemImage: "rectangle.stack.badge.plus"
            ) {
                actions.addToAlbum(asset)
            },
        ]

        if let deviceAction = DeviceCopyDeletion.menuAction(
            for: asset, request: { deviceDeleteID = $0 }) {
            items.append(deviceAction)
        }

        items.append(
            PhotoGridMenuAction(title: "Delete", systemImage: "trash", isDestructive: true) {
                actions.delete(asset)
            })

        return items
    }
}
