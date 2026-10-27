import SwiftUI

struct AlbumsListView: View {
    /// Pemilik layar (Library, misalnya) dapat ikut menambal snapshot albumnya.
    var onAlbumUpdated: ((AlbumResponseDTO) -> Void)?

    @Environment(SessionManager.self) private var session
    @State private var vm: AlbumListViewModel?
    @State private var scope: Scope = .all
    @State private var searchText = ""
    @Namespace private var albumNamespace
    @State private var editTarget: AlbumResponseDTO?
    @State private var addUserTarget: AlbumResponseDTO?
    @State private var deleteTarget: AlbumResponseDTO?
    @State private var sharedLink: SharedLinkPresentation?
    /// Tata letak & urutan disimpan supaya pilihannya bertahan antar sesi.
    @AppStorage("albumsLayout") private var layout: AlbumLayout = .grid
    @AppStorage("albumsSort") private var sort: AlbumSort = .lastModified

    enum Scope: String, CaseIterable, Identifiable {
        case all, shared, personal
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .shared: "Shared"
            case .personal: "Personal"
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
        onAlbumUpdated: ((AlbumResponseDTO) -> Void)? = nil
    ) {
        _vm = State(initialValue: viewModel)
        self.onAlbumUpdated = onAlbumUpdated
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
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            // `safeAreaBar`, BUKAN `safeAreaInset`.
            //
            // Keduanya sama-sama menyisihkan ruang, tapi hanya `safeAreaBar`
            // yang memberi tahu scroll view bahwa yang menempel di situ adalah
            // BAR. Itulah yang menyalakan blur bertingkat Liquid Glass di
            // baliknya; `safeAreaInset` cuma ruang kosong, sehingga isi yang
            // lewat di bawahnya terlihat menembus segmented apa adanya.
            .safeAreaBar(edge: .top, spacing: 0) { scopePicker }
            // Search dipasang SETELAH safe-area bar dan selalu terbuka di
            // navigation drawer. Dengan urutan/default otomatis sebelumnya,
            // search mencoba collapse saat scroll pada saat segmented juga
            // menghitung ulang safe area. Dua perubahan top inset itu dapat
            // saling menahan dan membuat kolom search sesekali tidak responsif.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Albums")
            .toolbar { toolbar }
            .sheet(isPresented: createSheetBinding) {
                NewAlbumSheet { name, description, assetIds in
                    guard let vm else {
                        return String(localized: "Failed to create album")
                    }
                    return await vm.createAlbum(
                        name: name, description: description, assetIds: assetIds)
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
                    await vm?.addUsers(userIDs, to: album.id)
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
        if vm == nil {
            let api = APIClient(session: session)
            vm = AlbumListViewModel(repo: AlbumRepository(api: api))
        }
        await vm?.loadAlbums()
    }

    // MARK: - Segmented

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Scope.allCases) { scope in
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                vm?.showCreateSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(vm == nil)
        }

        ToolbarItem(placement: .topBarTrailing) { optionsMenu }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(AlbumLayout.grid)
                Label("List", systemImage: "list.bullet").tag(AlbumLayout.list)
            }
            .pickerStyle(.inline)

            Picker("Sort By", selection: $sort) {
                ForEach(AlbumSort.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis")
        }
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

        if albums.isEmpty {
            if normalizedSearchText.isEmpty {
                emptyState(vm)
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
            case .grid: albumsGrid(albums)
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
    private func albumsGrid(_ albums: [AlbumResponseDTO]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns(for: proxy.size.width), spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(
                                album: album,
                                onAlbumChanged: {
                                    vm?.applyAlbumUpdate($0)
                                    onAlbumUpdated?($0)
                                })
                                .navigationTransition(
                                    .zoom(sourceID: album.id, in: albumNamespace))
                        } label: {
                            AlbumGridCard(album: album)
                                .matchedTransitionSource(id: album.id, in: albumNamespace)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            contextMenu(for: album)
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
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 8)
            }
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

    private func albumsList(
        _ albums: [AlbumResponseDTO],
        _ vm: AlbumListViewModel
    ) -> some View {
        List {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(
                        album: album,
                        onAlbumChanged: {
                            vm.applyAlbumUpdate($0)
                            onAlbumUpdated?($0)
                        })
                        .navigationTransition(
                            .zoom(sourceID: album.id, in: albumNamespace))
                } label: {
                    AlbumRowView(album: album)
                        .matchedTransitionSource(id: album.id, in: albumNamespace)
                }
                // Garis pemisah mulai dari tepi kiri TEKS, bukan dari tepi baris:
                // sampul selebar 60 ditambah sela 12. Nilainya relatif terhadap
                // tepi kiri baris ini sendiri.
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    albumRowThumbnailSide + albumRowSpacing
                }
                .contextMenu {
                    contextMenu(for: album)
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
                        Task { await vm.deleteAlbum(album.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The photos will stay in your library.")
                }
            }
            .onDelete { indices in
                for index in indices {
                    let id = albums[index].id
                    Task { await vm.deleteAlbum(id) }
                }
            }
            // Garis di ATAS baris pertama dibuang: ia bukan pemisah antar apa
            // pun — di atasnya cuma segmented, yang sudah punya batasnya sendiri.
            .listSectionSeparator(.hidden, edges: .top)
        }
        .listStyle(.plain)
    }

    // MARK: - Context menu

    private func contextMenu(for album: AlbumResponseDTO) -> some View {
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
        }

        let query = normalizedSearchText
        if !query.isEmpty {
            filtered = filtered.filter { album in
                album.albumName.localizedStandardContains(query)
                    || album.description?.localizedStandardContains(query) == true
            }
        }

        return filtered.sorted(by: sort)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    // MARK: - Keadaan kosong & gagal

    private func emptyState(_ vm: AlbumListViewModel) -> some View {
        ContentUnavailableView {
            Label("No Albums", systemImage: "rectangle.stack")
        } description: {
            Text("Create an album to organize your photos.")
        } actions: {
            Button("Create Album") { vm.showCreateSheet = true }
                .buttonStyle(.borderedProminent)
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
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                .font(.headline)
                .lineLimit(1)
            Text("^[\(album.assetCount) item](inflect: true)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .padding(12)
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
