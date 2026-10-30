import SwiftUI

struct CollectionsReorderView: View {
    @Binding var preferences: CollectionsPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(preferences.sectionOrder) { section in
                    Text(section.title)
                }
                .onMove { preferences.sectionOrder.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { preferences.sectionOrder = CollectionsSection.allCases }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PinnedCollectionsEditor: View {
    @Binding var preferences: CollectionsPreferences
    let albums: [AlbumResponseDTO]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Pinned") {
                    ForEach(preferences.pinnedCollections) { reference in
                        Label(reference.title(in: albums), systemImage: reference.systemImage)
                    }
                    .onDelete { preferences.pinnedCollections.remove(atOffsets: $0) }
                    .onMove { preferences.pinnedCollections.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Suggestions") {
                    ForEach(PinnedCollectionReference.suggestions.filter { !preferences.pinnedCollections.contains($0) }) { reference in
                        addButton(reference)
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums.filter { !preferences.pinnedCollections.contains(.album($0.id)) }) { album in
                            addButton(.album(album.id))
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pinned Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addButton(_ reference: PinnedCollectionReference) -> some View {
        Button {
            preferences.pinnedCollections.append(reference)
        } label: {
            HStack {
                Label(reference.title(in: albums), systemImage: reference.systemImage)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Pin \(reference.title(in: albums))"))
    }
}

extension PinnedCollectionReference {
    func title(in albums: [AlbumResponseDTO]) -> String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .map: String(localized: "Map")
        case .videos: String(localized: "Videos")
        case .recentlyDeleted: String(localized: "Recently Deleted")
        case .albums: String(localized: "Albums")
        case .people: String(localized: "People")
        case .memories: String(localized: "Memories")
        case .album(let id): albums.first(where: { $0.id == id })?.albumName ?? String(localized: "Album Unavailable")
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: "heart.fill"
        case .map: "map.fill"
        case .videos: "video.fill"
        case .recentlyDeleted: "trash.fill"
        case .albums, .album: "rectangle.stack.fill"
        case .people: "person.2.fill"
        case .memories: "sparkles.rectangle.stack.fill"
        }
    }
}
