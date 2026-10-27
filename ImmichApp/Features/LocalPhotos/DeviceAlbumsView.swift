import Photos
import SwiftUI
import UIKit

/// Memilih album perangkat mana yang ikut tampil di linimasa.
///
/// **Kenapa dipilih, bukan seluruh pustaka.** Menampilkan foto perangkat berarti
/// mencocokkannya dengan server, dan mencocokkan berarti membaca seluruh byte
/// setiap foto — pada pustaka yang sebagian isinya masih di iCloud, itu berarti
/// mengunduhnya lebih dulu. Untuk tiga ratus foto itu puluhan detik; untuk tiga
/// puluh ribu, itu berjam-jam dan berkuota.
///
/// Immich resmi memecahkannya dengan cara yang sama: kamu memilih albumnya, dan
/// hanya album itu yang dihitung.
struct DeviceAlbumsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LocalPhotoLibrary.shared
    @State private var albums: [LocalAlbum] = []
    @State private var albumsRevision: Int?
    @State private var isLoading = true
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("Device Albums")
            .navigationBarTitleDisplayMode(.inline)
            // `.searchable`, bukan TextField di dalam List: yang ini menempel di
            // nav bar, ikut menyusut saat digulir, dan sudah membawa tombol
            // Cancel serta perilaku papan ketik yang benar tanpa diminta.
            .searchable(text: $query, prompt: "Search albums")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                        .disabled(!library.isAuthorized || albumsRevision != library.revision || filteredAlbums.isEmpty)
                }
            }
            .task(id: library.revision) { await load() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                library.refreshAuthorizationStatus()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !library.isAuthorized && library.authorizationStatus != .notDetermined {
            PhotoLibraryAccessUnavailableView()
        } else if isLoading || albumsRevision != library.revision {
            ProgressView()
        } else if !library.isAuthorized {
            PhotoLibraryAccessUnavailableView()
        } else if albums.isEmpty {
            // DUA sebab yang berbeda, dan dua kalimat yang berbeda.
            //
            // Izin ditolak dan pustaka yang memang kosong sama-sama menghasilkan
            // daftar kosong, tapi hanya yang pertama punya jalan keluar — dan
            // jalan keluarnya bukan meminta izin lagi. Setelah ditolak sekali,
            // `requestAuthorization` pulang seketika tanpa memunculkan apa pun;
            // yang bisa mengubahnya cuma Settings sistem.
            ContentUnavailableView(
                "No Albums",
                systemImage: "photo.on.rectangle",
                description: Text("There are no photo albums on this device."))
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && filteredAlbums.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(filteredAlbums) { album in
                    Button {
                        toggle(album)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                Text("\(album.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if library.selectedAlbumIDs.contains(album.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                // Ongkosnya disebutkan DI MUKA, bukan setelah baterainya habis.
                Text("""
                    Photos in these albums appear in your timeline, marked as \
                    on-device. SelfPhotos reads each one once to check whether it is \
                    already on the server — photos stored only in iCloud are \
                    downloaded to do that.
                    """)
            }
        }
    }

    private var filteredAlbums: [LocalAlbum] {
        guard albumsRevision == library.revision else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return albums }
        return albums.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Berlaku atas yang TERSARING, bukan seluruh pustaka.
    ///
    /// Kalau tidak, menekan "Select All" setelah mencari akan diam-diam ikut
    /// memilih album yang sedang tidak terlihat sama sekali — dan yang
    /// tersembunyi itulah yang isinya ribuan foto.
    private var allSelected: Bool {
        !filteredAlbums.isEmpty
            && filteredAlbums.allSatisfy { library.selectedAlbumIDs.contains($0.id) }
    }

    private func toggleAll() {
        library.refreshAuthorizationStatus()
        guard library.isAuthorized, albumsRevision == library.revision else { return }
        let ids = filteredAlbums.map(\.id)
        if allSelected {
            library.selectedAlbumIDs.subtract(ids)
        } else {
            library.selectedAlbumIDs.formUnion(ids)
        }
    }

    private func toggle(_ album: LocalAlbum) {
        library.refreshAuthorizationStatus()
        guard library.isAuthorized, albumsRevision == library.revision else { return }
        if library.selectedAlbumIDs.contains(album.id) {
            library.selectedAlbumIDs.remove(album.id)
        } else {
            library.selectedAlbumIDs.insert(album.id)
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

struct PhotoLibraryAccessUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Access to Photos", systemImage: "lock")
        } description: {
            Text("SelfPhotos needs access to your photos to show what is on this device.")
        } actions: {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
