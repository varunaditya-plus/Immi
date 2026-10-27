import SwiftUI

/// Daftar koleksi ala Photos: sebagian baris bisa dilipat dan memperlihatkan
/// isinya sebagai deret mendatar, sebagian lagi baris biasa yang langsung
/// mendorong ke layarnya.
struct LibraryView: View {
    /// TabView dapat membangun Library walau Photos masih aktif; hanya tab yang
    /// terlihat yang boleh menjadi jangkar coach mark profil.
    var isActive = true

    @Environment(SessionManager.self) private var session
    @State private var vm: LibraryViewModel?
    /// Baris yang sedang terbuka. Pada pemakaian pertama semuanya tertutup;
    /// sesudah itu mengikuti pilihan terakhir pengguna.
    @State private var expanded: Set<Row>
    @State private var showSettings = false
    @State private var showBackup = false
    @State private var backupNotifier = BackupNotifier.shared
    @State private var editTarget: AlbumResponseDTO?
    @State private var addUserTarget: AlbumResponseDTO?
    @State private var deleteTarget: AlbumResponseDTO?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var albumPickerAsset: AssetLite?
    @State private var assetToDelete: AssetLite?
    @State private var shareFileURL: SharedLinkPresentation?
    @State private var deleteFeedback = 0
    @State private var backupSetupJourney = BackupSetupJourney.shared
    @State private var navigation = AppNavigation.shared
    @State private var navigationPath: [ExternalRoute] = []
    /// Kenangan yang sedang dibuka sebagai story; nil berarti tertutup.
    @State private var openedStoryID: String?
    /// Namespace zoom transition untuk kartu album.
    ///
    /// Dideklarasikan di sini, bukan di `AlbumCard`: sumber dan tujuan transisi
    /// harus berbagi namespace yang SAMA, sedangkan tiap kartu punya
    /// `@Namespace`-nya sendiri kalau dideklarasikan di dalamnya.
    @Namespace private var albumNamespace
    @Namespace private var assetNamespace
    @Namespace private var personNamespace

    enum Row: String, CaseIterable, Hashable {
        // `utilities` sudah dihapus. Nilai lama yang masih tersimpan di
        // UserDefaults tidak masalah: `Row(rawValue:)` mengembalikan nil dan
        // `compactMap` membuangnya.
        case memories, albums, favorites, people
    }

    private enum ExternalRoute: Hashable {
        case favorites
        case memories
        case album(String)
    }

    private static let expandedKey = "library.expandedRows"

