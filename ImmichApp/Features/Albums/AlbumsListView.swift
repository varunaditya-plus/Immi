import SwiftUI

struct AlbumsListView: View {
    /// Pemilik layar (Library, misalnya) dapat ikut menambal snapshot albumnya.
    var onAlbumUpdated: ((AlbumResponseDTO) -> Void)?
    var onAlbumCreated: ((AlbumResponseDTO) -> Void)?
    var onAlbumContentsChanged: ((String, [AssetLite]) -> Void)?
    var onAlbumDeleted: ((String) -> Void)?
    var onAlbumShared: ((String) -> Void)?
    var onAlbumCoverChanged: ((String, String) -> Void)?
    private let folderID: String?

    @Environment(SessionManager.self) private var session
    @State private var vm: AlbumListViewModel?
    @State private var scope: Scope = .personal
    @State private var searchText = ""
    @State private var isSearching = false
    @Namespace private var albumNamespace
    @State private var editTarget: AlbumResponseDTO?
    @State private var addUserTarget: AlbumResponseDTO?
    @State private var deleteTarget: AlbumResponseDTO?
    @State private var sharedLink: SharedLinkPresentation?
    @State private var organization: AlbumsOrganizationStore?
    @State private var activity: AlbumActivityViewModel?
    @State private var kind: ContentKind = .all
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renameFolderTarget: AlbumFolder?
    @State private var deleteFolderTarget: AlbumFolder?
    @State private var moveAlbumTarget: AlbumResponseDTO?
    @State private var showReorder = false
    @AppStorage("albumsCustomOrder") private var usesCustomOrder = true

    enum ContentKind: String { case all, albums, folders }
    /// Tata letak & urutan disimpan supaya pilihannya bertahan antar sesi.
    @AppStorage("albumsLayout") private var layout: AlbumLayout = .grid
    @AppStorage("albumsSort") private var sort: AlbumSort = .lastModified

