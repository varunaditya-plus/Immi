import SwiftUI

/// Pembungkus supaya kumpulan id bisa dipakai `sheet(item:)`.
///
/// `[String]` bukan `Identifiable`, dan menambahkan konformansi itu ke tipe milik
/// pustaka standar berisiko bentrok dengan deklarasi serupa di tempat lain.
private struct SelectedAssets: Identifiable {
    let id = UUID()
    let ids: [String]
}

struct TimelineView: View {
    /// Naik satu setiap tab Photos ditekan ulang; memicu kembali ke posisi
    /// default, yaitu paling bawah (foto terbaru).
    var resetScrollRequest = 0
    /// Mencegah tab yang sedang tidak terlihat ikut mempresentasikan coach mark
    /// dari toolbar yang mungkin sudah dibangun lebih dulu oleh TabView.
    var isActive = true

    @Environment(SessionManager.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Linimasa merender dari hasil sync, jadi ia perlu tahu kapan sync selesai.
    @Environment(SyncViewModel.self) private var syncVM: SyncViewModel?
    /// Dipakai bersama aksesori inline milik tab bar.
    @Environment(TimelineNavigationState.self) private var timelineNavigation
    @State private var vm: TimelineViewModel?
    @State private var shareFileURL: URL?
    @State private var isSharePresented = false
    @State private var assetToDelete: AssetLite?
    @State private var deviceDeleteID: String?
    /// Aset yang sedang dipilihkan album lewat sheet.
    @State private var showSettings = false
    @State private var albumPickerAsset: AssetLite?
    @State private var selectedIDs: Set<String> = []
    @State private var isPreparingSelectionShare = false
    @State private var isRemovingDeviceSelection = false
    @State private var selectionShareURLs: [URL] = []
    @State private var isSelectionSharePresented = false
    /// Naik satu setiap penghapusan yang dikonfirmasi server.
    @State private var deleteFeedback = 0
    /// Naik satu setiap favorit yang dikonfirmasi server.
    @State private var favoriteFeedback = 0
    /// Seleksi yang sedang dipilihkan album; nil berarti sheet-nya tertutup.
    @State private var albumPickerSelection: SelectedAssets?
    @State private var selectionLink: SharedLinkPresentation?
    /// Bulan yang sedang tampil, DI LUAR state milik view ini.
    ///
    /// Sebagai `@State`, setiap perubahannya menginvalidasi seluruh body —
    /// termasuk grid berisi puluhan ribu sel — padahal yang berubah cuma sebaris
    /// teks di toolbar. Dan probe-nya menulis terus selama jari bergerak.
    ///
    /// Sebagai objek `@Observable`, hanya view yang benar-benar MEMBACA judulnya
    /// yang ikut digambar ulang.
    @State private var monthTracker = VisibleMonthTracker()
    @AppStorage(SettingsViewModel.gridColumnsKey)
    private var gridColumns = SettingsViewModel.defaultGridColumns
    /// Pegangan ke controller grid, untuk perintah yang datang dari luar —
    /// ketukan kedua tab Photos, misalnya.
    @State private var gridController: PhotoGridController?
    /// Grid pembuka tidak boleh memperlihatkan cache lama sesaat sebelum sync
    /// menambahkan aset terbaru dan memindahkannya lagi ke bawah.
    @State private var initialNewestContentReady = false
    @State private var isFinishingInitialTimelineLoad = false
    @State private var backupSetupJourney = BackupSetupJourney.shared

    /// Mode pilih dibagi dengan AppRouter karena picker compact iPhone hidup
    /// sebagai overlay di luar TimelineView.
    private var isSelecting: Bool { timelineNavigation.isSelecting }

    private var isSelectingBinding: Binding<Bool> {
        Binding(
            get: { timelineNavigation.isSelecting },
            set: { timelineNavigation.setSelecting($0) })
    }

    var body: some View {
        NavigationStack {
            content
                // TANPA `toolbarBackground` sama sekali — latarnya diserahkan
                // ke sistem, dan di iOS 26 itulah yang memberi kaca transparan.
                //
                // Judulnya bukan `navigationTitle` melainkan toolbar item biasa
                // (lihat `timelineToolbar`), karena item toolbar tidak pernah
                // menyusut atau berpindah ke tengah saat di-scroll.
                .toolbar { timelineToolbar }
                // Years dan Months adalah navigator visual penuh. Sembunyikan
                // navigation bar-nya sebagai satu kesatuan agar judul, Select,
                // dan Profile hilang sekaligus tanpa menyisakan ruang kosong.
                .toolbar(
                    timelineNavigation.mode == .all ? .visible : .hidden,
                    for: .navigationBar)
                // Tab bar diganti bottom bar selama memilih, supaya aksi
                // seleksi menempati tempat yang sama.
                .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
                .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        }
        .overlay(alignment: .bottom) {
            if horizontalSizeClass == .regular, !isSelecting {
                TimelineModePicker(
                    navigation: timelineNavigation,
                    allTitle: "All Photos")
                    .controlSize(.large)
                    .frame(width: 480)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .onChange(of: showSettings) { _, isPresented in
            if !isPresented {
                Task { @MainActor in
                    // Tunggu animasi dismiss sheet selesai. Membuka TipKit saat
                    // presentation controller lama masih turun dapat membuat
                    // overlay tak terlihat yang menahan tap toolbar.
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !showSettings else { return }
                    backupSetupJourney.returnToProfileIfNeeded()
                }
            }
        }
        .sheet(isPresented: $isSharePresented) {
            if let url = shareFileURL {
                ShareSheet(url: url)
            }
        }
        .sheet(item: $albumPickerAsset) { asset in
            AlbumPickerSheet(albums: vm?.albums ?? []) { album in
                Task { await vm?.addToAlbum(asset, album: album) }
            }
        }
        .sheet(isPresented: $isSelectionSharePresented) {
            MultiShareSheet(urls: selectionShareURLs)
        }
        .sheet(item: $albumPickerSelection) { selection in
            AlbumPickerSheet(albums: vm?.albums ?? []) { album in
                runSelection { await vm?.addToAlbum(selection.ids, album: album) }
            }
        }
        .sheet(item: $selectionLink) { ShareSheet(url: $0.url) }
        .alert("Action Failed", isPresented: Binding(
            get: { vm?.actionError != nil },
            set: { if !$0 { vm?.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm?.actionError ?? "")
        }
        .alert("Delete Photo", isPresented: Binding(
            get: { assetToDelete != nil },
            set: { if !$0 { assetToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let asset = assetToDelete {
                    Task {
                        if await vm?.delete(asset) == true {
                            deleteFeedback += 1
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this photo?")
        }
        // Ketukan tegas hanya setelah server mengonfirmasi penghapusan.
        // Pencocokan foto perangkat menunda diri di jaringan berbayar; begitu
        // Wi‑Fi menyambung, ia dicoba lagi tanpa menunggu aplikasi dibuka ulang.
        .onChange(of: NetworkMonitor.shared.isExpensive) { _, expensive in
            if !expensive { vm?.matchDevicePhotos() }
        }
        // Tiap unggahan yang berhasil mengubah arti satu petak dari "belum aman"
        // jadi "sudah ada di keduanya". Tanpa ini lencananya baru berganti pada
        // sync berikutnya — sementara layar Backup sudah menghitungnya naik.
        .onChange(of: BackupService.shared.backedUp) { _, _ in
            Task { await vm?.refreshOrigins() }
        }
        // "Delete from Device" mengubah arti petak dari arah sebaliknya: yang
        // tadinya ada di keduanya sekarang hanya ada di server. Yang berubah
        // sama — lencananya — jadi jalur penggambaran ulangnya juga sama.
        .onChange(of: LocalPhotoLibrary.shared.photos.count) { _, _ in
            Task { await vm?.refreshOrigins() }
        }
        // Jumlah foto bisa tetap sama walaupun satu aset dihapus dan aset lain
        // masuk. Revision berasal langsung dari PhotoKit, jadi status `.both`
        // dan menu perangkat ikut diperiksa ulang pada setiap perubahan nyata.
        .onChange(of: LocalPhotoLibrary.shared.revision) { _, _ in
            Task { await vm?.reloadDevicePhotos() }
        }
        .onChange(of: SwiftDataManager.shared.nonTimelineAssetIDs) { _, _ in
            // Search, Library, and sync can hide assets while Photos stays alive.
            Task { await vm?.loadTimeline() }
        }
        .deleteFromDeviceAlert($deviceDeleteID) { deleteFeedback += 1 }
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteFeedback)
        // Favorit BUKAN ketukan berat: hasilnya bukan sesuatu yang hilang,
        // melainkan sesuatu yang bertambah — `.success` yang menyampaikannya.
        .sensoryFeedback(.success, trigger: favoriteFeedback)
        .task {
            if vm == nil {
                let api = APIClient(session: session)
                vm = TimelineViewModel(
                    dataManager: SwiftDataManager.shared,
                    assetRepo: AssetDetailRepository(api: api),
                    albumRepo: AlbumRepository(api: api),
                    matcher: DeviceAssetMatcher(
                        repo: BackupRepository(api: api),
                        dataManager: SwiftDataManager.shared)
                )
            }
            await vm?.loadTimelineIfNeeded()

            // Foto perangkat menyusul SETELAH linimasa tergambar.
            //
            // Kunjungan pertama memunculkan dialog izin sistem, dan itu tidak
            // boleh menghalangi foto yang sudah ada di cache untuk tampil lebih
            // dulu.
            await vm?.loadDevicePhotos()
            await vm?.loadAlbumsIfNeeded()

            // Bisa saja sync selesai sebelum Timeline sempat mengamati
            // perubahannya (misalnya cache kecil atau perangkat offline).
            if (syncVM?.backgroundSyncCompletionCount ?? 0) > 0 {
                await finishInitialTimelineLoad()
            }
        }
        // Sync pertama biasanya selesai SETELAH layar ini muncul; tanpa ini
        // grid-nya tetap kosong sampai tab dibuka ulang.
        .onChange(of: syncVM?.lastSyncTime) { _, _ in
            Task {
                if initialNewestContentReady {
                    await vm?.loadTimeline()
                } else {
                    await finishInitialTimelineLoad()
                }
            }
        }
        // Snapshot cache memang cepat, tetapi belum tentu yang terbaru. Tunggu
        // percobaan sync pembuka selesai, baca cache hasilnya, baru buka gerbang
        // render milik UICollectionView.
        .onChange(of: syncVM?.backgroundSyncCompletionCount) { _, count in
            guard let count, count > 0 else { return }
            Task { await finishInitialTimelineLoad() }
        }
        // Ketukan kedua pada tab Photos. Dikirim AppRouter sebagai penghitung
        // yang naik, bukan Bool, supaya ketukan beruntun tetap terbaca.
        .onChange(of: resetScrollRequest) { _, _ in
            guard let vm else { return }
            returnToNewest(vm)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.phase {
            case .idle, .loading:
                // Kosong, BUKAN spinner, kalau fotonya sudah ada di perangkat.
                //
                // Yang ditunggu cuma pembacaan cache dan pengelompokannya —
                // sepersekian detik, dan tidak ada yang sedang diunduh. Spinner
                // di situ membuat aplikasi seolah memuat ulang seluruh isinya
                // setiap kali dibuka, padahal isinya sudah lama tersimpan.
                if vm.hasLocalData {
                    Color.clear
                } else {
                    ProgressView()
                }

            case .loaded:
                if vm.sections.isEmpty, !initialNewestContentReady {
                    // Cache kosong belum tentu benar-benar kosong: sync pembuka
                    // mungkin sedang mengisinya. Hindari empty state berkedip
                    // lalu mendadak berubah menjadi ribuan foto.
                    Color.clear
                } else if vm.sections.isEmpty {
                    emptyState
                } else {
                    timelineContent(vm)
                }

            case .failed(let error):
                errorState(error, vm)
            }
        } else {
            // View model baru dibuat di `task`, yaitu setelah gambar pertama.
            // Satu frame kosong jauh lebih tenang daripada spinner yang berkedip
            // dan langsung hilang.
            Color.clear
        }
    }

    private func timelineContent(_ vm: TimelineViewModel) -> some View {
        TimelineBrowserView(
            viewModel: vm,
            navigation: timelineNavigation,
            gridController: gridController,
            resetScrollRequest: resetScrollRequest
        ) {
            timelineGrid(vm)
        }
    }

    private func timelineGrid(_ vm: TimelineViewModel) -> some View {
        PhotoGridView(
            sections: vm.sections,
            configuration: PhotoGridConfiguration(
                columns: max(gridColumns, 1),
                // TANPA judul bulan menempel di grid.
                //
                // Bulan yang sedang tampil sudah tertulis di bawah "Photos" di
                // toolbar, jadi judul kedua di dalam grid cuma mengulang. Dan
                // begitu judulnya tidak ada, memecah grid per bulan pun tidak
                // punya alasan lagi — barisnya mengalir terus melewati pergantian
                // bulan, tanpa petak kosong di ujung tiap bulan.
                showsSectionHeaders: false,
                startsAtNewest: true,
                // Linimasa dibaca dari bawah, jadi baris bolongnya ditaruh di
                // puncak — tempat yang hampir tidak pernah dilihat.
                padsFirstRow: true),
            isSelecting: isSelectingBinding,
            selectedIDs: $selectedIDs,
            detailScreen: { id in detailScreen(for: id, vm) },
            onVisibleSectionChanged: { monthTracker.show($0) },
            menuActions: { id in menuActions(for: id, vm) },
            initialContentReady: initialNewestContentReady,
            onInitialContentDisplayed: {
                AppLaunchState.shared.markReady()
            },
            onControllerReady: { gridController = $0 },
            session: session)
        // Grid adalah bidang visual yang benar-benar menempel pada safe area
        // sidebar iPad. Efek dipasang di sini agar sistem dapat mencerminkan dan
        // memburamkan tepi foto ke bawah sidebar, bukan pada hero koleksi lain.
        .backgroundExtensionEffect(
            isEnabled: horizontalSizeClass == .regular)
        // Grid menembus sampai ke BELAKANG nav bar, bukan berhenti di bawahnya.
        //
        // Inilah sebab toolbar-nya terlihat berlatar warna polos: bar-nya sendiri
        // sudah transparan, tapi yang berada di belakangnya cuma latar collection
        // view — fotonya tidak pernah sampai ke sana karena framenya berhenti
        // tepat di bawah bar. Kaca tidak punya apa-apa untuk diburamkan.
        //
        // Setelah framenya melebar, `contentInsetAdjustmentBehavior` bawaan tetap
        // menahan baris pertama di bawah bar, jadi tidak ada foto yang tertutup —
        // yang berubah cuma: sekarang foto lewat di belakangnya saat digulir.
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    /// Membaca hasil sync sekali lagi sebelum grid pembuka ditampilkan. Aman
    /// dipanggil dari dua jalur (task dan onChange): signature view model
    /// membuang rebuild yang isinya sama.
    private func finishInitialTimelineLoad() async {
        guard !initialNewestContentReady, !isFinishingInitialTimelineLoad else { return }
        isFinishingInitialTimelineLoad = true
        defer { isFinishingInitialTimelineLoad = false }
        await vm?.loadTimeline()
        initialNewestContentReady = true
        // Tidak ada controller grid yang akan memberi callback kalau hasil
        // akhirnya memang kosong. Dalam kasus itu empty state-lah frame final.
        if vm?.sections.isEmpty != false {
            AppLaunchState.shared.markReady()
        }
    }

    /// Isi context menu, dibangun SAAT foto ditekan lama.
    ///
    /// Dulu tiap sel memasang context menu sendiri begitu ia masuk layar. Di
    /// grid yang digulir cepat itu puluhan pemasangan interaksi per detik, untuk
    /// menu yang hampir tidak pernah dibuka.
    private func menuActions(
        for id: String,
        _ vm: TimelineViewModel
    ) -> [PhotoGridMenuAction] {
        guard let asset = vm.asset(for: id) else { return [] }
        var actions: [PhotoGridMenuAction] = [
            // Tiga teratas jadi BARIS IKON di puncak menu — lihat
            // `PhotoGridMenuGroup`.
            PhotoGridMenuAction(
                title: String(localized: "Share"),
                systemImage: "square.and.arrow.up",
                group: .quick
            ) {
                Task { await shareAsset(asset, vm) }
            },
            PhotoGridMenuAction(
                title: asset.isFavorite
                    ? String(localized: "Unfavorite")
                    : String(localized: "Favorite"),
                systemImage: asset.isFavorite ? "heart.fill" : "heart",
                group: .quick
            ) {
                Task {
                    // Getarnya HANYA setelah server menerimanya. Bergetar lebih
                    // dulu berarti memberi tahu "sudah" untuk sesuatu yang belum
                    // tentu terjadi.
                    if await vm.toggleFavorite(asset) { favoriteFeedback += 1 }
                }
            },
            PhotoGridMenuAction(
                title: String(localized: "Archive"),
                systemImage: "archivebox",
                group: .quick
            ) {
                Task { await vm.archive(asset) }
            },
            PhotoGridMenuAction(
                title: String(localized: "Add to Album"),
                systemImage: "rectangle.stack.badge.plus"
            ) {
                albumPickerAsset = asset
            },
            PhotoGridMenuAction(
                title: String(localized: "Move to Locked Folder"),
                systemImage: "lock"
            ) {
                Task { await vm.lockSelected([asset.id]) }
            },
            PhotoGridMenuAction(title: String(localized: "Share Link"), systemImage: "link") {
                createSharedLink(for: [asset.id])
            },
        ]

        // Disisipkan SEBELUM "Delete", supaya yang paling berat tetap paling
        // bawah — urutan itu yang membuat menu bisa dibaca dari atas ke bawah
        // sebagai "makin permanen".
        if let deviceAction = DeviceCopyDeletion.menuAction(
            for: asset, request: { deviceDeleteID = $0 }) {
            actions.append(deviceAction)
        }

        actions.append(PhotoGridMenuAction(
            title: String(localized: "Delete"),
            systemImage: "trash",
            isDestructive: true
        ) {
            assetToDelete = asset
        })

        return actions
    }

    private var selectButton: some View {
        Button {
            withAnimation {
                if isSelecting {
                    exitSelection()
                } else {
                    timelineNavigation.setSelecting(true)
                }
            }
        } label: {
            if isSelecting {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            } else {
                Text("Select")
            }
        }
    }

    /// Judul + bulan yang sedang di layar, keduanya di dalam satu toolbar item.
    ///
    /// Sengaja TANPA foregroundStyle: warna bawaan item toolbar sudah vibrant
    /// terhadap apa yang lewat di belakangnya — mekanisme yang sama dengan
    /// label tombol Select. Menyetelnya justru mengunci warnanya.
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Photos")
                .font(.largeTitle.bold())

            if timelineNavigation.mode == .all {
                VisibleMonthLabel(tracker: monthTracker)
            } else {
                Text(timelineNavigation.mode.title)
                    .font(.headline.bold())
            }
        }
        .lineLimit(1)
        // WAJIB: tanpa ini toolbar menyempitkan item sampai selebar ikon dan
        // judulnya tersisa jadi "…".
        .fixedSize()
    }
    
    private var settingsSheet: some View {
        SettingsSheetView(session: session)
    }

    // MARK: - Sel grid

    /// Layar detail, dibangun untuk dipresentasikan oleh grid.
    ///
    /// Isinya sama persis dengan yang dulu ada di `fullScreenCover`; yang pindah
    /// hanya siapa yang membukanya, supaya animator transisi punya tempat.
    private func detailScreen(for id: String, _ vm: TimelineViewModel) -> AnyView {
        guard let asset = vm.asset(for: id) else { return AnyView(EmptyView()) }

        return AnyView(
            NavigationStack {
                AssetDetailView(
                    currentAsset: asset,
                    assets: vm.allAssets,
                    isModal: true,
                    // Menutupnya harus mengecil ke foto yang SEDANG dilihat,
                    // bukan yang pertama dibuka.
                    onAssetChange: { gridController?.detailDidChangeAsset(to: $0.id) },
                    // Grid ikut diperbarui saat layar detail masih terbuka, jadi
                    // saat kembali isinya sudah konsisten dengan server.
                    onAssetRemoved: { vm.assetWasRemoved($0) },
                    onAssetUpdated: { removedID in
                        Task { await vm.assetWasUpdated(removedID) }
                    },
                    onFavoriteChanged: { favoriteID, isFavorite in
                        vm.setFavorite(favoriteID, to: isFavorite)
                    }
                )
            }
            // Keyboard avoidance ditolak di AKAR scene yang dipresentasikan:
            // inset keyboard dipasang oleh hosting controller-nya, dan opt-out
            // dari dalam NavigationStack tidak bisa membatalkan penyusutan yang
            // sudah terjadi di atasnya.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environment(session)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        // Judul sebagai toolbar item, bukan navigationTitle: posisinya tetap,
        // tidak ikut menyusut ke inline saat di-scroll.
        // Judul disembunyikan selama memilih: jumlah terpilih menempati posisi
        // principal, dan UIKit memusatkan `titleView` di antara item bar — dengan
        // judul besar masih di kiri, jumlahnya terjepit sampai terpotong.
        if !isSelecting {
            ToolbarItem(placement: .topBarLeading) { titleStack }
                // Judul tidak boleh dapat latar kapsul seperti tombol.
                .sharedBackgroundVisibility(.hidden)
        }

        // Pada iPad bar tetap terlihat di Years/Months supaya segmented control
        // dapat dipakai, tetapi aksi milik grid All tidak ikut ditampilkan.
        if timelineNavigation.mode == .all {
            ToolbarItem(placement: .topBarTrailing) { selectButton }
            if !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    JourneyProfileButton(isActive: isActive) {
                        showSettings = true
                    }
                }
                // Avatarnya sudah bulat penuh; kapsul kaca bawaan toolbar hanya
                // menambah lingkaran kedua yang lebih besar di belakangnya.
                .sharedBackgroundVisibility(.hidden)
            }
        }
        if isSelecting {
            // Jumlahnya pindah ke bar ATAS: bar bawah sekarang penuh aksi, dan
            // menyelipkan teks di antaranya hanya membuat tombolnya berdesakan.
            ToolbarItem(placement: .principal) { selectionCountLabel }
                .sharedBackgroundVisibility(.hidden)

            SelectionToolbar(actions: selectionActions)
        }
    }

    /// Aksi mode pilih untuk linimasa.
    private var selectionActions: SelectionActions {
        let ids = Array(selectedIDs)
        let selectedAssets = ids.compactMap { vm?.asset(for: $0) }
        let localIDs = DeviceCopyDeletion.localIdentifiers(for: selectedAssets)
        var actions = SelectionActions()
        actions.isBusy = isPreparingSelectionShare
            || isRemovingDeviceSelection
            || selectedIDs.isEmpty

        actions.share = { shareSelection() }
        actions.favorite = {
            runSelection {
                if await vm?.favoriteSelected(ids) == true { favoriteFeedback += 1 }
            }
        }
        actions.archive = { runSelection { await vm?.archiveSelected(ids) } }
        // Konfirmasi dimiliki tombol Trash-nya sendiri. Ini menjaga anchor dan
        // animasi presentasi berasal dari posisi tombol di bottom toolbar,
        // bukan muncul sebagai dialog milik layar di tengah.
        actions.trashConfirmation = SelectionConfirmation(
            title: deleteConfirmTitle,
            message: String(localized: "This cannot be undone."),
            options: [SelectionConfirmationOption(
                title: String(localized: "Delete"),
                isDestructive: true,
                handler: deleteSelection)])
        actions.menu = [
            SelectionMenuAction(title: "Share Link", systemImage: "link") {
                createSharedLink(for: ids)
            },
            SelectionMenuAction(
                title: "Add to Album",
                systemImage: "rectangle.stack.badge.plus"
            ) {
                albumPickerSelection = SelectedAssets(ids: ids)
            },
            SelectionMenuAction(title: "Move to Locked Folder", systemImage: "lock") {
                runSelection { await vm?.lockSelected(ids) }
            },
        ]
        if !localIDs.isEmpty {
            actions.menu.append(SelectionMenuAction(
                title: removeFromDeviceTitle(localIDs.count),
                systemImage: "iphone.slash",
                isDestructive: true
            ) {
                removeSelectionFromDevice(localIDs)
            })
        }
        return actions
    }

    private func removeFromDeviceTitle(_ count: Int) -> LocalizedStringKey {
        count == 1 ? "Remove 1 from Device" : "Remove \(count) from Device"
    }

    private func createSharedLink(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let repo = SharedLinkRepository(api: APIClient(session: session))
        Task {
            guard let link = try? await repo.create(assetIds: ids),
                  let url = link.publicURL(base: session.baseURL)
            else { return }
            selectionLink = SharedLinkPresentation(url: url)
        }
    }

    private func runSelection(_ work: @escaping () async -> Void) {
        Task {
            await work()
            exitSelection()
        }
    }

    private var selectionCountLabel: some View {
        Text(selectionTitle)
            .font(.headline.bold())
            .foregroundStyle(selectedIDs.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            // Tanpa fixedSize, toolbar menyempitkan teksnya sampai terpotong.
            .fixedSize()
    }

    /// Sengaja dirakit manual, bukan `^[...](inflect:)`.
    ///
    /// Markup inflect hanya diproses kalau string-nya berupa literal yang
    /// menjadi `LocalizedStringKey`. Membangunnya lebih dulu sebagai `String`
    /// membuat `Text` menampilkannya apa adanya — markup-nya ikut terbaca.
    private var selectionTitle: String {
        let count = selectedIDs.count
        guard count > 0 else { return String(localized: "Select Items") }
        return count == 1 ? "1 Item Selected" : "\(count) Items Selected"
    }

    private var deleteConfirmTitle: String {
        let count = selectedIDs.count
        return count == 1 ? "Delete 1 Item" : "Delete \(count) Items"
    }

    // MARK: - Aksi seleksi

    private func exitSelection() {
        timelineNavigation.setSelecting(false)
        selectedIDs.removeAll()
    }

    /// Ketukan kedua di tab Photos: kembali ke foto terbaru SEKALIGUS memuat
    /// ulang.
    ///
    /// Menggantikan tarik-untuk-menyegarkan, yang letaknya justru di ujung yang
    /// salah — foto terbaru ada di bawah, sedangkan tarikan itu hanya bisa
    /// dilakukan dari puncak, tempat foto paling lama berada.
    private func returnToNewest(_ vm: TimelineViewModel) {
        // TimelineBrowserView menangani resetScrollRequest dan perpindahan
        // mode sebagai satu aksi supaya jangkar periode tidak menimpa newest.

        // Penyegaran DITUNDA sampai terbangnya benar-benar selesai.
        //
        // Menyegarkan berarti menarik PERUBAHAN dari server lalu menyusun ulang
        // dari cache — bukan mengunduh ulang linimasanya. Tapi menyusun ulang itu
        // memasang snapshot untuk puluhan ribu item, dan kalau jatuh bersamaan
        // dengan animasinya, gerakannya macet lalu lanjut lagi. Kalau jatuh tepat
        // sesudahnya, dasar linimasa bergeser dan yang terlihat lompatan kedua.
        //
        // Ditunda, keduanya hilang: satu gerakan bersih, lalu penyegarannya
        // menyusul sebagai kejadian tersendiri.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await syncVM?.performBackgroundSync()
            await vm.loadTimeline()
        }
    }

    private func shareSelection() {
        let ids = Array(selectedIDs)
        isPreparingSelectionShare = true
        Task {
            let urls = await vm?.shareURLs(for: ids) ?? []
            isPreparingSelectionShare = false
            guard !urls.isEmpty else { return }
            selectionShareURLs = urls
            isSelectionSharePresented = true
        }
    }

    private func deleteSelection() {
        let ids = Array(selectedIDs)
        Task {
            if await vm?.deleteSelected(ids) == true {
                deleteFeedback += 1
            }
            exitSelection()
        }
    }

    private func removeSelectionFromDevice(_ localIDs: [String]) {
        guard !localIDs.isEmpty, !isRemovingDeviceSelection else { return }
        isRemovingDeviceSelection = true
        Task {
            let removed = await DeviceCopyDeletion.perform(
                localIdentifiers: localIDs)
            isRemovingDeviceSelection = false
            guard removed > 0 else { return }

            // Segera bangun ulang dari PhotoKit agar petak lokal hilang dan
            // petak `.both` berubah menjadi server-only dalam snapshot yang
            // sama. Observer Photos tetap menjadi pengaman bila perubahan
            // datang dari luar aplikasi.
            await vm?.reloadDevicePhotos()
            deleteFeedback += 1
            exitSelection()
        }
    }

    private func shareAsset(_ asset: AssetLite, _ vm: TimelineViewModel) async {
        if let url = await vm.shareURL(for: asset) {
            shareFileURL = url
            isSharePresented = true
        }
    }

    /// Kosong punya DUA arti sekarang, dan keduanya menuntut kalimat berbeda:
    /// perpustakaan yang memang masih kosong, atau sync pertama yang belum
    /// selesai menurunkan datanya.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if syncVM?.isSyncing == true {
                ProgressView()
                Text("Syncing your library…")
                    .font(.headline)
                Text("This only happens once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Photos")
                    .font(.headline)
                Text("Upload photos to see them here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private func errorState(_ error: String, _ vm: TimelineViewModel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Failed to Load")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await vm.retry()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    TimelineView()
        .environment(SessionManager())
        .environment(TimelineNavigationState())
}