    /// Dibaca LANGSUNG di init, bukan lewat `onAppear`.
    ///
    /// Menyetelnya setelah view muncul berarti barisnya sempat tampil terbuka
    /// lalu menutup sendiri — kelihatan seperti animasi lipat yang tidak diminta
    /// setiap kali tab ini dibuka.
    init(isActive: Bool = true) {
        self.isActive = isActive
        // Nil berarti belum pernah disimpan (semua tertutup); string kosong
        // berarti pengguna memang menutup semuanya. Keduanya harus dibedakan.
        guard let stored = UserDefaults.standard.string(forKey: Self.expandedKey) else {
            _expanded = State(initialValue: [])
            return
        }
        var rows = Set(stored.split(separator: ",").compactMap { Row(rawValue: String($0)) })
        // On This Day SELALU terbuka saat aplikasi dibuka.
        //
        // Isinya berganti tiap hari dan cuma ada hari ini; membiarkannya tertutup
        // karena kemarin pernah dilipat berarti kenangan hari ini tidak pernah
        // terlihat. Melipatnya tetap boleh — hanya tidak diingat.
        rows.insert(.memories)
        _expanded = State(initialValue: rows)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            assetActionPresentations
                // Nav bar TETAP dipakai — blur tepi progresifnya digambar oleh
                // bar itu; menyembunyikannya berarti kehilangan blurnya. Yang
                // dimatikan hanya latar solidnya.
                //
                // Judulnya toolbar item biasa, bukan `navigationTitle`, karena
                // item toolbar tidak menyusut atau pindah ke tengah saat
                // di-scroll — sama seperti di Photos.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { libraryToolbar }
                .sheet(isPresented: $showSettings) { settingsSheet }
                .onChange(of: showSettings) { _, isPresented in
                    if !isPresented {
                        Task { @MainActor in
                            // Anchor toolbar baru aman dipakai setelah sheet
                            // benar-benar meninggalkan presentation hierarchy.
                            try? await Task.sleep(for: .milliseconds(450))
                            guard !showSettings else { return }
                            backupSetupJourney.returnToProfileIfNeeded()
                        }
                    }
                }
                .navigationDestination(isPresented: $showBackup) { BackupView() }
                // Separuh kedua dari pengantaran itu — lihat `MainTabView`.
                .onChange(of: backupNotifier.shouldOpenBackup) { _, requested in
                    guard requested else { return }
                    openBackupScreen()
                }
                .fullScreenCover(isPresented: openedStoryBinding) { memoryStoryCover }
                .navigationDestination(for: ExternalRoute.self) { route in
                    externalDestination(route)
                }
                .onChange(of: navigation.pendingDestination) { _, destination in
                    // TabView membangun Library walau Photos/Search masih
                    // terlihat. Hanya Library aktif yang boleh mengonsumsi
                    // rute; kalau tidak, MainTabView kehilangan kesempatan
                    // memindahkan tab dan pengguna tetap berada di halaman lama.
                    guard isActive, let destination else { return }
                    openExternalDestination(destination)
                }
                .onChange(of: isActive) { _, active in
                    guard active, let destination = navigation.pendingDestination
                    else { return }
                    openExternalDestination(destination)
                }
                .onChange(of: SwiftDataManager.shared.assetMutationRevision) { _, _ in
                    Task { await vm?.refreshFavorites() }
                }
                .task {
                    if backupNotifier.shouldOpenBackup { openBackupScreen() }
                    await start()
                    if isActive, let destination = navigation.pendingDestination {
                        openExternalDestination(destination)
                    }
                }
        }
    }

    @ViewBuilder
    private func externalDestination(_ route: ExternalRoute) -> some View {
        switch route {
        case .favorites:
            AssetCollectionView(
                title: "Favorites",
                request: SearchRequestDTO(isFavorite: true, size: 200),
                isFavoritesCollection: true)
        case .memories:
            MemoriesView()
        case .album(let id):
            RoutedAlbumView(
                albumID: id,
                cachedAlbum: vm?.albums.first(where: { $0.id == id }),
                onContentsChanged: { assets in
                    guard vm?.applyAlbumContents(assets, to: id) == true
                    else { return }
                    Task { await vm?.refreshAlbums(invalidatingCoverFor: id) }
                },
                onAlbumChanged: { vm?.applyAlbumUpdate($0) })
        }
    }

    private func openExternalDestination(_ destination: AppNavigation.Destination) {
        let route: ExternalRoute
        switch destination {
        case .favorites:
            route = .favorites
        case .memories:
            route = .memories
        case .album(let id):
            route = .album(id)
        case .search:
            return
        }

        navigationPath = [route]
        navigation.consume(destination)
    }

    private func openBackupScreen() {
        showBackup = true
        backupNotifier.didOpenBackup()
    }

    /// Sheet & dialog dipisah jadi dua lapis properti, bukan satu rantai
    /// panjang di `body`: rantai sepanjang itu rutin membuat pengecek tipe
    /// Swift menyerah ("unable to type-check this expression").
    private var albumActionPresentations: some View {
        rows
            .sheet(item: $editTarget) { album in
                AlbumEditSheet(album: album) { updated in
                    vm?.applyAlbumUpdate(updated)
                }
            }
            .sheet(item: $addUserTarget) { album in
                AlbumAddUserSheet(album: album) { userIDs in
                    Task { await vm?.addUsers(userIDs, to: album.id) }
                }
            }
            .sheet(item: $sharedLink) { link in
                ShareSheet(url: link.url)
            }
    }

    private var assetActionPresentations: some View {
        albumActionPresentations
            .sheet(item: $shareFileURL) { item in
                ShareSheet(url: item.url)
            }
            .sheet(item: $albumPickerAsset) { asset in
                AlbumPickerSheet(albums: vm?.albums ?? []) { album in
                    Task { await vm?.addToAlbum(asset, album: album) }
                }
            }
            .alert("Delete Photo", isPresented: assetDeleteBinding) {
                Button("Delete", role: .destructive) { commitAssetDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this photo?")
            }
            .alert("Action Failed", isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm?.actionError ?? "")
            }
            // Ketukan tegas hanya setelah server mengonfirmasi penghapusan.
            .sensoryFeedback(.impact(weight: .heavy), trigger: deleteFeedback)
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { vm?.actionError != nil },
            set: { if !$0 { vm?.actionError = nil } })
    }

    /// "Nothing here yet" baru boleh diucapkan setelah kita benar-benar tahu.
    ///
    /// Isi Library datang dari jaringan dan tidak punya cache lokal, jadi pada
    /// pembukaan pertama semuanya memang kosong sesaat. Menyebutnya kosong di
    /// situ adalah pernyataan yang tegas padahal permintaannya bahkan belum
    /// dikirim — dan yang terlihat pengguna adalah perpustakaan yang seolah
    /// hilang isinya.
    private var hasLoaded: Bool { vm?.hasLoaded ?? false }

    /// Baris mana saja yang sudah punya isi — pemicu animasi lipat otomatis.
    ///
    /// Satu angka, bukan empat pengamatan terpisah: `.animation(_:value:)` hanya
    /// menerima satu nilai, dan yang penting cuma "ada yang berubah", bukan yang
    /// mana. Selama satu tik semuanya datang bersamaan (view model memasang
    /// keempatnya sekaligus), jadi seluruh baris terbuka dalam satu gerakan.
    private var contentReadiness: Int {
        var flags = 0
        if !(vm?.memories.isEmpty ?? true) { flags |= 1 }
        if !(vm?.albums.isEmpty ?? true) { flags |= 2 }
        if !(vm?.favorites.isEmpty ?? true) { flags |= 4 }
        if !(vm?.people.isEmpty ?? true) { flags |= 8 }
        if hasLoaded { flags |= 16 }
        return flags
    }

    private var rows: some View {
        ScrollView {
            // VStack biasa, bukan LazyVStack: isinya cuma enam baris, dan
            // versi lazy membangun ulang baris saat tinggi berubah sehingga
            // animasi lipatnya tersendat.
            VStack(alignment: .leading, spacing: 28) {
                memoriesSection
                albumsSection
                favoritesSection
                peopleSection
                fixedRows
            }
            .padding(.vertical, 12)
            // Animasi dipasang DI SINI, bukan di baris masing-masing.
            //
            // Baris kenangan berupa `if` di dalam `@ViewBuilder`, dan baris
            // lainnya membuka lewat binding yang nilainya berubah sendiri saat
            // isinya datang. Dua-duanya perlu wadah yang SELALU ada untuk
            // mengamati perubahannya — kalau dipasang di barisnya sendiri, saat
            // isinya belum ada tidak ada view apa pun di situ yang bisa
            // mengamati, dan barisnya menyodok masuk tanpa animasi.
            .animation(.smooth(duration: 0.35), value: contentReadiness)
        }
        // Alasan sama seperti di `CollectionSection`: klip scroll memangkas
        // pratinjau context menu. Bidang scroll ini sendiri sudah selebar dan
        // setinggi layar, jadi tidak ada yang benar-benar meluber terlihat.
        .scrollClipDisabled()
        // Blur tepi lembut ala iOS 26 saat isi lewat di bawah judul.
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: - Aksi album

    private func albumMenu(for album: AlbumResponseDTO) -> some View {
        AlbumActionsMenu(
            onEdit: { editTarget = album },
            onAddUser: { addUserTarget = album },
            onCreateLink: { createLink(for: album) },
            onDelete: { deleteTarget = album })
    }

    private func deleteBinding(for album: AlbumResponseDTO) -> Binding<Bool> {
        Binding(
            get: { deleteTarget?.id == album.id },
            set: { isPresented in
                if !isPresented, deleteTarget?.id == album.id {
                    deleteTarget = nil
                }
            })
    }

    // confirmationDialog memakai binding Bool, sementara sasarannya perlu
    // disimpan sebagai nilai — jembatannya di sini.
    /// `isPresented`, bukan `item`: id-nya sekadar `String`, dan membungkusnya
    /// jadi tipe `Identifiable` hanya untuk keperluan satu sheet lebih banyak
    /// daripada yang dihematnya.
    private var openedStoryBinding: Binding<Bool> {
        Binding(
            get: { openedStoryID != nil },
            set: { if !$0 { openedStoryID = nil } })
    }

    private func createLink(for album: AlbumResponseDTO) {
        Task {
            sharedLink = await SharedLinkPresentation.create(
                albumId: album.id, session: session)
        }
    }

    // MARK: - Aksi foto

    private func assetMenu(for asset: AssetLite) -> some View {
        AssetActionsMenu(
            asset: asset,
            onShare: { shareAsset(asset) },
            onToggleFavorite: { Task { await vm?.toggleFavorite(asset) } },
            onArchive: { Task { await vm?.archive(asset) } },
            onAddToAlbum: { albumPickerAsset = asset },
            onDelete: { assetToDelete = asset })
    }

    private func shareAsset(_ asset: AssetLite) {
        Task {
            guard let url = await vm?.shareURL(for: asset) else { return }
            shareFileURL = SharedLinkPresentation(url: url)
        }
    }

    private var assetDeleteBinding: Binding<Bool> {
        Binding(
            get: { assetToDelete != nil },
            set: { if !$0 { assetToDelete = nil } })
    }

    private func commitAssetDelete() {
        guard let asset = assetToDelete else { return }
        Task {
            if await vm?.delete(asset) == true { deleteFeedback += 1 }
        }
    }

    private func start() async {
        if vm == nil {
            let api = APIClient(session: session)
            vm = LibraryViewModel(
                memoriesRepo: MemoriesRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                peopleRepo: PeopleRepository(api: api),
                searchRepo: SearchRepository(api: api),
                assetRepo: AssetDetailRepository(api: api))
        }

        // Data pengguna ditanyakan ulang SETIAP KALI Library dibuka, tidak
        // seperti isi barisnya yang cuma dimuat sekali: hanya dari sinilah
        // aplikasi tahu foto profilnya diganti di server. Permintaannya kecil,
        // dan gambarnya baru benar-benar diunduh kalau penanda perubahannya
        // memang berbeda dari yang ada di cache.
        async let profile: Void = session.refreshUser()
        // `load()`, bukan `loadIfNeeded()`.
        //
        // Penjaga "sekali saja" itu ada untuk menghindari empat permintaan tiap
        // kali tab dibuka — dan yang membuatnya perlu adalah layar yang menunggu
        // keempatnya selesai. Sekarang isinya digambar dari potret lebih dulu
        // dan hanya diganti kalau memang berbeda, jadi penyegarannya tidak
        // terlihat sama sekali. Yang ikut hilang bersama penjaga itu: Library
        // yang terkunci pada potret sampai aplikasinya dijalankan ulang.
        await vm?.load()
        await profile
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { titleLabel }
            // Judul tidak boleh dapat latar kapsul seperti tombol.
            .sharedBackgroundVisibility(.hidden)
        profileButton
    }

    private var titleLabel: some View {
        Text("Library")
            .font(.largeTitle.bold())
            .lineLimit(1)
            // WAJIB: tanpa ini toolbar menyempitkan item sampai selebar ikon
            // dan judulnya tersisa jadi "…".
            .fixedSize()
    }

    @ToolbarContentBuilder
    private var profileButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            JourneyProfileButton(isActive: isActive) {
                showSettings = true
            }
        }
        // Avatarnya sudah bulat penuh; kapsul kaca bawaan toolbar hanya
        // menambah lingkaran kedua yang lebih besar di belakangnya.
        .sharedBackgroundVisibility(.hidden)
    }

    private var settingsSheet: some View {
        SettingsSheetView(session: session)
    }

    // MARK: - Baris yang bisa dilipat

    /// Baris kenangan DIHILANGKAN sama sekali kalau tidak ada kenangan.
    ///
    /// Baris lain boleh tampil kosong — album dan orang memang bisa ditambah
    /// pengguna, jadi judulnya berguna sebagai pintu masuk. Kenangan tidak: ia
    /// disusun server dari tanggal hari ini, dan di hari yang tidak punya foto
    /// dari tahun-tahun sebelumnya tidak ada yang bisa dilakukan pengguna.
    /// Judul dengan "Nothing here yet" di bawahnya hanya menyisakan ruang mati
    /// di puncak Library.
    /// Kenangan MUNCUL BELAKANGAN — datang setelah permintaannya selesai,
    /// sementara baris lain sudah ada sejak layar digambar. Tanpa animasi ia
    /// menyodok masuk dan mendorong seluruh isi Library ke bawah secara
    /// mendadak. Melarutkannya saja sudah cukup; yang bergerak justru
    /// baris-baris di bawahnya. Animasinya sendiri dipasang di VStack induk.
    @ViewBuilder
    private var memoriesSection: some View {
        let memories = vm?.memories ?? []
        if !memories.isEmpty {
            CollectionSection(
                title: "On This Day",
                isExpanded: binding(for: .memories),
                isEmpty: false,
                contentHeight: 240,
                destination: { MemoriesView() }
            ) {
                ForEach(memories) { story in
                    MemoryCard(story: story) { openedStoryID = story.id }
                }
            }
            .transition(.opacity)
        }
    }

    /// Story kenangan dibuka lewat `fullScreenCover`, bukan `NavigationLink`.
    ///
    /// Story adalah layar penuh tanpa nav bar dan tanpa tab bar; mendorongnya ke
    /// dalam stack berarti melawan kedua bar itu sepanjang tampilannya.
    @ViewBuilder
    private var memoryStoryCover: some View {
        if let vm, let openedStoryID {
            MemoryStoryView(
                stories: vm.memories,
                initialStoryID: openedStoryID,
                prepareShare: { await vm.shareURL(for: $0) })
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        let albums = vm?.albums ?? []
        CollectionSection(
            title: "Albums",
            isExpanded: expansion(for: .albums, hasContent: !albums.isEmpty),
            isEmpty: hasLoaded && albums.isEmpty,
            contentHeight: 200,
            destination: {
                AlbumsListView(onAlbumUpdated: { vm?.applyAlbumUpdate($0) })
            }
        ) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(
                        album: album,
                        onContentsChanged: { assets in
                            guard vm?.applyAlbumContents(assets, to: album.id) == true
                            else { return }
                            Task {
                                await vm?.refreshAlbums(
                                    invalidatingCoverFor: album.id)
                            }
                        },
                        onAlbumChanged: { vm?.applyAlbumUpdate($0) })
                        .navigationTransition(
                            .zoom(sourceID: album.id, in: albumNamespace))
                } label: {
                    AlbumCard(album: album)
                        // AlbumResponseDTO memakai id sebagai identitas. Revision
                        // visual ini memaksa count dan AuthImage cover dibangun
                        // ulang ketika isi berubah tanpa mengganti id navigasi.
                        .id("\(album.id)|\(album.assetCount)|\(album.albumThumbnailAssetId ?? "")")
                        .matchedTransitionSource(id: album.id, in: albumNamespace)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    albumMenu(for: album)
                } preview: {
                    AlbumCoverPreview(album: album, session: session)
                }
                .confirmationDialog(
                    "Delete “\(album.albumName)”?",
                    isPresented: deleteBinding(for: album),
                    titleVisibility: .visible
                ) {
                    Button("Delete Album", role: .destructive) {
                        deleteTarget = nil
                        Task { await vm?.deleteAlbum(album.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The photos will stay in your library.")
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = vm?.favorites ?? []
        CollectionSection(
            title: "Favorites",
            isExpanded: expansion(for: .favorites, hasContent: !favorites.isEmpty),
            isEmpty: hasLoaded && favorites.isEmpty,
            contentHeight: 140,
            destination: {
                AssetCollectionView(
                    title: "Favorites",
                    request: SearchRequestDTO(isFavorite: true, size: 200),
                    isFavoritesCollection: true)
            }
        ) {
            ForEach(favorites) { asset in
                NavigationLink {
                    AssetDetailView(currentAsset: asset, assets: favorites)
                        .navigationTransition(
                            .zoom(sourceID: asset.id, in: assetNamespace))
                        .toolbarVisibility(.hidden, for: .tabBar)
                } label: {
                    AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .matchedTransitionSource(id: asset.id, in: assetNamespace)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    assetMenu(for: asset)
                } preview: {
                    AssetContextPreview(asset: asset, session: session)
                }
            }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        let people = vm?.people ?? []
        CollectionSection(
            title: "People",
            isExpanded: expansion(for: .people, hasContent: !people.isEmpty),
            isEmpty: hasLoaded && people.isEmpty,
            contentHeight: 136,
            destination: { PeopleView() }
        ) {
            ForEach(people) { person in
                NavigationLink {
                    personDetail(for: person)
                } label: {
                    PersonCard(person: person)
                        .matchedTransitionSource(id: person.id, in: personNamespace)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func personDetail(for person: PersonDTO) -> some View {
        PersonDetailView(
            person: person,
            repo: PeopleRepository(api: APIClient(session: session)))
            .navigationTransition(.zoom(sourceID: person.id, in: personNamespace))
    }

    private func binding(for row: Row) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(row) },
            set: { isOn in
                if isOn { expanded.insert(row) } else { expanded.remove(row) }
                persistExpanded()
            })
    }

    /// Baris hanya benar-benar terbuka setelah ada yang bisa diperlihatkan.
    ///
    /// Pilihan pengguna tetap dihormati dan tetap disimpan — yang ditunda cuma
    /// PEMBUKAANNYA. Baris yang terbuka sejak awal padahal isinya belum datang
    /// hanyalah lubang kosong setinggi dua ratus titik di tengah Library, dan
    /// lubang itu bertahan selama permintaannya berjalan.
    ///
    /// Begitu isinya datang, nilainya berubah dan barisnya terbuka dengan
    /// animasi lipat yang sama seperti kalau ditekan sendiri — lihat `.animation`
    /// di `rows`.
    ///
    /// `hasLoaded` ikut dihitung supaya baris yang memang KOSONG tetap bisa
    /// terbuka dan mengatakannya, bukan diam tertutup tanpa penjelasan.
    private func expansion(for row: Row, hasContent: Bool) -> Binding<Bool> {
        let preference = binding(for: row)
        return Binding(
            get: { preference.wrappedValue && (hasContent || hasLoaded) },
            set: { preference.wrappedValue = $0 })
    }

    /// Urutannya dinormalkan mengikuti `Row.allCases` supaya nilai tersimpannya
    /// stabil — `Set` tidak menjamin urutan, dan tanpa ini isinya berubah-ubah
    /// tiap kali ditulis meski pilihannya sama.
    private func persistExpanded() {
        // `.memories` sengaja tidak ikut disimpan — lihat catatan di `init`.
        let ordered = Row.allCases
            .filter { $0 != .memories && expanded.contains($0) }
            .map(\.rawValue)
        UserDefaults.standard.set(ordered.joined(separator: ","), forKey: Self.expandedKey)
    }

    // MARK: - Baris tetap

    private var fixedRows: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 20)

            plainRow("On This Device", systemImage: "iphone") {
                DeviceAlbumsListView()
            }
            plainRow("Places", systemImage: "map") {
                PhotoMapView()
            }
            plainRow("Shared Links", systemImage: "link") {
                SharedLinksView()
            }
            plainRow("Duplicates", systemImage: "square.on.square") {
                DuplicatesView()
            }
            plainRow("Archived", systemImage: "archivebox") {
                AssetCollectionView(
                    title: "Archived",
                    request: SearchRequestDTO(size: 200, visibility: "archive"),
                    layout: .monthly)
            }
            plainRow("Trash", systemImage: "trash") {
                TrashView()
            }
            plainRow("Locked Folder", systemImage: "lock") {
                LockedFolderView()
            }
        }
    }

    private func plainRow<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                destination()
            } label: {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 20)
        }
    }
}

