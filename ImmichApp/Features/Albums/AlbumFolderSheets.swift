import SwiftUI

enum AlbumBrowserItem: Identifiable {
    case album(AlbumResponseDTO)
    case folder(AlbumFolder)

    var id: String {
        switch self {
        case .album(let album): AlbumOrganization.albumEntry(album.id)
        case .folder(let folder): AlbumOrganization.folderEntry(folder.id)
        }
    }
}

struct AlbumFolderCard: View {
    let folder: AlbumFolder
    let albums: [AlbumResponseDTO]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16).fill(.fill.tertiary)
            VStack(spacing: 4) {
                ForEach(0..<2) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<2) { column in
                            let index = row * 2 + column
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    if index < albums.count {
                                        AlbumCoverImage(album: albums[index])
                                    } else {
                                        RoundedRectangle(cornerRadius: 5).fill(.fill.quaternary)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .padding(12)
            .padding(.bottom, 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.headline).lineLimit(1)
                Label("Folder", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct AlbumBrowserReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AlbumBrowserItem]
    let onSave: ([String]) -> Void

    init(items: [AlbumBrowserItem], onSave: @escaping ([String]) -> Void) {
        _items = State(initialValue: items)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        switch item {
                        case .album(let album): AlbumRowView(album: album)
                        case .folder(let folder): Label(folder.name, systemImage: "folder")
                        }
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Folders and custom order are saved on this device.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(items.map(\.id)); dismiss() }
                }
            }
        }
    }
}

struct AlbumMoveToFolderSheet: View {
    let folders: [AlbumFolder]
    let currentFolderID: String?
    let onMove: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                destination(String(localized: "Albums"), id: nil)
                ForEach(folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                    destination(folder.name, id: folder.id)
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func destination(_ name: String, id: String?) -> some View {
        Button { onMove(id); dismiss() } label: {
            HStack {
                Label(name, systemImage: id == nil ? "rectangle.stack" : "folder")
                Spacer()
                if id == currentFolderID { Image(systemName: "checkmark") }
            }
        }
    }
}
