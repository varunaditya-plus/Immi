import SwiftUI

struct DerivedCollectionView: View {
    let title: LocalizedStringKey
    let assets: @MainActor @Sendable () -> [AssetLite]
    var dateInterval: DateInterval? = nil
    var refreshSources: @MainActor @Sendable () -> Void = {}
    var dayLoader: (@MainActor @Sendable (DateInterval) async throws -> [AssetLite])? = nil
    var assetLoader: (@MainActor @Sendable () async throws -> [AssetLite])? = nil
    var layout: PhotoCollectionLayout = .hero
    var keepsTabBarVisible = false
    var onSelectionChanged: (Bool) -> Void = { _ in }
    var dataManager: SwiftDataManager? = nil
    var localPhotos: @MainActor () -> [LocalPhoto] = { LocalPhotoLibrary.shared.photos }

    @Environment(SessionManager.self) private var session
    @State private var model: TimelineViewModel?
    @State private var generation: UUID?
    @State private var phase: LoadingPhase<Void> = .loading
    @State private var loadError: String?
    @State private var request = UUID()
    @State private var albumPickerAsset: AssetLite?

    var body: some View {
        collection
            .safeAreaInset(edge: .bottom) {
                if let loadError, !displayedAssets.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Failed to Load").font(.subheadline.weight(.semibold))
                            Text(loadError).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .sheet(item: $albumPickerAsset) { asset in
                AlbumPickerLoader { album in
                    Task { await model?.addToAlbum(asset, album: album) }
                }
            }
            .task(id: session.accountGeneration) { await load() }
            .onChange(of: SourceSnapshot(assets: assets())) { _, _ in
                if dateInterval == nil && assetLoader == nil { seed(assets()) }
                else { Task { await load() } }
            }
            .onChange(of: localPhotos()) { _, _ in Task { await load() } }
            .onDisappear { request = UUID() }
    }

    private var displayedAssets: [AssetLite] {
        guard generation == LocalSnapshot.generation else { return [] }
        let selected = Set(localPhotos().map(\.id))
        return AssetVisibilityPolicy(scope: .timeline, dataManager: store).filter(model?.libraryAssets ?? []).filter {
            !LocalPhotoLibrary.isLocal($0.id) || selected.contains(LocalPhotoLibrary.localIdentifier(from: $0.id))
        }
    }

    private var collection: some View {
        PhotoCollectionScreen(
            title: title,
            layout: layout,
            assets: displayedAssets,
            phase: phase,
            actionError: Binding(get: { model?.actionError }, set: { model?.actionError = $0 }),
            onRetry: { Task { await load() } },
            onToggleFavorite: { _ = await model?.toggleFavorite($0) },
            onDelete: { _ = await model?.deleteSelected($0) },
            shareURLs: { await model?.shareURLs(for: $0) ?? [] },
            onAddToAlbum: { albumPickerAsset = $0 },
            onFavoriteSelection: { _ = await model?.favoriteSelected($0) },
            onArchiveSelection: { _ = await model?.archiveSelected($0) },
            onMoveToLocked: { _ = await model?.lockSelected($0) },
            visibilityScope: .timeline,
            canPerformServerActions: { AssetServerIdentity.resolve($0, using: store) != nil },
            keepsTabBarVisible: keepsTabBarVisible,
            onSelectionChanged: onSelectionChanged)
    }

    private func seed(_ items: [AssetLite]) {
        guard generation == LocalSnapshot.generation else { return }
        model?.sections = [TimelineSection(id: "derived", title: "", assets: items, count: items.count)]
    }

    private var store: SwiftDataManager { dataManager ?? .shared }

    private func load(retryCanceledSource: Bool = true) async {
        let id = UUID()
        request = id
        if generation != session.accountGeneration {
            generation = session.accountGeneration
            let api = APIClient(session: session)
            model = TimelineViewModel(dataManager: store, assetRepo: AssetDetailRepository(api: api), albumRepo: AlbumRepository(api: api),
                localPhotos: localPhotos)
        }
        loadError = nil
        refreshSources()
        if (dateInterval == nil && assetLoader == nil) || model?.libraryAssets.isEmpty != false { seed(assets()) }
        guard dateInterval != nil || assetLoader != nil else {
            phase = .loaded(())
            return
        }
        if displayedAssets.isEmpty { phase = .loading }
        do {
            let loaded: [AssetLite]
            if let assetLoader {
                loaded = try await assetLoader()
            } else if let dateInterval, let dayLoader {
                loaded = try await dayLoader(dateInterval)
            } else if let dateInterval {
                let api = APIClient(session: session)
                let repository = RecentDayRepository(repository: SearchRepository(api: api))
                loaded = try await repository.assets(in: dateInterval)
            } else {
                return
            }
            guard !Task.isCancelled, request == id, generation == LocalSnapshot.generation else { return }
            seed(loaded)
            phase = .loaded(())
        } catch is CancellationError {
            guard !Task.isCancelled, request == id, generation == LocalSnapshot.generation else { return }
            if retryCanceledSource {
                await load(retryCanceledSource: false)
            } else {
                let message = String(localized: "Your photo library changed. Try again.")
                loadError = message
                phase = displayedAssets.isEmpty ? .failed(message) : .loaded(())
            }
        } catch {
            guard !Task.isCancelled, request == id, generation == LocalSnapshot.generation else { return }
            let message = (error as? APIError)?.errorDescription ?? String(localized: "Failed to load photos")
            loadError = message
            phase = displayedAssets.isEmpty ? .failed(message) : .loaded(())
        }
    }

    private struct SourceSnapshot: Equatable {
        let assets: [AssetLite]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.assets.elementsEqual(rhs.assets) { $0.hasSameContent(as: $1) }
        }
    }
}