/// Album dari widget bisa bukan salah satu kartu ringkas yang sedang dimuat di
/// Library. Ambil DTO-nya langsung berdasarkan id agar deep link selalu menuju
/// album yang dipilih, bukan jatuh kembali ke daftar semua album.
private struct RoutedAlbumView: View {
    let albumID: String
    let cachedAlbum: AlbumResponseDTO?
    let onContentsChanged: ([AssetLite]) -> Void
    let onAlbumChanged: (AlbumResponseDTO) -> Void

    @Environment(SessionManager.self) private var session
    @State private var album: AlbumResponseDTO?
    @State private var didFail = false

    var body: some View {
        Group {
            if let album = album ?? cachedAlbum {
                AlbumDetailView(
                    album: album,
                    onContentsChanged: onContentsChanged,
                    onAlbumChanged: onAlbumChanged)
            } else if didFail {
                ContentUnavailableView(
                    "Album Unavailable",
                    systemImage: "rectangle.stack.badge.exclamationmark",
                    description: Text("This album could not be loaded."))
            } else {
                ProgressView("Loading Album…")
            }
        }
        .task(id: albumID) {
            guard cachedAlbum == nil else { return }
            do {
                album = try await AlbumRepository(
                    api: APIClient(session: session)).detail(albumID)
            } catch {
                didFail = true
            }
        }
    }
}

#Preview {
    LibraryView()
        .environment(SessionManager())
}
