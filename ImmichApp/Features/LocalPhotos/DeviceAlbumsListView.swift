import Photos
import SwiftUI

/// Album perangkat, disusun persis seperti daftar Albums server.
///
/// Yang TIDAK ada di sini: segmented All / Shared / Personal. Album perangkat
/// tidak punya pemiliknya masing-masing dan tidak pernah dibagikan, jadi ketiga
/// pilihan itu akan menyaring sesuatu yang tidak ada bedanya.
///
/// Yang ditampilkan hanya album yang dipilih untuk dicadangkan — sama dengan
/// yang muncul di linimasa. Menampilkan seluruh album perangkat berarti
/// menawarkan isi yang tidak pernah dibaca aplikasi ini.
struct DeviceAlbumsListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LocalPhotoLibrary.shared
    @State private var albums: [LocalAlbum] = []
    @State private var albumsRevision: Int?
    @State private var isLoading = true
    @Namespace private var albumNamespace
    @AppStorage("deviceAlbumsLayout") private var layout: AlbumsListView.AlbumLayout = .grid
    @AppStorage("deviceAlbumsSort") private var sort: DeviceAlbumSort = .name

    enum DeviceAlbumSort: String, CaseIterable, Identifiable {
        case name, count
        var id: Self { self }

        var label: LocalizedStringKey {
            switch self {
            case .name: "Name"
            case .count: "Item Count"
            }
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("On This Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
            .task(id: library.revision) { await load() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                library.refreshAuthorizationStatus()
            }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .tag(AlbumsListView.AlbumLayout.grid)
                Label("List", systemImage: "list.bullet")
                    .tag(AlbumsListView.AlbumLayout.list)
            }
            .pickerStyle(.inline)

            Picker("Sort By", selection: $sort) {
                ForEach(DeviceAlbumSort.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: - Isi

    @ViewBuilder
    private var content: some View {
        if !library.isAuthorized && library.authorizationStatus != .notDetermined {
            PhotoLibraryAccessUnavailableView()
        } else if isLoading || albumsRevision != library.revision {
            ProgressView()
        } else if !library.isAuthorized {
            PhotoLibraryAccessUnavailableView()
        } else if visibleAlbums.isEmpty {
            emptyState
        } else {
            switch layout {
            case .grid: grid
            case .list: list
            }
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns(for: proxy.size.width), spacing: 16) {
                    ForEach(visibleAlbums) { album in
                        NavigationLink {
                            detail(for: album)
                        } label: {
                            DeviceAlbumGridCard(album: album)
                                .matchedTransitionSource(id: album.id, in: albumNamespace)
                        }
                        .buttonStyle(.plain)
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

    /// Sama dengan Albums server: iPhone tetap minimal dua kolom, sedangkan
    /// ruang tambahan menambah kolom secara bertahap sampai maksimum empat.
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

    private var list: some View {
        List {
            ForEach(visibleAlbums) { album in
                NavigationLink {
                    detail(for: album)
                } label: {
                    DeviceAlbumRowView(album: album)
                        .matchedTransitionSource(id: album.id, in: albumNamespace)
                }
                // Sejajar dengan daftar album server: garis pemisah mulai dari
                // tepi kiri teks, bukan tepi baris.
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    albumRowThumbnailSide + albumRowSpacing
                }
            }
            .listSectionSeparator(.hidden, edges: .top)
        }
        .listStyle(.plain)
    }

    private func detail(for album: LocalAlbum) -> some View {
        DeviceAlbumDetailView(album: album)
            .navigationTransition(.zoom(sourceID: album.id, in: albumNamespace))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Albums Selected", systemImage: "iphone")
        } description: {
            Text("Choose which albums on this device to include from the Backup screen.")
        }
    }

    // MARK: - Data

    private var visibleAlbums: [LocalAlbum] {
        guard library.isAuthorized, albumsRevision == library.revision else { return [] }
        let selected = albums.filter { library.selectedAlbumIDs.contains($0.id) }
        switch sort {
        case .name:
            return selected.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .count:
            return selected.sorted { $0.count > $1.count }
        }
    }

    private func load() async {
        library.refreshAuthorizationStatus()
        if !library.isAuthorized {
            albums = []
            albumsRevision = nil
        }
        isLoading = albumsRevision != library.revision || albums.isEmpty
        let revision = library.revision
        let fetched = await library.albums()
        guard !Task.isCancelled else { return }
        library.refreshAuthorizationStatus()
        guard revision == library.revision else { return }
        albums = library.isAuthorized ? fetched : []
        albumsRevision = revision
        isLoading = false
    }
}

// MARK: - Kartu & baris

/// Kembaran `AlbumGridCard` untuk album perangkat.
///
/// Tidak bisa dipakai ulang begitu saja: yang itu menerima `AlbumResponseDTO`
/// dan mengambil sampulnya lewat jaringan. Yang di sini membaca dari PhotoKit.
/// Yang disamakan tampilannya, bukan tipenya.
struct DeviceAlbumGridCard: View {
    let album: LocalAlbum

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay {
                DeviceAlbumCover(assetID: album.coverAssetID, placeholderFont: .title)
            }
            caption
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.title)
                .font(.headline)
                .lineLimit(1)
            Text("^[\(album.count) item](inflect: true)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .padding(12)
    }
}

struct DeviceAlbumRowView: View {
    let album: LocalAlbum

    var body: some View {
        HStack(spacing: albumRowSpacing) {
            DeviceAlbumCover(assetID: album.coverAssetID, placeholderFont: .body)
                .frame(width: albumRowThumbnailSide, height: albumRowThumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.caption)
                    Text("\(album.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// Sampul album perangkat.
struct DeviceAlbumCover: View {
    let assetID: String?
    var placeholderFont: Font = .body

    @State private var image: UIImage?
    @State private var imageRevision: Int?
    @State private var library = LocalPhotoLibrary.shared

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image, imageRevision == library.revision, library.isAuthorized {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(placeholderFont)
                        .foregroundStyle(.secondary)
                }
            }
            // WAJIB: tanpa ini `scaledToFill` melebar keluar petaknya dan
            // menabrak kartu di sebelahnya.
            .clipped()
            .task(id: CoverRequest(assetID: assetID, revision: library.revision)) { await loadCover() }
    }

    private func loadCover() async {
        image = nil
        imageRevision = nil
        library.refreshAuthorizationStatus()
        guard let assetID, library.isAuthorized else { return }
        let revision = library.revision
        let fetched = await library.thumbnail(
            for: LocalPhotoLibrary.assetID(for: assetID),
            size: CGSize(width: 600, height: 600))
        library.refreshAuthorizationStatus()
        guard !Task.isCancelled, revision == library.revision, library.isAuthorized else { return }
        image = fetched
        imageRevision = revision
    }

    private struct CoverRequest: Hashable {
        let assetID: String?
        let revision: Int
    }
}