    enum Scope: String, CaseIterable, Identifiable {
        case all, shared, personal, activity
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .shared: "Shared"
            case .personal: "Personal"
            case .activity: "Activity"
            }
        }
    }

    /// Sengaja BUKAN `Layout` — nama itu milik protokol `Layout` di SwiftUI, dan
    /// tipe bersarang akan menaunginya di dalam struct ini.
    enum AlbumLayout: String {
        case grid, list
    }

    /// Sidebar iPad dan layar All Albums berbagi instance yang sama agar hasil
    /// membuat/menghapus album langsung terlihat di kedua tempat.
    init(
        viewModel: AlbumListViewModel? = nil,
        initialScope: Scope? = nil,
        onAlbumUpdated: ((AlbumResponseDTO) -> Void)? = nil,
        onAlbumCreated: ((AlbumResponseDTO) -> Void)? = nil,
        onAlbumContentsChanged: ((String, [AssetLite]) -> Void)? = nil,
        onAlbumDeleted: ((String) -> Void)? = nil,
        onAlbumShared: ((String) -> Void)? = nil,
        onAlbumCoverChanged: ((String, String) -> Void)? = nil,
        organizationStore: AlbumsOrganizationStore? = nil,
        folderID: String? = nil
    ) {
        _vm = State(initialValue: viewModel)
        self.onAlbumUpdated = onAlbumUpdated
        self.onAlbumCreated = onAlbumCreated
        self.onAlbumContentsChanged = onAlbumContentsChanged
        self.onAlbumDeleted = onAlbumDeleted
        self.onAlbumShared = onAlbumShared
        self.onAlbumCoverChanged = onAlbumCoverChanged
        self.folderID = folderID
        _scope = State(initialValue: initialScope ?? (folderID == nil ? .personal : .all))
        _organization = State(initialValue: organizationStore)
    }

    var body: some View {
        content
            // Isi SELALU mengisi ruangnya, sebesar apa pun isinya.
            //
            // Bar tepi menempel pada frame view yang dimodifikasinya, bukan pada
            // layar. Selagi memuat, isinya cuma `ProgressView` seukuran ikonnya
            // — jadi segmented ikut menyusut ke tengah bersamanya, lalu melompat
            // ke atas begitu daftar album datang dan isinya membesar.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(folderTitle)
            .navigationBarTitleDisplayMode(.inline)
            // `safeAreaBar`, BUKAN `safeAreaInset`.
            //
            // Keduanya sama-sama menyisihkan ruang, tapi hanya `safeAreaBar`
            // yang memberi tahu scroll view bahwa yang menempel di situ adalah
            // BAR. Itulah yang menyalakan blur bertingkat Liquid Glass di
            // baliknya; `safeAreaInset` cuma ruang kosong, sehingga isi yang
            // lewat di bawahnya terlihat menembus segmented apa adanya.
            .safeAreaBar(edge: .top, spacing: 0) { scopePicker }
            .modifier(AlbumsSearchPresentation(text: $searchText, isPresented: $isSearching))
            .onChange(of: isSearching) { _, searching in
                if !searching { searchText = "" }
            }
            .onChange(of: vm?.hasLoadedAlbums) { _, _ in reconcileOrganization() }
            .onChange(of: vm?.albums.map(\.id)) { _, _ in reconcileOrganization() }
            .toolbar { toolbar }
            .sheet(isPresented: $showReorder) {
                AlbumBrowserReorderSheet(items: unfilteredItems) { ids in
                    organization?.setContainerOrder(ids, in: folderID)
                    usesCustomOrder = true
                }
            }
            .sheet(item: $moveAlbumTarget) { album in
                AlbumMoveToFolderSheet(
                    folders: organization?.value.folders ?? [],
                    currentFolderID: organization?.value.albumFolders[album.id]) { destination in
                        organization?.moveAlbum(album.id, to: destination)
                    }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder Name", text: $folderName)
                Button("Create") {
                    organization?.createFolder(name: folderName, parentID: folderID)
                    kind = .all
                    folderName = ""
                }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { folderName = "" }
            } message: { Text("Folders are saved on this device.") }
            .alert("Rename Folder", isPresented: Binding(
                get: { renameFolderTarget != nil }, set: { if !$0 { renameFolderTarget = nil } })) {
                TextField("Folder Name", text: $folderName)
                Button("Save") {
                    if let target = renameFolderTarget { organization?.renameFolder(target.id, to: folderName) }
                    renameFolderTarget = nil
                }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renameFolderTarget = nil }
            }
            .confirmationDialog("Delete Folder?", isPresented: Binding(
                get: { deleteFolderTarget != nil }, set: { if !$0 { deleteFolderTarget = nil } }),
                titleVisibility: .visible) {
                    Button("Delete Folder", role: .destructive) {
                        if let target = deleteFolderTarget { organization?.removeFolder(target.id) }
                        deleteFolderTarget = nil
                    }
                    Button("Cancel", role: .cancel) { deleteFolderTarget = nil }
                } message: { Text("The albums and photos will be kept.") }
            .sheet(isPresented: createSheetBinding) {
                NewAlbumSheet { name, description, assetIds in
                    guard let vm else {
                        return String(localized: "Failed to create album")
                    }
                    return await createAlbum(
                        name: name, description: description, assetIds: assetIds, using: vm)
                }
            }
            .sheet(item: $editTarget) { album in
                AlbumEditSheet(album: album) { updated in
                    vm?.applyAlbumUpdate(updated)
                    onAlbumUpdated?(updated)
                }
            }
            .sheet(item: $addUserTarget) { album in
                AlbumAddUserSheet { userIDs in
                    if let vm { await addUsers(userIDs, to: album.id, using: vm) }
                    defer { vm?.actionError = nil }
                    return vm?.actionError
                }
            }
            .sheet(item: $sharedLink) { link in
                ShareSheet(url: link.url)
            }
            .alert("Action Failed", isPresented: Binding(
                get: { vm?.actionError != nil },
                set: { if !$0 { vm?.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm?.actionError ?? "")
            }
            .task { await start() }
    }

    private func start() async {
        if organization == nil { organization = AlbumsOrganizationStore(owner: session.accountOwner) }
        if activity == nil { activity = AlbumActivityViewModel(repository: AlbumActivityRepository(api: APIClient(session: session))) }
        if vm == nil {
            let api = APIClient(session: session)
            vm = AlbumListViewModel(repo: AlbumRepository(api: api))
        }
        await vm?.loadAlbums()
    }

    // MARK: - Segmented

    @ViewBuilder
    private var scopePicker: some View {
        if folderID == nil {
        Picker("Scope", selection: $scope) {
            ForEach([Scope.personal, .shared, .activity]) { scope in
                Text(scope.title).tag(scope)
            }
        }
        // `.segmented` menjembatani ke `UISegmentedControl`. Di iOS 26 yang
        // jadi kaca hanya INDIKATOR pilihannya; track-nya tetap fill solid.
        // Liquid Glass diberikan ke chrome yang dihosting bar — dan itulah
        // sebabnya picker ini dipasang lewat `safeAreaBar`, bukan diberi latar
        // sendiri.
        .pickerStyle(.segmented)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { vm?.showCreateSheet = true } label: {
                    Label("New Album", systemImage: "rectangle.stack.badge.plus")
                }
                Button { folderName = ""; showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("Create")
            .disabled(vm == nil)
            optionsMenu
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button { isSearching = true } label: { Label("Search", systemImage: "magnifyingglass") }
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(AlbumLayout.grid)
                Label("List", systemImage: "list.bullet").tag(AlbumLayout.list)
            }.pickerStyle(.inline)

            Menu {
                Picker("Sort By", selection: Binding<AlbumSort?>(
                    get: { usesCustomOrder ? nil : sort },
                    set: { value in
                        usesCustomOrder = value == nil
                        if let value { sort = value }
                    })) {
                        Text("Custom Order").tag(AlbumSort?.none)
                        ForEach(AlbumSort.allCases) { order in
                            Text(order.label).tag(Optional(order))
                        }
                    }
                Button("Reorder Albums") { showReorder = true }.disabled(unfilteredItems.isEmpty)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }

            Menu {
                Picker("Filter", selection: $kind) {
                    Text("All Items").tag(ContentKind.all)
                    Text("Albums").tag(ContentKind.albums)
                    Text("Folders").tag(ContentKind.folders)
                }
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("More")
        .disabled(scope == .activity)
    }

    private var createSheetBinding: Binding<Bool> {
        Binding(
            get: { vm?.showCreateSheet ?? false },
            set: { vm?.showCreateSheet = $0 })
    }

    // MARK: - Isi

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.phase {
            case .idle, .loading:
            // Spinner HANYA kalau memang belum ada apa-apa.
            //
            // Potret lokal dibaca di `task`, yaitu setelah render pertama, jadi
            // tanpa gerbang ini layar berkedip spinner satu frame sebelum isi
            // yang sebenarnya sudah tersedia tergambar.
                if vm.albums.isEmpty {
                    ProgressView()
                } else {
                    loadedContent(vm)
                }

            case .loaded:
                loadedContent(vm)

            case .failed(let error):
                errorState(error, vm)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func loadedContent(_ vm: AlbumListViewModel) -> some View {
        let albums = visibleAlbums(vm)

        if scope == .activity {
            activityContent(vm)
        } else if albums.isEmpty && visibleFolders.isEmpty {
            if normalizedSearchText.isEmpty {
                emptyState(vm, scope: scope)
            } else {
                ContentUnavailableView.search(text: normalizedSearchText)
            }
        } else {
            albumsContainer(albums, vm)
        }
    }

    @ViewBuilder
    private func albumsContainer(
        _ albums: [AlbumResponseDTO],
        _ vm: AlbumListViewModel
    ) -> some View {
        Group {
            switch layout {
            case .grid: albumsGrid(albums, vm)
            case .list: albumsList(albums, vm)
            }
        }
        // `.hard`, bukan `.soft`.
        //
        // `.soft` adalah gradien lembut untuk isi yang memang harus terlihat
        // menembus penuh sampai ke tepi — foto layar penuh, misalnya. Di bawah
        // sebuah bar hasilnya justru yang dikeluhkan: isinya terlihat menembus
        // segmented. `.hard` memberi bidang buram bertepi tegas seukuran
        // bar-nya, sama seperti nav bar dan tab bar bawaan.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .refreshable { await vm.loadAlbums() }
    }

    /// Tautan memakai TUJUAN LANGSUNG, bukan `NavigationLink(value:)` +
    /// `navigationDestination(for:)`.
    ///
    /// Layar ini sendiri sudah didorong ke dalam stack milik Collections.
    /// Mendaftarkan tujuan berbasis nilai dari posisi itu membuat SwiftUI
    /// mendorong dua entri sekaligus — halaman yang sama muncul di atas, dan
    /// detailnya baru terlihat setelah ditekan back. Jalur dari Collections
    /// tidak pernah bermasalah justru karena memakai tujuan langsung.
    private func albumsGrid(_ albums: [AlbumResponseDTO], _ model: AlbumListViewModel) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns(for: proxy.size.width), spacing: 12) {
                    ForEach(browserItems(albums: albums, folders: visibleFolders)) { item in
                        browserGridItem(item, model: model)
                            .draggable(item.id)
                            .dropDestination(for: String.self) { ids, _ in
                                reorder(ids.first, before: item.id)
                            }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func browserGridItem(_ item: AlbumBrowserItem, model: AlbumListViewModel) -> some View {
        switch item {
        case .album(let album):
            NavigationLink {
                albumDestination(for: album, using: model)
                    .navigationTransition(.zoom(sourceID: album.id, in: albumNamespace))
            } label: {
                AlbumGridCard(album: album).matchedTransitionSource(id: album.id, in: albumNamespace)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(for: album) } preview: { AlbumCoverPreview(album: album, session: session) }
            .confirmationDialog("Delete “\(album.albumName)”?", isPresented: deleteBinding(for: album), titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) {
                    deleteTarget = nil
                    Task { await deleteAlbum(album.id, using: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The photos will stay in your library.") }
        case .folder(let folder):
            NavigationLink {
                folderDestination(folder, using: model)
            } label: {
                AlbumFolderCard(folder: folder, albums: organization?.value.orderedAlbums(model.albums, in: folder.id) ?? [])
            }
            .buttonStyle(.plain)
            .contextMenu { folderMenu(folder) }
        }
    }

    private static let maximumGridColumns = 4
    private static let minimumGridColumns = 2
    private static let minimumAlbumCardWidth: CGFloat = 150
    private static let gridSpacing: CGFloat = 12
    private static let gridHorizontalPadding: CGFloat = 16

    /// Dua kolom tetap menjadi batas bawah agar iPhone mempertahankan tampilan
    /// yang sekarang. Ruang ekstra menambah kolom satu per satu sampai empat;
    /// perhitungannya memakai lebar container, jadi ikut beradaptasi saat
    /// sidebar atau multitasking mengubah lebar area detail iPad.
    private func gridColumns(for containerWidth: CGFloat) -> [GridItem] {
        let availableWidth = max(0, containerWidth - Self.gridHorizontalPadding * 2)
        let fittingCount = Int(
            (availableWidth + Self.gridSpacing)
                / (Self.minimumAlbumCardWidth + Self.gridSpacing))
        let count = min(
            Self.maximumGridColumns,
            max(Self.minimumGridColumns, fittingCount))

        return Array(
            repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
            count: count)
    }

    private func albumsList(_ albums: [AlbumResponseDTO], _ vm: AlbumListViewModel) -> some View {
        List {
            ForEach(browserItems(albums: albums, folders: visibleFolders)) { item in
                switch item {
                case .album(let album):
                    NavigationLink { albumDestination(for: album, using: vm) } label: { AlbumRowView(album: album) }
                        .contextMenu { contextMenu(for: album) }
                        .confirmationDialog("Delete “\(album.albumName)”?", isPresented: deleteBinding(for: album), titleVisibility: .visible) {
                            Button("Delete Album", role: .destructive) {
                                deleteTarget = nil
                                Task { await deleteAlbum(album.id, using: vm) }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: { Text("The photos will stay in your library.") }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleteTarget = album }
                        }
                case .folder(let folder):
                    NavigationLink { folderDestination(folder, using: vm) } label: {
                        Label(folder.name, systemImage: "folder")
                            .padding(.vertical, 16)
                    }
                    .contextMenu { folderMenu(folder) }
                }
            }
        }
        .listStyle(.plain)
    }

    private var folderTitle: String {
        organization?.value.folders.first(where: { $0.id == folderID })?.name ?? String(localized: "Albums")
    }

    private func reconcileOrganization() {
        guard let vm, vm.hasLoadedAlbums else { return }
        organization?.reconcileAlbums(Set(vm.albums.map(\.id)))
    }

    private var visibleFolders: [AlbumFolder] {
        guard scope != .activity, scope != .shared, kind != .albums else { return [] }
        return (organization?.value.childFolders(of: folderID) ?? []).filter {
            normalizedSearchText.isEmpty || $0.name.localizedStandardContains(normalizedSearchText)
        }
    }

    private var unfilteredItems: [AlbumBrowserItem] {
        guard let vm else { return [] }
        let albums = organization?.value.albums(vm.albums, in: folderID) ?? vm.albums
        return browserItems(albums: albums, folders: organization?.value.childFolders(of: folderID) ?? [])
    }

    private func browserItems(albums: [AlbumResponseDTO], folders: [AlbumFolder]) -> [AlbumBrowserItem] {
        let items = folders.map(AlbumBrowserItem.folder) + albums.map(AlbumBrowserItem.album)
        guard usesCustomOrder else { return items }
        let order = organization?.value.containerOrders[AlbumOrganization.container(folderID)] ?? []
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil { positions[id] = index }
        let fallback = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return items.sorted {
            let a = positions[$0.id] ?? Int.max
            let b = positions[$1.id] ?? Int.max
            return a == b ? fallback[$0.id, default: 0] < fallback[$1.id, default: 0] : a < b
        }
    }

    private func reorder(_ source: String?, before destination: String) {
        var ids = unfilteredItems.map(\.id)
        guard let source, source != destination, let original = ids.firstIndex(of: source),
              ids.contains(destination) else { return }
        _ = ids.remove(at: original)
        guard let target = ids.firstIndex(of: destination) else { return }
        ids.insert(source, at: target)
        organization?.setContainerOrder(ids, in: folderID)
        usesCustomOrder = true
    }

    private func folderDestination(_ folder: AlbumFolder, using model: AlbumListViewModel) -> some View {
        AlbumsListView(viewModel: model,
            onAlbumUpdated: onAlbumUpdated, onAlbumCreated: onAlbumCreated,
            onAlbumContentsChanged: onAlbumContentsChanged, onAlbumDeleted: onAlbumDeleted,
            onAlbumShared: onAlbumShared, onAlbumCoverChanged: onAlbumCoverChanged,
            organizationStore: organization, folderID: folder.id)
    }

    private func folderMenu(_ folder: AlbumFolder) -> some View {
        Group {
            Button { folderName = folder.name; renameFolderTarget = folder } label: {
                Label("Rename Folder", systemImage: "pencil")
            }
            Button(role: .destructive) { deleteFolderTarget = folder } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func activityContent(_ albums: AlbumListViewModel) -> some View {
        if let activity {
            let items = activity.items(in: albums.albums)
            Group {
                if activity.phase.isLoading && items.isEmpty {
                    ProgressView()
                } else if let error = activity.phase.errorMessage {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Retry") { Task { await activity.load(albums: albums.albums) } }
                    }
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("No Activity", systemImage: "bubble.left.and.bubble.right")
                    } description: { Text("Comments and likes in shared albums will appear here.") }
                } else {
                    List {
                        if let error = activity.partialError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(items) { item in
                            NavigationLink { albumDestination(for: item.album, using: albums) } label: {
                                AlbumActivityRow(item: item)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await activity.load(albums: albums.albums) }
                }
            }
            .task(id: albums.albums.filter(\.shared).map(\.id)) { await activity.load(albums: albums.albums) }
        } else { ProgressView() }
    }

    // MARK: - Context menu

    func albumDestination(for album: AlbumResponseDTO, using model: AlbumListViewModel) -> AlbumDetailView {
        AlbumDetailView(
            album: album,
            onContentsChanged: { assets in
                model.applyContents(assets, to: album.id)
                onAlbumContentsChanged?(album.id, assets)
            },
            onAlbumChanged: {
                model.applyAlbumUpdate($0)
                onAlbumUpdated?($0)
            },
            onDeleted: {
                organization?.removeAlbum(album.id)
                model.removeDeletedAlbum(album.id)
                onAlbumDeleted?(album.id)
            },
            onShared: {
                model.applyAlbumSharing(album.id)
                onAlbumShared?(album.id)
            },
            onCoverChanged: { albumID, assetID in
                model.applyAlbumCover(albumID, assetID: assetID)
                onAlbumCoverChanged?(albumID, assetID)
            },
            organizationStore: organization)
    }

    func createAlbum(
        name: String, description: String, assetIds: [String], using model: AlbumListViewModel
    ) async -> String? {
        await model.createAlbum(name: name, description: description, assetIds: assetIds) { album in
            scope = folderID == nil ? .personal : .all
            kind = .all
            searchText = ""
            if folderID != nil { organization?.moveAlbum(album.id, to: folderID) }
            onAlbumCreated?(album)
        }
    }

    func addUsers(_ ids: [String], to albumID: String, using model: AlbumListViewModel) async {
        await model.addUsers(ids, to: albumID, onShared: onAlbumShared)
    }

    func deleteAlbum(_ id: String, using model: AlbumListViewModel) async {
        if await model.deleteAlbum(id) {
            organization?.removeAlbum(id)
            onAlbumDeleted?(id)
        }
    }

    private func contextMenu(for album: AlbumResponseDTO) -> some View {
        Group {
            Button { moveAlbumTarget = album } label: { Label("Move to Folder", systemImage: "folder") }
            AlbumActionsMenu(
            onEdit: { editTarget = album },
            onAddUser: { addUserTarget = album },
            onCreateLink: { createLink(for: album) },
            onDelete: { deleteTarget = album })
        }
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

    private func createLink(for album: AlbumResponseDTO) {
        Task {
            do {
                sharedLink = try await SharedLinkPresentation.create(
                    albumId: album.id, session: session)
            } catch {
                vm?.actionError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to create shared link")
            }
        }
    }

    // MARK: - Filter & urutan

    private func visibleAlbums(_ vm: AlbumListViewModel) -> [AlbumResponseDTO] {
        var filtered: [AlbumResponseDTO]
        switch scope {
        case .all: filtered = vm.albums
        case .shared: filtered = vm.albums.filter(\.shared)
        case .personal: filtered = vm.albums.filter { !$0.shared }
        case .activity: filtered = []
        }
        if kind == .folders { return [] }
        filtered = organization?.value.albums(filtered, in: folderID) ?? filtered

        let query = normalizedSearchText
        if !query.isEmpty {
            filtered = filtered.filter { album in
                album.albumName.localizedStandardContains(query)
                    || album.description?.localizedStandardContains(query) == true
            }
        }

        if usesCustomOrder { return organization?.orderedAlbums(filtered, in: folderID) ?? filtered }
        return filtered.sorted(by: sort)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    // MARK: - Keadaan kosong & gagal

    @ViewBuilder
    func emptyState(_ vm: AlbumListViewModel, scope: Scope) -> some View {
        if kind == .folders {
            ContentUnavailableView {
                Label("No Folders", systemImage: "folder")
            } description: {
                Text("Folders are saved on this device.")
            } actions: {
                Button("New Folder") { folderName = ""; showNewFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if scope == .shared {
            ContentUnavailableView {
                Label("No Shared Albums", systemImage: "person.2")
            } description: {
                Text("Albums you share or that others share with you will appear here.")
            } actions: {
                Button("View Personal Albums") { self.scope = .personal }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No Albums", systemImage: "rectangle.stack")
            } description: {
                Text("Create an album to organize your photos.")
            } actions: {
                Button("Create Album") { vm.showCreateSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorState(_ error: String, _ vm: AlbumListViewModel) -> some View {
        ContentUnavailableView {
            Label("Failed to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") { Task { await vm.retry() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Kartu album untuk tata letak grid — sampul penuh dengan nama menumpang di
/// atasnya, mengikuti gaya Albums di Photos.
struct AlbumGridCard: View {
    let album: AlbumResponseDTO

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cover
            caption
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.albumName)
        .accessibilityValue("^[\(album.assetCount) item](inflect: true)")
    }

    /// `Color.clear.overlay` supaya ukuran petaknya ditentukan `aspectRatio` di
    /// luar, bukan oleh gambar di dalamnya.
    private var cover: some View {
        Color.clear.overlay {
            AlbumCoverImage(album: album, placeholderFont: .title)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.albumName)
                .font(.body)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                stops: [.init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.72), location: 0.25),
                        .init(color: .black.opacity(0.85), location: 1)],
                startPoint: .top, endPoint: .bottom)
                .padding(.top, -28)
        }
    }
}

private struct AlbumsSearchPresentation: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPresented {
            content.searchable(text: $text, isPresented: $isPresented,
                placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Albums")
        } else {
            content
        }
    }
}

/// Ukuran sampul dan sela di baris album.
///
/// Konstanta, bukan angka yang ditulis ulang di dua tempat: penjajaran garis
/// pemisah dihitung dari keduanya, dan menyalinnya hanya menunggu keduanya
/// menyimpang.
let albumRowThumbnailSide: CGFloat = 60
let albumRowSpacing: CGFloat = 12

struct AlbumRowView: View {
    let album: AlbumResponseDTO

    var body: some View {
        HStack(spacing: albumRowSpacing) {
            AlbumCoverImage(album: album)
                .frame(width: albumRowThumbnailSide, height: albumRowThumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.albumName)
                    .font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption)
                    Text("\(album.assetCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if album.shared {
                        Spacer()
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    AlbumsListView()
        .environment(SessionManager())
}
