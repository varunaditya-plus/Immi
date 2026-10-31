import SwiftUI

/// Cara mengeluarkan foto dari koleksi TANPA menghapusnya dari perpustakaan.
///
/// Tidak semua koleksi punya arti untuk ini — album punya ("keluarkan dari
/// album"), favorit punya ("cabut favorit"), tapi kumpulan foto seseorang tidak.
/// Karena itu bentuknya opsional, bukan tombol yang selalu ada tapi kadang mati.
struct PhotoCollectionRemoval {
    /// Judul tombolnya, mis. "Remove from Album".
    ///
    /// `String`, bukan `LocalizedStringKey`: judul ini juga dipakai sebagai
    /// judul `UIAction` di context menu UIKit, yang hanya menerima teks biasa.
    let title: String
    let perform: ([String]) async -> Void
}

/// Bentuk tampilan koleksi.
///
/// Keduanya berbagi grid, mode pilih, dan context menu yang sama persis — yang
/// berbeda hanya bagian kepalanya. Memisahkannya jadi dua layar utuh berarti
/// menyalin seluruh mode pilih itu, dan setiap perbaikan harus dikerjakan dua
/// kali.
enum PhotoCollectionLayout {
    /// Sampul besar berisi judul & jumlah item, lalu grid rata — untuk koleksi
    /// yang "punya identitas" seperti album, Favorites, dan orang.
    case hero
    /// Judul biasa di nav bar, grid dikelompokkan per bulan — untuk tumpukan
    /// yang sifatnya kronologis seperti Archived, Trash, dan Locked Folder.
    case monthly
}

struct PhotoCollectionEmptyState {
    let title: LocalizedStringKey
    let systemImage: String
    var description: LocalizedStringKey? = nil
    var action: Action? = nil

    struct Action {
        let title: LocalizedStringKey
        let perform: () -> Void
    }
}

/// Layar koleksi foto ala Photos.
///
/// Dipakai bersama oleh detail album, Favorites, foto per orang, dan
/// tumpukan-tumpukan di Library. Semuanya dulu punya tata letak dan mode
/// pilihnya sendiri-sendiri, dan setiap penyesuaian harus dikerjakan berkali —
/// perbedaannya sebenarnya cuma pada aksi yang tersedia dan bentuk kepalanya,
/// jadi itulah yang dijadikan parameter.
///
/// Gridnya `UICollectionView`, sama seperti linimasa. Album bisa berisi ribuan
/// foto, dan `LazyVGrid` menahan setiap sel yang pernah terlihat sampai layarnya
/// ditutup — pada album sebesar itu hasilnya sama persis dengan yang membuat tab
/// Photos dulu memakan ratusan megabyte.
struct PhotoCollectionScreen<Options: View>: View {
    let title: LocalizedStringKey
    var layout: PhotoCollectionLayout = .hero
    /// Keterangan di bawah judul, mis. deskripsi album. Kosong berarti tidak
    /// ada barisnya sama sekali.
    var subtitle: String? = nil
    var heroAssetID: String? = nil
    /// Daftar MENTAH dari pemanggil. Yang dipakai layar ini `visibleAssets`,
    /// yang sudah dibersihkan dari aset yang dibuang di layar lain.
    let assets: [AssetLite]
    let phase: LoadingPhase<Void>
    var actionError: Binding<String?> = .constant(nil)
    /// Pesan khusus setelah server berhasil menyatakan koleksinya kosong.
    /// `nil` mempertahankan tampilan kosong bawaan layar tersebut.
    var emptyState: PhotoCollectionEmptyState? = nil

    var onRetry: () -> Void
    var onToggleFavorite: ((AssetLite) async -> Void)? = nil
    var onDelete: ([String]) async -> Void
    var shareURLs: ([String]) async -> [URL]

    /// nil berarti layar ini tidak punya petak "+".
    var onAddPhotos: (() -> Void)? = nil
    var removal: PhotoCollectionRemoval? = nil
    /// nil berarti "Add to Album" tidak muncul di context menu.
    var onAddToAlbum: ((AssetLite) -> Void)? = nil

    // Aksi mode pilih. Yang nil tidak digambar tombolnya sama sekali — itu yang
    // membuat Trash tidak memamerkan "Archive" dan Archived tidak memamerkan
    // "Move to Archive".
    var onFavoriteSelection: (([String]) async -> Void)? = nil
    var onArchiveSelection: (([String]) async -> Void)? = nil
    var archiveActionTitle = String(localized: "Archive")
    /// Mengembalikan dari tong sampah; nil di layar selain Trash.
    var onRestoreSelection: (([String]) async -> Void)? = nil
    /// Mengeluarkan dari folder terkunci; nil di layar selain Locked Folder.
    var onUnlockSelection: (([String]) async -> Void)? = nil
    /// Memindahkan ke folder terkunci; nil di layar yang isinya memang tidak
    /// boleh dipindah ke sana (tong sampah, arsip, folder terkunci itu sendiri).
    var onMoveToLocked: (([String]) async -> Void)? = nil
    /// Membuat tautan publik untuk aset tertentu.
    var onShareLink: (([String]) -> Void)? = nil
    /// Mengunggah foto perangkat yang belum ada di server; nil di layar yang
    /// isinya memang sudah di server semua.
    var onUpload: (([String]) async -> Void)? = nil
    /// false untuk layar yang berbagi fotonya tidak masuk akal — tong sampah.
    var allowsSelectionShare = true
    /// "Delete" di layar ini menghapus SELAMANYA, bukan memindahkan ke tong
    /// sampah. Mengubah peringatannya, dan membuat penghapusan lewat context menu
    /// ikut bertanya lebih dulu.
    var deletesPermanently = false
    var trashViewerActions: TrashViewerActions? = nil
    /// Trash includes soft-deleted photos while still excluding unavailable ones.
    var removalScope: RemovedAssets.Scope = .library
    var visibilityScope: AssetVisibilityPolicy.Scope = .collection
    var canPerformServerActions: (AssetLite) -> Bool = { _ in true }
    var facePersonID: String? = nil
    var viewOptions: (() -> AnyView)? = nil
    /// Detail album di iPad tetap membutuhkan sidebar sebagai jalan kembali ke
    /// All Albums. Di compact/iPhone, tab bar tetap disembunyikan seperti biasa.
    var keepsTabBarVisibleOnRegularWidth = false
    var keepsTabBarVisible = false
    var onSelectionChanged: (Bool) -> Void = { _ in }
    /// Aksi tambahan di menu elipsis, dirakit dari id yang sedang terpilih.
    var selectionMenu: ((Set<String>) -> [SelectionMenuAction])? = nil
    /// Confirmation milik menu opsi. Binding-nya berasal dari pemanggil, tetapi
    /// modifier dipasang pada `Menu` persisten di toolbar agar anchor benar.
    var optionsConfirmation: SelectionConfirmation? = nil
    var optionsConfirmationPresented: Binding<Bool>? = nil

