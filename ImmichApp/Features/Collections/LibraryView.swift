import SwiftUI

/// Daftar koleksi ala Photos: sebagian baris bisa dilipat dan memperlihatkan
/// isinya sebagai deret mendatar, sebagian lagi baris biasa yang langsung
/// mendorong ke layarnya.
struct LibraryView: View {
    /// TabView dapat membangun Library walau Photos masih aktif; hanya tab yang
    /// terlihat yang boleh menjadi jangkar coach mark profil.
    var isActive = true
    private let localLibrary: LocalPhotoLibrary

    @Environment(SessionManager.self) private var session
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var vm: LibraryViewModel?
    @State private var preferences = CollectionsPreferences()
    @State private var preferencesStore: CollectionsPreferencesStore?
    @State private var modelGeneration: UUID?
    @State private var showReorder = false
    @State private var showPinnedEditor = false
    @State private var contentWidth: CGFloat = 390
    @State private var showSettings = false
    @State private var showBackup = false
    @State private var backupNotifier = BackupNotifier.shared
    @State private var editTarget: AlbumResponseDTO?
    @State private var addUserTarget: AlbumResponseDTO?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var albumPickerAsset: AssetLite?
    @State private var assetToDelete: AssetLite?
    @State private var shareFileURL: SharedLinkPresentation?
    @State private var sharePreparation = SharePreparation()
    @State private var deleteFeedback = 0
    @State private var backupSetupJourney = BackupSetupJourney.shared
    @State private var navigation = AppNavigation.shared
    @State private var navigationPath: [ExternalRoute] = []
    @State private var isRootVisible = false
    /// Kenangan yang sedang dibuka sebagai story; nil berarti tertutup.
    @State private var openedStoryID: String?
    @Namespace private var personNamespace

    private enum ExternalRoute: Hashable {
        case favorites
        case memories
        case album(String)
    }

