import SwiftUI

/// Konfigurasi dilakukan di app biasa, sebelum supporter menyalakan Assistive
/// Access di Settings. iOS belum menyediakan configuration extension untuk
/// menaruh opsi app pihak ketiga langsung di alur pemilihan app sistem.
struct AssistiveAccessSettingsView: View {
    @AppStorage(AssistiveAccessPreferences.showsHomeKey)
    private var showsHome = AssistiveAccessPreferences.defaultShowsHome
    @AppStorage(AssistiveAccessPreferences.showsFavoritesKey)
    private var showsFavorites = AssistiveAccessPreferences.defaultShowsFavorites
    @AppStorage(AssistiveAccessPreferences.albumIDKey)
    private var selectedAlbumID = ""
    @AppStorage(AssistiveAccessPreferences.albumNameKey)
    private var selectedAlbumName = ""

    @State private var albums: AlbumListViewModel

    init(session: SessionManager) {
        let api = APIClient(session: session)
        _albums = State(initialValue: AlbumListViewModel(
            repo: AlbumRepository(api: api)))
    }

    var selectedAlbumLabel: String {
        selectedAlbumID.isEmpty || selectedAlbumName.isEmpty
            ? String(localized: "None") : selectedAlbumName
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show Home", isOn: $showsHome)
            } footer: {
                Text(showsHome
                     ? "SelfPhotos opens with a menu for the content enabled below."
                     : "SelfPhotos opens Photos directly. Favorites and the selected album stay saved for later.")
            }

            Section("Home Menu") {
                Toggle("Show Favorites", isOn: $showsFavorites)

                NavigationLink {
                    AssistiveAccessAlbumPicker(
                        viewModel: albums,
                        selectedAlbumID: $selectedAlbumID,
                        selectedAlbumName: $selectedAlbumName)
                } label: {
                    LabeledContent {
                        Text(selectedAlbumLabel)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Album", systemImage: "rectangle.stack")
                    }
                }
            }
        }
        .navigationTitle("Assistive Access")
        .navigationBarTitleDisplayMode(.inline)
        .settingsSheetCloseButton()
        .task { await albums.loadAlbums() }
        .onChange(of: albums.albums) { _, loaded in
            guard !selectedAlbumID.isEmpty else { return }
            guard let album = loaded.first(where: { $0.id == selectedAlbumID }) else {
                selectedAlbumID = ""
                selectedAlbumName = ""
                return
            }
            selectedAlbumName = album.albumName
        }
    }
}

private struct AssistiveAccessAlbumPicker: View {
    let viewModel: AlbumListViewModel
    @Binding var selectedAlbumID: String
    @Binding var selectedAlbumName: String

    var body: some View {
        List {
            selectionRow(id: "", name: String(localized: "None"), systemImage: "nosign")

            if viewModel.phase.isLoading, viewModel.albums.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let error = viewModel.phase.errorMessage, viewModel.albums.isEmpty {
                ContentUnavailableView(
                    "Couldn’t Load Albums",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else {
                ForEach(viewModel.albums) { album in
                    selectionRow(
                        id: album.id,
                        name: album.albumName,
                        systemImage: "rectangle.stack")
                }
            }
        }
        .navigationTitle("Album")
        .navigationBarTitleDisplayMode(.inline)
        .settingsSheetCloseButton()
        .task { await viewModel.loadAlbums() }
    }

    private func selectionRow(id: String, name: String, systemImage: String) -> some View {
        Button {
            selectedAlbumID = id
            selectedAlbumName = id.isEmpty ? "" : name
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer()
                if selectedAlbumID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedAlbumID == id ? .isSelected : [])
    }
}