    /// Isi menu elipsis di kanan atas; `EmptyView` kalau layarnya tidak punya.
    @ViewBuilder var options: () -> Options

    @Environment(SessionManager.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Jumlah kolom mengikuti Settings, sama seperti linimasa — kalau tidak,
    /// pilihan yang sama memberi hasil berbeda tergantung layar mana yang dibuka.
    @AppStorage(SettingsViewModel.gridColumnsKey)
    private var gridColumns = SettingsViewModel.defaultGridColumns
    @AppStorage("library.aspectRatioGrid") private var aspectRatioGrid = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var sharePreparation = SharePreparation()
    @State private var copyPreparation = MediaCopyPreparation()
    @State private var slideshow: PhotoSlideshowPresentation?
    private var isPreparingShare: Bool { sharePreparation.isPreparing }
    @State private var isPerformingAction = false
    @State private var preparedURLs: [URL] = []
    @State private var preparedAssetIDs: [String] = []
    @State private var sharedSourceIDs: [String] = []
    @State private var sharedRequestContext: SessionRequestContext?
    @State private var isSharePresented = false
    @State private var showsMap = false
    @State private var showsFaces = false
    /// Foto yang menunggu konfirmasi hapus DARI CONTEXT MENU.
    ///
    /// Terpisah dari konfirmasi mode pilih, dan bentuknya alert, bukan dialog:
    /// yang ditanyakan menyangkut satu foto yang barusan ditekan lama, bukan
    /// sekumpulan pilihan atas seleksi.
    @State private var menuDeleteTarget: PhotoCollectionDeleteTarget?
    @State private var deviceDeleteID: String?
    /// Naik satu setiap penghapusan dan setiap favorit yang selesai dikerjakan.
    @State private var deleteFeedback = 0
    @State private var favoriteFeedback = 0
    @State private var heroIndex = 0
    @State private var heroZoomedIn = false
    /// Posisi puncak judul di dalam sampul, DIUKUR bukan ditebak.
    ///
    /// Nama album bisa jadi satu sampai tiga baris tergantung panjangnya dan
    /// ukuran teks pilihan pengguna, jadi angka tetap apa pun akan meleset persis
    /// di kasus-kasus itu.
    @State private var heroTitleTop: CGFloat = .infinity
    /// Judul sampul sudah tergulir sampai menyentuh toolbar.
    ///
    /// Yang disimpan hanya keadaan akhirnya, bukan offset gulirnya — grid
    /// mengabarinya sekali saat berganti, bukan tiap frame.
    @State private var isTitleDocked = false
    @State private var gridController: PhotoGridController?
    /// Aset yang sudah dikelompokkan untuk grid.
    ///
    /// Disimpan, bukan dihitung di `body`. Sebagai properti terhitung,
    /// pengelompokan per bulan — lengkap dengan `DateFormatter` untuk SETIAP
    /// foto — dijalankan ulang pada tiap pembaruan tampilan, termasuk pada tiap
    /// ketukan saat memilih. Pada album berisi ribuan foto itu ribuan pemformatan
    /// tanggal per ketukan.
    @State private var gridSections: [TimelineSection] = []

    /// Isi layar SETELAH aset yang dibuang di tempat lain dibersihkan.
    ///
    /// Album, Favorites, dan foto per orang masing-masing punya potretnya
    /// sendiri, diambil dari endpoint yang berbeda dari linimasa. Menghapus foto
    /// di tab Photos tidak menyentuh satu pun dari potret itu — jadi foto yang
    /// sudah tidak ada tetap berdiri di sini sampai layarnya memuat ulang dari
    /// server, dan menekannya berujung pada aset yang tidak ada.
    private var visibleAssets: [AssetLite] {
        visibilityPolicy.filter(assets)
    }

    private var visibilityPolicy: AssetVisibilityPolicy {
        AssetVisibilityPolicy(scope: visibilityScope, removalScope: removalScope)
    }

    var body: some View {
        screenContent
            .onChange(of: SwiftDataManager.shared.assetMutationRevision) { _, _ in onRetry() }
            // Bar transparan selama judul sampulnya masih terlihat, supaya
            // gambarnya penuh sampai ke belakang tombol-tombolnya. Begitu
            // judulnya merapat ke bar, latarnya dipasang — kalau tidak, judul
            // yang baru mendarat itu melayang di atas foto tanpa alas.
            .toolbarBackground(barBackground, for: .navigationBar)
            // Judulnya kembali ke nav bar saat sampulnya tidak digambar. Mode
            // sampul menyerahkan judul ke `dockedTitle`, dan tanpa sampul yang
            // bisa merapat, layar gagalnya akan berdiri tanpa judul sama sekali.
            .navigationTitle(layout == .hero && !isShowingUnavailableScreen ? "" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { screenToolbar }
            // Mode pilih tidak boleh bertahan ke layar gagal: seleksi bisa
            // dinyalakan saat masih memuat, dan kalau muatannya gagal, bar
            // aksinya tertinggal menumpangi pesan error dengan nol foto untuk
            // dikerjakan.
            .toolbar(
                isSelecting && !isShowingUnavailableScreen ? .visible : .hidden,
                for: .bottomBar)
            .toolbarVisibility(
                keepsTabBarVisible || (keepsTabBarVisibleOnRegularWidth && horizontalSizeClass == .regular)
                    ? .visible
                    : .hidden,
                for: .tabBar)
            .sheet(isPresented: $isSharePresented, onDismiss: cleanupPreparedShare) {
                PhotoShareSheet(urls: preparedURLs, assetIDs: preparedAssetIDs,
                    sourceIDs: sharedSourceIDs, requestContext: sharedRequestContext,
                    isAllowed: { [policy = visibilityPolicy] in policy.allows(id: $0) })
            }
            .fullScreenCover(item: $slideshow) { selection in
                PhotoSlideshowView(assets: selection.assets, initialAssetID: selection.initialAssetID,
                    visibilityPolicy: visibilityPolicy) { asset in
                    (await shareURLs([asset.id])).first
                }
            }
            .sheet(isPresented: $showsMap) {
                NavigationStack {
                    PhotoMapView(assetIDs: PhotoMapNavigation.ids(for: visibleAssets))
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { showsMap = false } } }
                }
            }
            .onChange(of: visibilityPolicy.state) { _, _ in
                guard preparedAssetIDs.contains(where: { !visibilityPolicy.allows(id: $0) }) else { return }
                isSharePresented = false
                cleanupPreparedShare()
            }
            // ALERT, bukan confirmation dialog — dan hanya untuk context menu.
            //
            // Yang ditanyakan di sini menyangkut satu foto yang barusan ditekan
            // lama, dengan satu jawaban yang mungkin. Dialog aksi dipakai saat
            // ada beberapa jalan keluar untuk dipilih, dan itu urusan mode pilih
            // — konfirmasinya menempel di tombolnya sendiri, lihat
            // `SelectionConfirmation`.
            .alert(
                contextDeleteTitle,
                isPresented: Binding(
                    get: { menuDeleteTarget != nil },
                    set: { if !$0 { menuDeleteTarget = nil } }),
                presenting: menuDeleteTarget
            ) { target in
                Button(deleteActionTitle, role: .destructive) {
                    menuDeleteTarget = nil
                    guard target.isCurrent(session: session, policy: visibilityPolicy) else { return }
                    runAction([target.asset.id]) {
                        guard target.isCurrent(session: session, policy: visibilityPolicy) else { return }
                        await onDelete([target.asset.id])
                        // Getarnya sama dengan jalur bar seleksi; tanpa ini,
                        // menghapus lewat context menu terasa berbeda dari
                        // menghapus hal yang sama lewat mode pilih.
                        if actionError.wrappedValue == nil { deleteFeedback += 1 }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                if deletesPermanently { Text("This cannot be undone.") }
                else {
                    Text(target.asset.isVideo ? "Are you sure you want to delete this video?"
                        : "Are you sure you want to delete this photo?")
                }
            }
            .alert("Action Failed", isPresented: Binding(
                get: { actionError.wrappedValue != nil },
                set: { if !$0 { actionError.wrappedValue = nil } })
            ) {
                Button("OK", role: .cancel) { actionError.wrappedValue = nil }
            } message: {
                Text(actionError.wrappedValue ?? "")
            }
            .deleteFromDeviceAlert($deviceDeleteID) { deleteFeedback += 1 }
            .sensoryFeedback(deleteHaptic, trigger: deleteFeedback)
            // Favorit BUKAN ketukan berat: hasilnya bukan sesuatu yang hilang,
            // melainkan sesuatu yang bertambah — `.success` yang menyampaikannya.
            .sensoryFeedback(.success, trigger: favoriteFeedback)
            // Tombol back diganti "Select All" selama memilih, seperti di
            // Photos — kalau tidak, keduanya berjejal di sisi kiri.
            .navigationBarBackButtonHidden(isSelecting)
            // Dikelompokkan ulang hanya saat isinya benar-benar berganti, dan
            // di luar main actor.
            .task(id: assetsSignature) { await rebuildSections() }
            .onChange(of: assetsSignature) { _, _ in
                selectedIDs.formIntersection(Set(visibleAssets.map(\.id)))
                if selectedIDs.isEmpty { endSelection() }
                if let target = menuDeleteTarget, !target.isCurrent(session: session, policy: visibilityPolicy) { menuDeleteTarget = nil }
                if let id = deviceDeleteID, !visibilityPolicy.allows(id: id) { deviceDeleteID = nil }
            }
            .onDisappear { sharePreparation.cancel(); copyPreparation.cancel() }
            .onChange(of: isSelecting, initial: true) { _, value in onSelectionChanged(value) }
    }

    // MARK: - Grid

    /// Gagal memuat MENGGANTIKAN gridnya, bukan menumpanginya.
    ///
    /// Sebelumnya pesan gagal ditumpuk sebagai overlay di atas grid yang masih
    /// membawa sampulnya. Sampul itu tetap tergambar — gambar besar berikut
    /// judulnya — dan pesan yang seharusnya di tengah layar justru mendarat di
    /// tengah sisa ruang di bawahnya, terpotong tepi sampul. Yang terlihat bukan
    /// satu layar gagal, melainkan dua layar yang saling menimpa.
    ///
    /// Kalau memang tidak ada yang bisa ditampilkan, tidak ada pula alasan
    /// menggambar sampulnya.
    @ViewBuilder
    private var screenContent: some View {
        if case .failed(let error) = phase, visibleAssets.isEmpty {
            errorState(error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Seleksi yang sempat dinyalakan sebelum muatannya gagal
                // dipadamkan di sini juga, bukan cuma disembunyikan barnya —
                // kalau tidak, ia menyala lagi begitu Retry berhasil.
                .onAppear { endSelection() }
        } else if isShowingEmptyScreen, let emptyState {
            emptyStateView(emptyState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { endSelection() }
        } else {
            grid
        }
    }

    private var grid: some View {
        PhotoGridView(
            sections: visibilityPolicy.filterSections(gridSections),
            configuration: configuration,
            hero: heroView,
            isSelecting: $isSelecting,
            selectedIDs: $selectedIDs,
            onOpen: { _ in sharePreparation.cancel(); copyPreparation.cancel() },
            detailScreen: { id in detailScreen(for: id) },
            onAddTapped: onAddPhotos,
            // Ambangnya diukur dari judul sungguhan; mode bulanan tidak punya
            // sampul, jadi tidak pernah ada yang merapat.
            titleDockContentY: layout == .hero ? heroTitleTop : .infinity,
            onTitleDockedChanged: { docked in
                withAnimation(.easeInOut(duration: 0.22)) { isTitleDocked = docked }
            },
            menuActions: { menuActions(for: $0) },
            onControllerReady: { gridController = $0 },
            onDensityChanged: { gridColumns = $0 },
            visibilityPolicy: visibilityPolicy,
            session: session)
        // Album, Favorites, dan koleksi hero lain menempel langsung pada safe
        // area sidebar iPad. Perluas seluruh bidang grid agar sampul dan foto
        // tetap berlanjut di bawah kaca sidebar seperti pada tab Photos.
        .backgroundExtensionEffect(
            isEnabled: horizontalSizeClass == .regular && layout == .hero)
        // Menembus sampai ke belakang nav bar di kedua mode — lihat catatan yang
        // sama di `TimelineView`. Mode sampul butuh itu supaya gambarnya terlihat
        // penuh; mode bulanan butuh itu supaya kaca bar-nya punya foto untuk
        // diburamkan alih-alih warna polos.
        .ignoresSafeArea(edges: [.top, .bottom])
        .overlay { statusOverlay }
    }

    /// Layar detail, dibangun untuk dipresentasikan oleh grid.
    private func detailScreen(for id: String) -> AnyView {
        guard let detail = detailView(for: id) else { return AnyView(EmptyView()) }

        return AnyView(
            NavigationStack {
                detail
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environment(session)
        )
    }

    func detailView(for id: String) -> AssetDetailView? {
        guard let asset = asset(for: id) else { return nil }
        return AssetDetailView(
            currentAsset: asset,
            assets: visibleAssets,
            visibilityPolicy: visibilityPolicy,
            isModal: true,
            onAssetChange: { gridController?.detailDidChangeAsset(to: $0.id) },
            trashActions: trashViewerActions)
    }

    /// Judul yang mendarat di toolbar begitu judul besar di sampul menyentuhnya.
    ///
    /// Item toolbar sendiri, bukan `navigationTitle`: judul bawaan muncul dan
    /// hilang seketika, sedangkan yang ini bisa dilarutkan mengikuti gulir —
    /// dan itulah yang membuat perpindahannya terasa menyambung, bukan berkedip.
    private var dockedTitle: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .opacity(isTitleDocked ? 1 : 0)
    }

    /// Bar baru berlatar setelah judulnya merapat.
    ///
    /// `.visible` yang tegas, bukan `.automatic`: yang menggulir di sini
    /// `UICollectionView` milik grid, dan nav bar tidak mengamatinya — diserahkan
    /// ke sistem, ia akan bertahan di penampilan tepi-gulir yang transparan
    /// selamanya. Mode bulanan tidak punya sampul untuk diperlihatkan, jadi di
    /// sana barnya dibiarkan berperilaku biasa.
    private var barBackground: Visibility {
        guard layout == .hero, !isShowingUnavailableScreen else { return .automatic }
        return isTitleDocked ? .visible : .hidden
    }

    /// Tidak ada yang bisa ditampilkan, dan server yang bilang begitu.
    private var isShowingErrorScreen: Bool {
        guard case .failed = phase else { return false }
        return visibleAssets.isEmpty
    }

    private var isShowingEmptyScreen: Bool {
        guard emptyState != nil, visibleAssets.isEmpty else { return false }
        if case .loaded = phase { return true }
        return false
    }

    private var isShowingUnavailableScreen: Bool {
        isShowingErrorScreen || isShowingEmptyScreen
    }

    /// Sampul hanya ada di mode `.hero`; mode bulanan langsung mulai dari grid.
    private var heroView: AnyView? {
        guard layout == .hero else { return nil }
        return AnyView(hero)
    }

    private var configuration: PhotoGridConfiguration {
        PhotoGridConfiguration(
            layoutStyle: layout == .hero && aspectRatioGrid && !showsFaces ? .justified : .square,
            columns: max(gridColumns, 1),
            allowsDensityZoom: true,
            facePersonID: showsFaces ? facePersonID : nil,
            faceRevision: showsFaces ? facePersonID.map {
                "\(LocalSnapshot.invalidationRevision(for: LocalSnapshot.Key.person($0))):\(SwiftDataManager.shared.assetMutationRevision)"
            } : nil,
            showsSectionHeaders: layout == .monthly,
            startsAtNewest: false,
            heroHeight: layout == .hero ? 420 : 0,
            // Petak "+" disembunyikan selama memilih: ia bukan foto, jadi tidak
            // punya arti dalam seleksi dan hanya mengacaukan barisnya.
            showsAddTile: onAddPhotos != nil && !isSelecting
                && (!visibleAssets.isEmpty || phase.value != nil),
            extendsUnderTopBar: layout == .hero)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch phase {
        case .idle, .loading:
            if visibleAssets.isEmpty { ProgressView() }

        // Gagal TIDAK ditangani di sini lagi — ia mengganti seluruh layar,
        // bukan menumpanginya. Lihat `screenContent`.
        case .failed:
            EmptyView()

        case .loaded:
            EmptyView()
        }
    }

    private func asset(for id: String) -> AssetLite? {
        visibleAssets.first { $0.id == id }
    }

    private struct CollectionContent: Equatable {
        let assets: [AssetLite]
        let monthly: Bool

        static func == (lhs: CollectionContent, rhs: CollectionContent) -> Bool {
            lhs.monthly == rhs.monthly
                && lhs.assets.elementsEqual(rhs.assets) { $0.hasSameContent(as: $1) }
        }
    }

    private var assetsSignature: CollectionContent {
        CollectionContent(assets: visibleAssets, monthly: layout == .monthly)
    }

    private func rebuildSections() async {
        let input = assetsSignature
        let sections = await groupAssets(input.assets, monthly: input.monthly)
        guard !Task.isCancelled, input == assetsSignature else { return }
        gridSections = sections
    }

    // MARK: - Sampul

    private var hero: some View {
        ZStack(alignment: .bottom) {
            coverImage
            scrim
            heroCaption
        }
        .frame(height: 420)
        .clipped()
        // Ruang acuan pengukuran judul. Diberi nama supaya angkanya relatif
        // terhadap PUNCAK SAMPUL — dan karena sampul adalah sel pertama grid,
        // puncak sampul sama dengan titik nol koordinat isi. Itu yang membuat
        // hasil ukurnya bisa langsung dibandingkan dengan posisi gulir.
        .coordinateSpace(.named(heroSpace))
        // Dimulai ulang saat isi koleksi berubah; sebelum itu belum ada foto
        // yang bisa digilir.
        .task(id: HeroPresentation(ids: heroAssets.map(\.id), fixedID: heroAssetID, reduceMotion: reduceMotion)) {
            await runHeroAnimation()
        }
    }

    /// Beberapa foto pertama saja yang digilir — cukup untuk terasa hidup tanpa
    /// perlu memuat seluruh koleksi beresolusi preview.
    private var heroAssets: [AssetLite] {
        PhotoCollectionCover.assets(in: visibleAssets, preferredID: heroAssetID)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let asset = currentHeroAsset {
            Color.clear.overlay {
                AuthImage(
                    assetId: asset.id,
                    size: "preview",
                    thumbhash: asset.thumbhash,
                    pixelSize: 1400)
                    .scaleEffect(heroZoomedIn ? 1.14 : 1)
            }
            // `id` membuat SwiftUI memperlakukan foto berikutnya sebagai view
            // BARU, sehingga pergantiannya bisa ditransisikan. Tanpa itu ia
            // hanya menukar isi view yang sama dan berganti seketika.
            .id(asset.id)
            .transition(.opacity)
        } else {
            Rectangle().fill(.fill.secondary)
        }
    }

    private var currentHeroAsset: AssetLite? {
        guard !heroAssets.isEmpty else { return nil }
        return heroAssets[heroIndex % heroAssets.count]
    }

    /// Zoom lambat sepanjang foto ditampilkan, lalu larut ke foto berikutnya.
    private struct HeroPresentation: Equatable {
        let ids: [String]
        let fixedID: String?
        let reduceMotion: Bool
    }

    private func runHeroAnimation() async {
        heroIndex = 0
        heroZoomedIn = false
        guard heroAssetID == nil, !reduceMotion, heroAssets.count > 1 else { return }

        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: heroHoldDuration)) {
                heroZoomedIn = true
            }
            try? await Task.sleep(for: .seconds(heroHoldDuration))
            guard !Task.isCancelled, heroAssets.count > 1 else { continue }

            withAnimation(.easeInOut(duration: heroFadeDuration)) {
                heroIndex += 1
                heroZoomedIn = false
            }
            try? await Task.sleep(for: .seconds(heroFadeDuration))
        }
    }

    /// Gradien gelap di bagian bawah supaya judul tetap terbaca di atas sampul
    /// seterang apa pun.
    private var scrim: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.55)],
            startPoint: .center,
            endPoint: .bottom)
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(heroSpace)).minY
                } action: { top in
                    // Sel sampul bisa diukur ulang saat sedang didaur ulang di
                    // luar layar, dan ukurannya waktu itu nol. Menerimanya
                    // berarti ambangnya jadi 0 — judul di toolbar tersangkut
                    // menyala selamanya, bahkan setelah digulir balik ke puncak.
                    guard top > 0 else { return }
                    heroTitleTop = top
                }

            Label(itemCountText, systemImage: "photo.stack")
                .font(.subheadline)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    // Deskripsi bisa sepanjang apa pun; dibatasi supaya sampul
                    // tidak berubah tinggi mengikuti isinya.
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var itemCountText: String {
        String(localized: "\(visibleAssets.count) items")
    }

    private func errorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Failed to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }

    private func emptyStateView(_ state: PhotoCollectionEmptyState) -> some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.systemImage)
        } description: {
            if let description = state.description {
                Text(description)
            }
        } actions: {
            if let action = state.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Context menu

    private func requestMenuDelete(_ asset: AssetLite) {
        let target = PhotoCollectionDeleteTarget(asset: asset, session: session)
        guard target.isCurrent(session: session, policy: visibilityPolicy) else { return }
        menuDeleteTarget = target
    }

    private var contextDeleteTitle: LocalizedStringKey {
        let isVideo = menuDeleteTarget?.asset.isVideo == true
        if deletesPermanently { return isVideo ? "Permanently Delete Video?" : "Permanently Delete Photo?" }
        return isVideo ? "Delete Video" : "Delete Photo"
    }

    /// Dibangun dari id, bukan dari salinan aset milik grid — dengan begitu
    /// status favoritnya selalu yang terbaru, bukan yang sempat tersimpan saat
    /// grid terakhir disusun.
    func menuActions(for id: String) -> [PhotoGridMenuAction] {
        guard let asset = asset(for: id) else { return [] }
        let allowsServerActions = canPerformServerActions(asset)

        // TONG SAMPAH hanya punya dua jalan keluar, dan keduanya ada di sini.
        //
        // Foto di sana tidak berada di perpustakaan: memfavoritkannya,
        // memasukkannya ke album, atau membagikannya semuanya menjanjikan
        // sesuatu yang tidak akan terlihat di mana pun. Yang tersisa cuma
        // "kembalikan" atau "hilangkan selamanya".
        if let onRestoreSelection {
            return [
                PhotoGridMenuAction(
                    title: String(localized: "Restore"),
                    systemImage: "arrow.uturn.backward"
                ) {
                    runAction([asset.id]) { await onRestoreSelection([asset.id]) }
                },
                PhotoGridMenuAction(
                    title: deleteActionTitle,
                    systemImage: "trash",
                    isDestructive: true
                ) {
                    requestMenuDelete(asset)
                },
            ]
        }

        // FOLDER TERKUNCI juga punya daftarnya sendiri.
        //
        // Foto di sana sengaja disingkirkan dari pandangan: memfavoritkan atau
        // memasukkannya ke album akan memunculkannya lagi di tempat lain, yang
        // persis kebalikan dari alasan ia ditaruh di situ.
        if let onUnlockSelection {
            return [
                PhotoGridMenuAction(
                    title: String(localized: "Share"),
                    systemImage: "square.and.arrow.up",
                    group: .quick
                ) {
                    share([asset.id])
                },
                PhotoGridMenuAction(title: String(localized: "Copy"), systemImage: "doc.on.doc") {
                    copy([asset.id])
                },
                PhotoGridMenuAction(
                    title: String(localized: "Unlock"),
                    systemImage: "lock.open"
                ) {
                    runAction([asset.id]) { await onUnlockSelection([asset.id]) }
                },
                PhotoGridMenuAction(
                    title: deleteActionTitle,
                    systemImage: "trash",
                    isDestructive: true
                ) {
                    requestMenuDelete(asset)
                },
            ]
        }

        var actions: [PhotoGridMenuAction] = []

        // Tiga teratas jadi BARIS IKON: yang paling sering dipakai, dan
        // ketiganya sudah terbaca dari gambarnya saja.
        if allowsSelectionShare {
            actions.append(
                PhotoGridMenuAction(
                    title: String(localized: "Share"),
                    systemImage: "square.and.arrow.up",
                    group: .quick
                ) {
                    share([asset.id])
                })
            actions.append(PhotoGridMenuAction(
                title: String(localized: "Copy"), systemImage: "doc.on.doc"
            ) { copy([asset.id]) })
        }

        if allowsSelectionShare, visibilityScope != .locked {
            actions.append(PhotoGridMenuAction(title: String(localized: "Slideshow"), systemImage: "play.rectangle") {
                slideshow = PhotoSlideshowPresentation(assets: visibleAssets, initialAssetID: asset.id)
            })
        }

        if let onToggleFavorite, allowsServerActions {
            actions.append(PhotoGridMenuAction(
                title: asset.isFavorite
                    ? String(localized: "Unfavorite")
                    : String(localized: "Favorite"),
                systemImage: asset.isFavorite ? "heart.fill" : "heart",
                group: .quick
            ) {
                runAction([asset.id]) { await onToggleFavorite(asset) }
            })
        }

        if let onArchiveSelection, allowsServerActions {
            actions.append(PhotoGridMenuAction(
                title: archiveActionTitle,
                systemImage: "archivebox",
                group: .quick
            ) {
                runAction([asset.id]) { await onArchiveSelection([asset.id]) }
            })
        }

        if let onAddToAlbum, allowsServerActions {
            actions.append(PhotoGridMenuAction(
                title: String(localized: "Add to Album"),
                systemImage: "rectangle.stack.badge.plus"
            ) {
                if visibilityPolicy.allows(id: asset.id) { onAddToAlbum(asset) }
            })
        }

        if let onMoveToLocked, allowsServerActions {
            actions.append(PhotoGridMenuAction(
                title: String(localized: "Move to Locked Folder"),
                systemImage: "lock"
            ) {
                runAction([asset.id]) { await onMoveToLocked([asset.id]) }
            })
        }

        if let onShareLink, allowsServerActions {
            actions.append(PhotoGridMenuAction(
                title: String(localized: "Share Link"),
                systemImage: "link"
            ) {
                if visibilityPolicy.allows(id: asset.id) { onShareLink([asset.id]) }
            })
        }

        if let removal {
            actions.append(PhotoGridMenuAction(
                title: removal.title,
                systemImage: "minus.circle"
            ) {
                runAction([asset.id]) { await removal.perform([asset.id]) }
            })
        }

        // "Upload" hanya untuk yang BELUM ada di server, dan itu justru
        // satu-satunya foto yang membutuhkannya.
        if let onUpload, asset.needsUpload {
            actions.append(PhotoGridMenuAction(
                title: String(localized: "Upload"),
                systemImage: "arrow.up.circle"
            ) {
                runAction([asset.id]) { await onUpload([asset.id]) }
            })
        }

        if let deviceAction = DeviceCopyDeletion.menuAction(
            for: asset, request: { if visibilityPolicy.allows(id: $0) { deviceDeleteID = $0 } }) {
            actions.append(deviceAction)
        }

        actions.append(PhotoGridMenuAction(
            title: String(localized: "Delete"),
            systemImage: "trash",
            isDestructive: true
        ) {
            requestMenuDelete(asset)
        })

        return actions
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var screenToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) { selectAllButton }
            // Jumlahnya pindah ke bar ATAS: bar bawah sekarang penuh aksi, dan
            // menyelipkan teks di antaranya hanya membuat tombol-tombolnya
            // berdesakan.
            ToolbarItem(placement: .principal) { selectionLabel }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { cancelSelectionButton }

            SelectionToolbar(actions: selectionActions)
        } else {
            // Item DIGATE, bukan isinya.
            //
            // Item principal memetakan ke `navigationItem.titleView`, dan
            // titleView kosong MENGGANTIKAN judul — bukan mundur ke
            // `navigationTitle`. Kalau yang digate cuma isinya, mode bulanan
            // (Archived, Trash, Locked Folder) kehilangan judul barnya.
            if layout == .hero && !isShowingUnavailableScreen {
                ToolbarItem(placement: .principal) { dockedTitle }
                    // Judul bukan tombol; kapsul kaca bawaan toolbar hanya
                    // menaruh alas di belakang tulisan yang tidak bisa ditekan.
                    .sharedBackgroundVisibility(.hidden)
            }

            if !isShowingUnavailableScreen {
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }

            // Tidak ada foto untuk dipilih. Tombolnya bukan cuma percuma — ia
            // mengunci layar di mode pilih yang tidak bisa dibatalkan lewat apa
            // pun selain tombol yang sama.
            //
            // Spacer-nya ikut digate. Ia memisahkan dua kapsul kaca; ditinggal
            // sendirian tanpa item sesudahnya, yang tersisa cuma celah
            // menggantung di ujung bar.
            if !isShowingUnavailableScreen {
                // Memisahkan keduanya jadi dua kapsul kaca terpisah, bukan satu
                // grup yang menempel.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                }
            }
        }
    }

    @ViewBuilder
    private var optionsMenu: some View {
        // Layar tanpa menu opsi tidak boleh menampilkan kapsul elipsis kosong.
        if Options.self != EmptyView.self || layout == .hero {
            Menu {
                if layout == .hero {
                    Menu("View Options") {
                        if facePersonID != nil {
                            Button { showsFaces = false } label: {
                                if showsFaces { Text("Photos") }
                                else { Label("Photos", systemImage: "checkmark") }
                            }
                            Button { showsFaces = true } label: {
                                if showsFaces { Label("Faces", systemImage: "checkmark") }
                                else { Text("Faces") }
                            }
                            Divider()
                        }
                        if let viewOptions { viewOptions() }
                        Button("Zoom In", systemImage: "plus.magnifyingglass") {
                            gridController?.zoomDensity(in: true)
                        }
                        .disabled(PhotoGridDensity.next(columns: gridColumns, zoomingIn: true) == nil)
                        Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                            gridController?.zoomDensity(in: false)
                        }
                        .disabled(PhotoGridDensity.next(columns: gridColumns, zoomingIn: false) == nil)
                        Toggle("Aspect Ratio Grid", isOn: $aspectRatioGrid)
                            .disabled(showsFaces)
                    }
                    let mapPolicy = AssetVisibilityPolicy(scope: .timeline)
                    if visibilityScope != .locked && onRestoreSelection == nil && onUnlockSelection == nil,
                       visibleAssets.contains(where: { mapPolicy.allows(id: $0.id) }) {
                        Button("Show Map", systemImage: "map") { showsMap = true }
                        Button("Slideshow", systemImage: "play.rectangle") {
                            slideshow = PhotoSlideshowPresentation(assets: visibleAssets)
                        }
                    }
                }
                options()
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .confirmationDialog(
                optionsConfirmation?.title ?? "",
                isPresented: optionsConfirmationPresented ?? .constant(false),
                titleVisibility: .visible
            ) {
                ForEach(optionsConfirmation?.options ?? []) { option in
                    Button(
                        option.title,
                        role: option.isDestructive ? .destructive : nil,
                        action: option.handler)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let message = optionsConfirmation?.message {
                    Text(message)
                }
            }
        }
    }

    private var selectAllButton: some View {
        Button(isAllSelected ? "Deselect All" : "Select All") {
            if isAllSelected {
                selectedIDs.removeAll()
            } else {
                selectedIDs = Set(visibleAssets.map(\.id))
            }
        }
    }

    private var isAllSelected: Bool {
        !visibleAssets.isEmpty && selectedIDs.count == visibleAssets.count
    }

    private var cancelSelectionButton: some View {
        Button {
            endSelection()
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Cancel")
    }

    /// Aksi mode pilih untuk layar ini.
    ///
    /// Dirakit di satu tempat, bukan ditulis sebagai empat tombol di dalam
    /// toolbar: susunannya sama di semua layar, dan yang berbeda cuma aksi mana
    /// yang tersedia.
    private var selectionActions: SelectionActions {
        selectionActions(for: visibleAssets.filter { selectedIDs.contains($0.id) }.map(\.id))
    }

    func selectionActions(for ids: [String]) -> SelectionActions {
        let allowsServerActions = ids.allSatisfy { id in
            guard let asset = asset(for: id) else { return false }
            return canPerformServerActions(asset)
        }
        var actions = SelectionActions()
        // Tombolnya tetap terlihat saat belum ada yang dipilih, hanya dimatikan.
        // Bar yang berubah-ubah isinya sesuai jumlah pilihan lebih membingungkan
        // daripada tombol kelabu.
        actions.isBusy = isPreparingShare || copyPreparation.isPreparing || isPerformingAction || ids.isEmpty

        if allowsSelectionShare { actions.share = { share(ids) } }
        actions.trashConfirmation = SelectionConfirmation(
            title: destructiveDialogTitle,
            message: deletesPermanently ? String(localized: "This cannot be undone.") : nil,
            options: destructiveOptions)

        if onRestoreSelection != nil {
            actions.restoreConfirmation = SelectionConfirmation(
                title: String(localized: "Restore these photos to your library?"),
                options: [SelectionConfirmationOption(
                    title: String(localized: "Restore")) { runRestore() }])
        }
        if let onFavoriteSelection, allowsServerActions {
            actions.favorite = {
                runSelection(ids) {
                    await onFavoriteSelection(ids)
                    if actionError.wrappedValue == nil { favoriteFeedback += 1 }
                }
            }
        }
        if let onArchiveSelection, allowsServerActions {
            actions.archiveTitle = archiveActionTitle
            actions.archive = { runSelection(ids) { await onArchiveSelection(ids) } }
        }
        var menu = (selectionMenu?(Set(ids)) ?? []).map { action in
            SelectionMenuAction(title: action.title, systemImage: action.systemImage,
                                isDestructive: action.isDestructive) {
                guard ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else {
                    endSelection()
                    return
                }
                action.handler()
            }
        }
        if allowsSelectionShare {
            menu.insert(SelectionMenuAction(title: "Copy", systemImage: "doc.on.doc") { copy(ids) }, at: 0)
            if visibilityScope != .locked {
                menu.insert(SelectionMenuAction(title: "Slideshow", systemImage: "play.rectangle") {
                    slideshow = PhotoSlideshowPresentation(assets: visibleAssets.filter { ids.contains($0.id) })
                }, at: 1)
            }
        }
        if let onMoveToLocked, allowsServerActions {
            menu.append(SelectionMenuAction(
                title: "Move to Locked Folder", systemImage: "lock"
            ) {
                runSelection(ids) { await onMoveToLocked(ids) }
            })
        }
        actions.menu = menu
        return actions
    }

    private func runSelection(_ ids: [String], _ work: @escaping () async -> Void) {
        guard !isPerformingAction, !ids.isEmpty else { return }
        guard ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else {
            endSelection()
            return
        }
        isPerformingAction = true
        Task {
            defer { isPerformingAction = false }
            guard !Task.isCancelled, ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else {
                endSelection()
                return
            }
            await work()
            if actionError.wrappedValue == nil { endSelection() }
        }
    }

    private func runRestore() {
        guard let onRestoreSelection else { return }
        let ids = Array(selectedIDs)
        runSelection(ids) { await onRestoreSelection(ids) }
    }

    private var destructiveDialogTitle: String {
        removal == nil
            ? String(localized: "Are you sure you want to delete these photos?")
            : String(localized: "Do you want to delete these photos or remove them from this collection?")
    }

    /// Isi dialog tombol sampah.
    ///
    /// Koleksi yang bisa "dikeluarkan isinya" punya DUA arti untuk ikon yang
    /// sama — mengeluarkan foto dari album tidak sama dengan menghapusnya dari
    /// perpustakaan — dan keduanya tidak bisa dibedakan dari gambarnya saja.
    private var destructiveOptions: [SelectionConfirmationOption] {
        var options: [SelectionConfirmationOption] = []
        if let removal {
            options.append(SelectionConfirmationOption(title: removal.title) {
                runRemoval(removal)
            })
        }
        options.append(SelectionConfirmationOption(
            title: deleteActionTitle, isDestructive: true) {
            runDelete()
        })
        return options
    }

    /// "Delete Permanently" di tempat yang memang permanen.
    ///
    /// Kata "Delete" saja sudah benar di layar lain — fotonya pindah ke tong
    /// sampah dan masih bisa diambil kembali. Di sini tidak ada tempat kembali,
    /// dan tombolnya harus mengatakan itu sebelum ditekan, bukan sesudahnya.
    private var deleteActionTitle: String {
        deletesPermanently
            ? String(localized: "Delete Permanently")
            : String(localized: "Delete")
    }

    /// Hapus permanen terasa BERBEDA di tangan.
    ///
    /// Ketukan berat yang sama untuk "pindah ke tong sampah" dan "hilang
    /// selamanya" membuat keduanya tidak bisa dibedakan tanpa melihat layar —
    /// padahal justru yang kedua yang perlu dikenali.
    private var deleteHaptic: SensoryFeedback {
        deletesPermanently ? .warning : .impact(weight: .heavy)
    }

    private var selectionLabel: some View {
        Text(selectionTitle)
            .font(.subheadline)
            .lineLimit(1)
            .fixedSize()
    }

    private var selectionTitle: String {
        let count = selectedIDs.count
        guard count > 0 else { return String(localized: "Select Items") }
        return count == 1 ? "1 Item Selected" : "\(count) Items Selected"
    }

    // MARK: - Aksi

    private func copy(_ selectedIDs: [String]) {
        let selected = Set(selectedIDs)
        let ids = visibleAssets.filter { selected.contains($0.id) }.map(\.id)
        guard ids.count == selectedIDs.count else { return }
        let api = APIClient(session: session)
        let context = session.snapshot
        let media = Dictionary(ids.compactMap { id in asset(for: id).map { (id, $0.isVideo) } },
            uniquingKeysWith: { _, current in current })
        guard media.count == ids.count else { return }
        copyPreparation.start(ids: ids, prepare: { ids in
            let urls = await shareURLs(ids)
            guard urls.count == ids.count else { TemporaryMediaStore.remove(urls); return [] }
            return zip(ids, urls).map { MediaCopy.Source(url: $0.1, isVideo: media[$0.0] == true) }
        }, isAllowed: { (try? api.checkCurrent(context)) != nil && visibilityPolicy.allows(id: $0) },
            onError: { actionError.wrappedValue = $0 })
    }

    private func share(_ ids: [String]) {
        guard !isSharePresented else { return }
        sharePreparation.start(ids: ids, session: session, prepare: { await shareURLs($0) },
            isAllowed: { visibilityPolicy.allows(id: $0) },
            onError: { actionError.wrappedValue = $0 }) { urls in
            preparedURLs = urls
            preparedAssetIDs = ids
            sharedSourceIDs = sharePreparation.preparedSourceIDs
            sharedRequestContext = sharePreparation.preparedContext
            isSharePresented = true
        }
    }

    private func cleanupPreparedShare() {
        TemporaryMediaStore.remove(preparedURLs)
        preparedURLs.removeAll()
        preparedAssetIDs.removeAll()
        sharedSourceIDs.removeAll()
        sharedRequestContext = nil
    }

    private func runRemoval(_ removal: PhotoCollectionRemoval) {
        let ids = Array(selectedIDs)
        runSelection(ids) { await removal.perform(ids) }
    }

    private func runDelete() {
        let ids = Array(selectedIDs)
        runSelection(ids) {
            await onDelete(ids)
            if actionError.wrappedValue == nil { deleteFeedback += 1 }
        }
    }

    private func endSelection() {
        sharePreparation.cancel()
        copyPreparation.cancel()
        selectedIDs.removeAll()
        isSelecting = false
    }

    private func runAction(_ ids: [String], _ work: @escaping () async -> Void) {
        guard !ids.isEmpty, ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else { return }
        Task {
            guard !Task.isCancelled, ids.allSatisfy({ visibilityPolicy.allows(id: $0) }) else { return }
            await work()
        }
    }
}

// Konstanta di level file, bukan `static let` di dalam `PhotoCollectionScreen`:
// tipe itu generik, dan Swift melarang properti tersimpan statis di tipe generik.
/// Nama ruang koordinat sampul, dipakai bersama oleh sampul dan pengukur judul.
private let heroSpace = "photoCollection.hero"

private let heroHoldDuration: Double = 7
private let heroFadeDuration: Double = 1.4

/// Mengelompokkan koleksi menjadi section untuk grid, DI LUAR main actor.
///
/// Untuk mode sampul hasilnya satu section tanpa judul: isinya sudah satu
/// tumpukan, dan memaksakan pembagian bulan hanya menambah baris judul yang
/// tidak diminta.
private func groupAssets(
    _ assets: [AssetLite],
    monthly: Bool
) async -> [TimelineSection] {
    guard !assets.isEmpty else { return [] }

    guard monthly else {
        return [TimelineSection(
            id: "all", title: "", assets: assets,
            count: assets.count, startIndex: 0)]
    }

    return await Task.detached(priority: .userInitiated) {
        var sections: [TimelineSection] = []
        sections.reserveCapacity(32)

        for (offset, asset) in assets.enumerated() {
            let key = MonthKey.of(asset.createdAt)
            if sections.last?.id == key {
                sections[sections.count - 1].assets.append(asset)
                sections[sections.count - 1].count += 1
            } else {
                sections.append(TimelineSection(
                    id: key,
                    title: TimelineViewModel.formatBucketTitle(key),
                    assets: [asset],
                    count: 1,
                    startIndex: offset))
            }
        }
        return sections
    }.value
}

extension PhotoCollectionScreen where Options == EmptyView {
    /// Versi tanpa menu elipsis, supaya pemanggilnya tidak perlu menulis
    /// `options: { EmptyView() }` sendiri.
    init(
        title: LocalizedStringKey,
        layout: PhotoCollectionLayout = .hero,
        subtitle: String? = nil,
        heroAssetID: String? = nil,
        assets: [AssetLite],
        phase: LoadingPhase<Void>,
        actionError: Binding<String?> = .constant(nil),
        emptyState: PhotoCollectionEmptyState? = nil,
        onRetry: @escaping () -> Void,
        onToggleFavorite: ((AssetLite) async -> Void)? = nil,
        onDelete: @escaping ([String]) async -> Void,
        shareURLs: @escaping ([String]) async -> [URL],
        onAddPhotos: (() -> Void)? = nil,
        removal: PhotoCollectionRemoval? = nil,
        onAddToAlbum: ((AssetLite) -> Void)? = nil,
        onFavoriteSelection: (([String]) async -> Void)? = nil,
        onArchiveSelection: (([String]) async -> Void)? = nil,
        archiveActionTitle: String = String(localized: "Archive"),
        onRestoreSelection: (([String]) async -> Void)? = nil,
        onUnlockSelection: (([String]) async -> Void)? = nil,
        onMoveToLocked: (([String]) async -> Void)? = nil,
        onShareLink: (([String]) -> Void)? = nil,
        onUpload: (([String]) async -> Void)? = nil,
        allowsSelectionShare: Bool = true,
        deletesPermanently: Bool = false,
        visibilityScope: AssetVisibilityPolicy.Scope = .collection,
        canPerformServerActions: @escaping (AssetLite) -> Bool = { _ in true },
        facePersonID: String? = nil,
        keepsTabBarVisible: Bool = false,
        onSelectionChanged: @escaping (Bool) -> Void = { _ in },
        selectionMenu: ((Set<String>) -> [SelectionMenuAction])? = nil
    ) {
        self.init(
            title: title,
            layout: layout,
            subtitle: subtitle,
            heroAssetID: heroAssetID,
            assets: assets,
            phase: phase,
            actionError: actionError,
            emptyState: emptyState,
            onRetry: onRetry,
            onToggleFavorite: onToggleFavorite,
            onDelete: onDelete,
            shareURLs: shareURLs,
            onAddPhotos: onAddPhotos,
            removal: removal,
            onAddToAlbum: onAddToAlbum,
            onFavoriteSelection: onFavoriteSelection,
            onArchiveSelection: onArchiveSelection,
            archiveActionTitle: archiveActionTitle,
            onRestoreSelection: onRestoreSelection,
            onUnlockSelection: onUnlockSelection,
            onMoveToLocked: onMoveToLocked,
            onShareLink: onShareLink,
            onUpload: onUpload,
            allowsSelectionShare: allowsSelectionShare,
            deletesPermanently: deletesPermanently,
            visibilityScope: visibilityScope,
            canPerformServerActions: canPerformServerActions,
            facePersonID: facePersonID,
            keepsTabBarVisible: keepsTabBarVisible,
            onSelectionChanged: onSelectionChanged,
            selectionMenu: selectionMenu,
            options: { EmptyView() })
    }
}

enum PhotoCollectionCover {
    static func assets(in visibleAssets: [AssetLite], preferredID: String?) -> [AssetLite] {
        if let preferredID, let asset = visibleAssets.first(where: { $0.id == preferredID }) {
            return [asset]
        }
        return Array(visibleAssets.prefix(8))
    }
}

@MainActor
private struct PhotoCollectionDeleteTarget {
    let asset: AssetLite
    private let sourceID: String
    private let generation = LocalSnapshot.generation
    private let context: SessionRequestContext

    init(asset: AssetLite, session: SessionManager) {
        self.asset = asset
        sourceID = AssetServerIdentity.resolve(asset) ?? asset.id
        context = session.snapshot
    }

    func isCurrent(session: SessionManager, policy: AssetVisibilityPolicy) -> Bool {
        generation == LocalSnapshot.generation && context == session.snapshot
            && (AssetServerIdentity.resolve(asset) ?? asset.id) == sourceID
            && policy.allows(id: asset.id) && policy.allows(id: sourceID)
    }
}
