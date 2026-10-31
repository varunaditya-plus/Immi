import SwiftUI

struct SearchRecentsView: View {
    let store: RecentlyViewedStore
    let onOpen: () -> Void

    var body: some View {
        if let cover = store.assets.first {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recents").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Button(action: onOpen) {
                    AuthImage(assetId: cover.id, thumbhash: cover.thumbhash)
                        .frame(width: 112, height: 112)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            Text("Recently Viewed").font(.caption.weight(.semibold))
                                .foregroundStyle(.white).padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                        .clipShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recently Viewed")
            }
        }
    }
}

struct RecentlyViewedCollectionView: View {
    let store: RecentlyViewedStore
    @Environment(SessionManager.self) private var session
    @State private var model: AssetGridViewModel?
    @State private var albumPicker: AssetLite?
    @State private var actionMessage: ErrorEvent?
    @State private var showsClearConfirmation = false

    init(store: RecentlyViewedStore, viewModel: AssetGridViewModel? = nil) {
        self.store = store
        _model = State(initialValue: viewModel)
    }

    var body: some View {
        PhotoCollectionScreen(
            title: "Recently Viewed", assets: store.assets, phase: .loaded(()),
            actionError: Binding(get: { model?.actionError }, set: { model?.actionError = $0 }),
            emptyState: PhotoCollectionEmptyState(title: "No Recently Viewed Photos", systemImage: "clock",
                description: "Photos you view appear here."),
            onRetry: { Task { await model?.load() } },
            onToggleFavorite: { asset in await setFavorite([asset.id], to: !asset.isFavorite) },
            onDelete: { _ = await model?.delete($0) },
            shareURLs: { await model?.shareURLs(for: $0) ?? [] },
            onAddToAlbum: { albumPicker = $0 },
            onFavoriteSelection: { ids in await setFavorite(ids, to: true) },
            onArchiveSelection: { _ = await model?.setArchived($0, to: true) },
            onMoveToLocked: { _ = await model?.setLocked($0) }, visibilityScope: .timeline,
            options: {
                Button("Clear Recently Viewed", systemImage: "trash", role: .destructive) {
                    showsClearConfirmation = true
                }
                .disabled(store.assets.isEmpty)
            })
        .task(id: store.assets.map(\.id)) {
            if model == nil {
                let api = APIClient(session: session)
                let store = store
                model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: store.dataManager),
                    albumRepo: AlbumRepository(api: api), dataManager: store.dataManager) { store.assets }
            }
            await model?.load()
        }
        .sheet(item: $albumPicker) { asset in
            AlbumPickerLoader { album in
                Task {
                    if let message = await model?.addToAlbum([asset.id], album: album) { actionMessage = ErrorEvent(message) }
                }
            }
        }
        .confirmationDialog("Clear Recently Viewed?", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("Clear Recently Viewed", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your photos will stay in your library.") }
        .errorToast($actionMessage)
    }

    private func setFavorite(_ ids: [String], to value: Bool) async {
        for id in ids {
            guard await model?.setFavorite([id], to: value) == true else { return }
            store.updateFavorite(id, to: value)
        }
    }
}