    init(isActive: Bool = true, viewModel: LibraryViewModel? = nil, localLibrary: LocalPhotoLibrary? = nil) {
        self.isActive = isActive
        self.localLibrary = localLibrary ?? .shared
        _vm = State(initialValue: viewModel)
        _modelGeneration = State(initialValue: viewModel == nil ? nil : LocalSnapshot.generation)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            assetActionPresentations
                .onAppear { isRootVisible = true }
                .onDisappear {
                    isRootVisible = false
                    sharePreparation.cancel()
                }
                // Nav bar TETAP dipakai — blur tepi progresifnya digambar oleh
                // bar itu; menyembunyikannya berarti kehilangan blurnya. Yang
                // dimatikan hanya latar solidnya.
                //
                // Judulnya toolbar item biasa, bukan `navigationTitle`, karena
                // item toolbar tidak menyusut atau pindah ke tengah saat
                // di-scroll — sama seperti di Photos.
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { libraryToolbar }
                .sheet(isPresented: $showSettings) { settingsSheet }
                .sheet(isPresented: $showReorder) {
                    CollectionsReorderView(preferences: $preferences)
                }
                .sheet(isPresented: $showPinnedEditor) {
                    PinnedCollectionsEditor(preferences: $preferences, albums: vm?.albums ?? [])
                }
                .onChange(of: preferences) { _, value in preferencesStore?.save(value) }
                .onChange(of: vm?.hasLoadedAlbums) { _, _ in reconcilePinnedAlbums() }
                .onChange(of: vm?.albums.map(\.id)) { _, _ in reconcilePinnedAlbums() }
                .onChange(of: showSettings) { _, isPresented in
                    if isPresented {
                        backupSetupJourney.advanceToBackupRow()
                    } else {
                        backupSetupJourney.beginReturningToProfile(
                            request: backupSetupJourney.presentationRequest)
                    }
                }
                .task(id: returnToProfileTaskID) {
                    await returnToProfileAfterDismissal()
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
                .onChange(of: localLibrary.photos) { _, _ in vm?.refreshRecentDays() }
                .onChange(of: SwiftDataManager.shared.assetMutationRevision) { _, _ in
                    Task {
                        vm?.refreshRecentDays()
                        await vm?.refreshFavorites()
                    }
                }
                .task(id: session.accountGeneration) {
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
            routedAlbumDestination(id: id, using: vm)
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
                AlbumAddUserSheet { userIDs in
                    await vm?.addUsers(userIDs, to: album.id)
                    defer { vm?.actionError = nil }
                    return vm?.actionError
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

    private var rows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(preferences.sectionOrder) { section in
                    collectionSection(section)
                }
            }
            .padding(.vertical, 14)
        }
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .refreshable { await vm?.load() }
    }

    @ViewBuilder
    private func collectionSection(_ section: CollectionsSection) -> some View {
        switch section {
        case .pinned: pinnedSection
        case .memories: memoriesSection
        case .albums: albumsSection
        case .people: peopleSection
        case .featured: featuredSection
        case .sharedAlbums: sharedAlbumsSection
        case .recentDays: recentDaysSection
        case .mediaTypes: mediaTypesSection
        case .utilities: utilitiesSection
        }
    }

    // MARK: - Aksi album

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
            vm?.actionError = nil
            do {
                sharedLink = try await SharedLinkPresentation.create(
                    albumId: album.id, session: session)
            } catch {
                vm?.actionError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link")
            }
        }
    }

    // MARK: - Aksi foto

    @ViewBuilder
    private func assetMenu(for asset: AssetLite) -> some View {
        if AssetServerIdentity.resolve(asset, using: SwiftDataManager.shared) != nil {
            AssetActionsMenu(
                asset: asset,
                onShare: { shareAsset(asset) },
                onToggleFavorite: { Task { await vm?.toggleFavorite(asset) } },
                onArchive: { Task { await vm?.archive(asset) } },
                onAddToAlbum: { albumPickerAsset = asset },
                onDelete: { assetToDelete = asset })
        } else {
            Button("Share", systemImage: "square.and.arrow.up") { shareAsset(asset) }
            Button("Delete", systemImage: "trash", role: .destructive) { assetToDelete = asset }
        }
    }

    private func shareAsset(_ asset: AssetLite) {
        guard shareFileURL == nil else { return }
        sharePreparation.start(ids: [asset.id], prepare: { _ in
            if let url = await vm?.shareURL(for: asset) { return [url] }
            return []
        }, isAllowed: { AssetVisibilityPolicy(scope: .timeline).allows(id: $0) },
            onError: { if vm?.actionError == nil { vm?.actionError = $0 } }) { urls in
            shareFileURL = urls.first.map { SharedLinkPresentation(url: $0) }
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
        let owner = session.accountOwner ?? session.backupQueueOwner
        if preferencesStore?.owner != owner || preferencesStore == nil || modelGeneration != session.accountGeneration {
            let store = CollectionsPreferencesStore(owner: owner)
            preferencesStore = store
            preferences = store.load()
        }
        if modelGeneration != session.accountGeneration {
            vm = nil
            modelGeneration = session.accountGeneration
        }
        if vm == nil {
            let api = APIClient(session: session)
            vm = LibraryViewModel(
                memoriesRepo: MemoriesRepository(api: api),
                albumRepo: AlbumRepository(api: api),
                peopleRepo: PeopleRepository(api: api),
                searchRepo: SearchRepository(api: api),
                assetRepo: AssetDetailRepository(api: api),
                localPhotos: { [localLibrary] in localLibrary.photos })
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
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                titleLabel
                collectionsMenu
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
                JourneyProfileButton(
                    isActive: isActive && isRootVisible && navigationPath.isEmpty
                        && !showBackup && !showSettings && openedStoryID == nil
                ) {
                    showSettings = true
                }
                .frame(width: 44, height: 44)
            }
            .frame(width: max(1, contentWidth - 40), height: 44)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var collectionsMenu: some View {
        Menu {
            Picker("Layout", selection: $preferences.layout) {
                ForEach(CollectionsLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Divider()
            Button("Show All", systemImage: "chevron.down") { preferences.showAll() }
            Button("Collapse All", systemImage: "chevron.up") { preferences.collapseAll() }
            Button("Reorder", systemImage: "arrow.up.arrow.down") { showReorder = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Collection View Options")
    }

    private var titleLabel: some View {
        Text("Collections")
            .font(.largeTitle.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSheet: some View {
        SettingsSheetView(session: session)
    }

    private var returnToProfileTaskID: String {
        "\(backupSetupJourney.presentationRequest)-\(isActive)-\(isRootVisible)-\(showSettings)"
    }

    private func returnToProfileAfterDismissal() async {
        guard isActive, isRootVisible, !showSettings,
              backupSetupJourney.step == .returningToProfile else { return }
        let request = backupSetupJourney.presentationRequest
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, !showSettings else { return }
        backupSetupJourney.returnToProfileIfNeeded(request: request)
    }

    // MARK: - Baris yang bisa dilipat

    private var memoriesSection: some View {
        let memories = vm?.memories ?? []
        let width = cardWidth(.memories)
        return CollectionSection(
            title: "Memories",
            isExpanded: expansion(for: .memories),
            isEmpty: hasLoaded && memories.isEmpty,
            contentHeight: width,
            emptyMessage: "No Memories",
            destination: { MemoriesView() }
        ) {
            ForEach(memories) { story in
                MemoryCard(story: story, width: width, height: width) {
                    openedStoryID = story.id
                }
            }
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
                prepareShare: { await vm.shareURL(for: $0, reportsErrors: false) })
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        let albums = Array((vm?.albums ?? []).filter { !$0.shared }.prefix(15))
        CollectionSection(
            title: "Albums",
            isExpanded: expansion(for: .albums),
            isEmpty: hasLoaded && albums.isEmpty,
            contentHeight: cardWidth(.albums),
            emptyMessage: "No Albums",
            destination: {
                allAlbumsDestination(using: vm)
            }
        ) {
            ForEach(albums) { album in
                albumCard(for: album, width: cardWidth(.albums), using: vm)
            }
        }
    }

    private func albumCard(for album: AlbumResponseDTO, width: CGFloat, using model: LibraryViewModel?) -> some View {
        CollectionAlbumCard(
            album: album, width: width,
            onEdit: { editTarget = album },
            onAddUser: { addUserTarget = album },
            onCreateLink: { createLink(for: album) },
            onDelete: { id in Task { await model?.deleteAlbum(id) } },
            destination: { albumDestination(for: album, using: model) })
    }

    func albumDestination(for album: AlbumResponseDTO, using model: LibraryViewModel?) -> AlbumDetailView {
        AlbumDetailView(
            album: album,
            onContentsChanged: { reportAlbumContents($0, id: album.id, using: model) },
            onAlbumChanged: { model?.applyAlbumUpdate($0) },
            onDeleted: { model?.removeDeletedAlbum(album.id) },
            onShared: { model?.applyAlbumSharing(album.id) },
            onCoverChanged: { id, assetID in model?.applyAlbumCover(albumID: id, assetID: assetID) })
    }

    func allAlbumsDestination(using model: LibraryViewModel?, initialScope: AlbumsListView.Scope? = nil) -> AlbumsListView {
        AlbumsListView(
            initialScope: initialScope,
            onAlbumUpdated: { model?.applyAlbumUpdate($0) },
            onAlbumCreated: { model?.applyAlbumCreation($0) },
            onAlbumContentsChanged: { id, assets in
                reportAlbumContents(assets, id: id, using: model)
            },
            onAlbumDeleted: { model?.removeDeletedAlbum($0) },
            onAlbumShared: { model?.applyAlbumSharing($0) },
            onAlbumCoverChanged: { id, assetID in model?.applyAlbumCover(albumID: id, assetID: assetID) })
    }

    func routedAlbumDestination(id: String, using model: LibraryViewModel?) -> RoutedAlbumView {
        RoutedAlbumView(
            albumID: id,
            cachedAlbum: model?.albums.first(where: { $0.id == id }),
            destination: { albumDestination(for: $0, using: model) })
    }

    private func reportAlbumContents(_ assets: [AssetLite], id: String, using model: LibraryViewModel?) {
        guard model?.applyAlbumContents(assets, to: id) == true else { return }
        Task { await model?.refreshAlbums(invalidatingCoverFor: id) }
    }

    private var featuredSection: some View {
        let featured = vm?.featuredPhotos ?? []
        let width = cardWidth(.featured)
        return CollectionSection(
            title: "Featured Photos",
            isExpanded: expansion(for: .featured),
            isEmpty: hasLoaded && featured.isEmpty,
            contentHeight: width,
            emptyMessage: "No Featured Photos",
            destination: {
                DerivedCollectionView(title: "Featured Photos", assets: { [model = vm] in model?.featuredPhotos ?? [] },
                    refreshSources: { [model = vm] in model?.refreshRecentDays() })
            }
        ) {
            FeaturedPhotoCards(assets: featured, width: width) { assetMenu(for: $0) }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        let people = vm?.people ?? []
        CollectionSection(
            title: "People",
            isExpanded: expansion(for: .people),
            isEmpty: hasLoaded && people.isEmpty,
            contentHeight: personSide + 26,
            emptyMessage: "No People",
            destination: { peopleDirectory }
        ) {
            ForEach(people) { person in
                NavigationLink {
                    personDetail(for: person)
                } label: {
                    PersonCard(person: person, side: personSide)
                        .matchedTransitionSource(id: person.id, in: personNamespace)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func personDetail(for person: PersonDTO) -> some View {
        PersonDetailView(
            person: person,
            repo: PeopleRepository(api: APIClient(session: session)),
            onPersonUpdated: { vm?.applyPersonUpdate($0) })
            .navigationTransition(.zoom(sourceID: person.id, in: personNamespace))
    }

    private var peopleDirectory: some View {
        PeopleView(onPersonUpdated: { vm?.applyPersonUpdate($0) },
            onPeopleMerged: { removedIDs, _ in vm?.applyPeopleMerge(removedIDs) })
    }

    private func expansion(for section: CollectionsSection) -> Binding<Bool> {
        Binding(
            get: { !preferences.collapsedSections.contains(section) },
            set: { expanded in
                if expanded { preferences.collapsedSections.remove(section) }
                else { preferences.collapsedSections.insert(section) }
            })
    }

    private func cardWidth(_ section: CollectionsSection) -> CGFloat {
        preferences.layout.cardWidth(for: section)
    }

    private var personSide: CGFloat {
        preferences.layout == .large ? 160 : preferences.layout == .small ? 88 : 110
    }

    private func reconcilePinnedAlbums() {
        guard vm?.hasLoadedAlbums == true else { return }
        preferences.removeMissingAlbums(Set(vm?.albums.map(\.id) ?? []))
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                NavigationLink {
                    allPinnedCollections
                } label: {
                    HStack(spacing: 4) {
                        Text("Pinned").font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.5)
                        Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Edit") { showPinnedEditor = true }
                    .font(.subheadline.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("collections.editPinned")
                collapseControl(.pinned)
            }
            if !preferences.collapsedSections.contains(.pinned) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                    ForEach(preferences.pinnedCollections) { reference in
                        NavigationLink {
                            pinnedDestination(reference)
                        } label: {
                            pinnedTile(reference)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Unpin", systemImage: "pin.slash") {
                                preferences.pinnedCollections.removeAll { $0 == reference }
                            }
                        }
                    }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(.horizontal, 20)
    }

    private var allPinnedCollections: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth(.pinned)), spacing: 12)], spacing: 12) {
                ForEach(preferences.pinnedCollections) { reference in
                    NavigationLink { pinnedDestination(reference) } label: { pinnedTile(reference) }
                        .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle("Pinned")
        .toolbar {
            Button("Edit") { showPinnedEditor = true }
        }
    }

    private func collapseControl(_ section: CollectionsSection) -> some View {
        let collapsed = preferences.collapsedSections.contains(section)
        return Button {
            if collapsed { preferences.collapsedSections.remove(section) }
            else { preferences.collapsedSections.insert(section) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.blue)
                .rotationEffect(.degrees(collapsed ? (layoutDirection == .rightToLeft ? 90 : -90) : 0))
                .frame(width: 28, height: 28)
                .background(.fill.tertiary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? Text("Expand \(Text(section.title))") : Text("Collapse \(Text(section.title))"))
        .accessibilityValue(collapsed ? Text("Collapsed") : Text("Expanded"))
    }

    private func pinnedTile(_ reference: PinnedCollectionReference) -> some View {
        let width = cardWidth(.pinned)
        return Color(.tertiarySystemFill)
            .overlay {
                pinnedCover(reference)
            }
            .overlay(alignment: .bottomLeading) {
                Text(reference.title(in: vm?.albums ?? []))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    .lineLimit(2).minimumScaleFactor(0.65)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .topTrailing) {
                if reference == .favorites {
                    Image(systemName: "heart.fill").foregroundStyle(.white).padding(10)
                }
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reference.title(in: vm?.albums ?? []))
    }

    @ViewBuilder
    private func pinnedCover(_ reference: PinnedCollectionReference) -> some View {
        switch reference {
        case .favorites:
            if let asset = vm?.favorites.first { AuthImage(assetId: asset.id, thumbhash: asset.thumbhash) }
            else { pinnedPlaceholder(reference) }
        case .album(let id):
            if let album = vm?.albums.first(where: { $0.id == id }) { AlbumCoverImage(album: album) }
            else { pinnedPlaceholder(reference) }
        case .albums:
            if let album = vm?.albums.first { AlbumCoverImage(album: album) }
            else { pinnedPlaceholder(reference) }
        case .memories:
            if let asset = vm?.memories.first?.cover { AuthImage(assetId: asset.id, thumbhash: asset.thumbhash) }
            else { pinnedPlaceholder(reference) }
        case .people:
            if let person = vm?.people.first { AuthImage(assetId: person.id, path: "/people/\(person.id)/thumbnail") }
            else { pinnedPlaceholder(reference) }
        case .videos:
            if let asset = vm?.recentDays.flatMap(\.assets).first(where: \.isVideo) {
                AuthImage(assetId: asset.id, thumbhash: asset.thumbhash)
            } else { pinnedPlaceholder(reference) }
        case .map:
            CollectionsMapPreview(marker: vm?.mapPreviewMarker)
        case .recentlyDeleted:
            pinnedPlaceholder(reference)
        }
    }

    private func pinnedPlaceholder(_ reference: PinnedCollectionReference) -> some View {
        Image(systemName: reference.systemImage)
            .font(.largeTitle.weight(.medium))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func pinnedDestination(_ reference: PinnedCollectionReference) -> some View {
        switch reference {
        case .favorites:
            AssetCollectionView(title: "Favorites", request: SearchRequestDTO(isFavorite: true, size: 200), isFavoritesCollection: true)
        case .map: PhotoMapView()
        case .videos: AssetCollectionView(title: "Videos", request: SearchRequestDTO(type: "VIDEO", size: 200))
        case .recentlyDeleted: TrashView()
        case .albums: allAlbumsDestination(using: vm)
        case .people: peopleDirectory
        case .memories: MemoriesView()
        case .album(let id): routedAlbumDestination(id: id, using: vm)
        }
    }

    private var sharedAlbumsSection: some View {
        let albums = Array((vm?.albums ?? []).filter(\.shared).prefix(15))
        let width = cardWidth(.sharedAlbums)
        return CollectionSection(
            title: "Shared Albums",
            isExpanded: expansion(for: .sharedAlbums),
            isEmpty: hasLoaded && albums.isEmpty,
            contentHeight: width,
            emptyMessage: "No Shared Albums",
            destination: { allAlbumsDestination(using: vm, initialScope: .shared) }
        ) {
            sharedAlbumCards(using: vm, width: width)
        }
    }

    func sharedAlbumCards(using model: LibraryViewModel?, width: CGFloat) -> some View {
        ForEach(Array((model?.albums ?? []).filter(\.shared).prefix(15))) { album in
            albumCard(for: album, width: width, using: model)
        }
    }

    private var recentDaysSection: some View {
        let days = vm?.recentDays ?? []
        let width = cardWidth(.recentDays)
        return CollectionSection(
            title: "Recent Days",
            isExpanded: expansion(for: .recentDays),
            isEmpty: hasLoaded && days.isEmpty,
            contentHeight: width * 1.1,
            emptyMessage: "No Recent Days",
            destination: {
                RecentDaysListView(days: days, refreshedDays: { [model = vm] in model?.recentDays ?? [] },
                    refreshSources: { [model = vm] in model?.refreshRecentDays() })
            }
        ) {
            ForEach(days) { day in
                NavigationLink {
                    RecentDayDestination(day: day,
                        previewAssets: { [model = vm, day] in model?.assets(in: DateInterval(start: day.start, end: day.end)) ?? [] },
                        refreshSources: { [model = vm] in model?.refreshRecentDays() })
                } label: {
                    RecentDayCard(day: day, width: width, height: width * 1.1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var mediaTypesSection: some View {
        VStack(spacing: 0) {
            sectionToggle(.mediaTypes).padding(.horizontal, 20).padding(.bottom, 12)
            if !preferences.collapsedSections.contains(.mediaTypes) {
                plainRow("Videos", systemImage: "video") {
                    AssetCollectionView(title: "Videos", request: SearchRequestDTO(type: "VIDEO", size: 200))
                }
                plainRow("Photos", systemImage: "photo") {
                    AssetCollectionView(title: "Photos", request: SearchRequestDTO(type: "IMAGE", size: 200))
                }
            }
        }
    }

    private var utilitiesSection: some View {
        VStack(spacing: 0) {
            sectionToggle(.utilities).padding(.horizontal, 20).padding(.bottom, 12)
            if !preferences.collapsedSections.contains(.utilities) {
                plainRow("On This Device", systemImage: "iphone") { DeviceAlbumsListView() }
                plainRow("Map", systemImage: "map") { PhotoMapView() }
                plainRow("Shared Links", systemImage: "link") { SharedLinksView() }
                plainRow("Duplicates", systemImage: "square.on.square") { DuplicatesView() }
                plainRow("Archived", systemImage: "archivebox") {
                    AssetCollectionView(title: "Archived", request: SearchRequestDTO(size: 200, visibility: "archive"), layout: .monthly)
                }
                plainRow("Recently Deleted", systemImage: "trash") { TrashView() }
                plainRow("Locked Folder", systemImage: "lock") { LockedFolderView() }
            }
        }
    }

    private func sectionToggle(_ section: CollectionsSection) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.32)) {
                if preferences.collapsedSections.contains(section) { preferences.collapsedSections.remove(section) }
                else { preferences.collapsedSections.insert(section) }
            }
        } label: {
            HStack {
                Text(section.title).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.blue)
                    .rotationEffect(.degrees(preferences.collapsedSections.contains(section) ? (layoutDirection == .rightToLeft ? 90 : -90) : 0))
                    .frame(width: 28, height: 28)
                    .background(.fill.tertiary, in: .circle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(preferences.collapsedSections.contains(section) ? Text("Collapsed") : Text("Expanded"))
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
                    Image(systemName: "chevron.forward")
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
struct RoutedAlbumView: View {
    let albumID: String
    let cachedAlbum: AlbumResponseDTO?
    let destination: (AlbumResponseDTO) -> AlbumDetailView

    @Environment(SessionManager.self) private var session
    @State private var album: AlbumResponseDTO?
    @State private var didFail = false

    var body: some View {
        Group {
            if let album = album ?? cachedAlbum {
                destination(album)
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
