import SwiftUI

struct CollectionAlbumCard<Destination: View>: View {
    let album: AlbumResponseDTO
    let width: CGFloat
    let onEdit: () -> Void
    let onAddUser: () -> Void
    let onCreateLink: () -> Void
    let onDelete: (String) -> Void
    @ViewBuilder let destination: () -> Destination

    @Environment(SessionManager.self) private var session
    @State private var showsDeleteConfirmation = false
    @Namespace private var namespace

    var body: some View {
        NavigationLink {
            destination()
                .navigationTransition(.zoom(sourceID: album.id, in: namespace))
        } label: {
            AlbumCard(album: album, width: width)
                .matchedTransitionSource(id: album.id, in: namespace)
        }
        .buttonStyle(.plain)
        .contextMenu {
            AlbumActionsMenu(
                onEdit: onEdit,
                onAddUser: onAddUser,
                onCreateLink: onCreateLink,
                onDelete: { showsDeleteConfirmation = true })
        } preview: {
            AlbumCoverPreview(album: album, session: session)
        }
        .accessibilityAction(named: Text("Delete Album")) { showsDeleteConfirmation = true }
        .confirmationDialog(
            "Delete “\(album.albumName)”?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) { onDelete(album.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos will stay in your library.")
        }
    }
}
