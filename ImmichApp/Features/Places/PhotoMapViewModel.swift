import Foundation
import Observation

@MainActor
@Observable
final class PhotoMapViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private let dataManager: SwiftDataManager
    private let localPhotos: @MainActor () -> [LocalPhoto]
    private var requestID = UUID()
    private var hasSnapshot: Bool
    private var assetRequestID = UUID()
    private var assetTask: Task<[AssetLite], Error>?
    private var assetRevision: UUID?
    private var assetMappingRevision: UUID?
    private var cachedAssets: [AssetLite]?
    private(set) var markers: [MapMarkerDTO]
    private(set) var isLoading: Bool
    private(set) var loadError: String?
    private(set) var refreshError: String?

    var isCurrentAccount: Bool { snapshotGeneration == LocalSnapshot.generation }
    var store: SwiftDataManager { dataManager }
    var selectedLocalPhotos: [LocalPhoto] { isCurrentAccount ? localPhotos() : [] }

    init(dataManager: SwiftDataManager? = nil,
         localPhotos: @escaping @MainActor () -> [LocalPhoto] = { LocalPhotoLibrary.shared.photos }) {
        self.dataManager = dataManager ?? .shared
        self.localPhotos = localPhotos
        let cached = LocalSnapshot.load([MapMarkerDTO].self, for: LocalSnapshot.Key.places)
        markers = PhotoMapClustering.validated(cached ?? [])
        hasSnapshot = cached != nil
        isLoading = cached == nil
    }

    func load(using fetch: @MainActor () async throws -> [MapMarkerDTO]) async {
        guard !Task.isCancelled, isCurrentAccount else { return }
        let request = UUID()
        let revision = dataManager.assetMutationRevision
        requestID = request
        loadError = nil
        refreshError = nil
        isLoading = !hasSnapshot
        defer {
            if requestID == request, isCurrentAccount {
                isLoading = false
            }
        }
        do {
            let fetched = PhotoMapClustering.validated(try await fetch())
            guard !Task.isCancelled, isCurrentAccount, requestID == request,
                  revision == dataManager.assetMutationRevision else { return }
            cancelAssetLoading()
            cachedAssets = nil
            assetRevision = nil
            assetMappingRevision = nil
            LocalSnapshot.save(fetched, for: LocalSnapshot.Key.places, expectedGeneration: snapshotGeneration)
            if markers != fetched { markers = fetched }
            hasSnapshot = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  isCurrentAccount, requestID == request else { return }
            let message = (error as? APIError)?.errorDescription ?? String(localized: "Failed to load places")
            if !hasSnapshot {
                loadError = message
            } else {
                refreshError = message
            }
        }
    }

    var admittedMarkers: [MapMarkerDTO] {
        guard isCurrentAccount else { return [] }
        _ = dataManager.backupMappingRevision
        return PhotoMapSources.markers(server: markers, selectedLocal: localPhotos(),
            mappings: dataManager.serverAssetIDsByLocalIdentifier(),
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager))
    }

    func markers(forAssetIDs ids: Set<String>?) -> [MapMarkerDTO] {
        let admitted = admittedMarkers
        guard let ids else { return admitted }
        let mappings = dataManager.serverAssetIDsByLocalIdentifier()
        let requested = Set(ids.map { PhotoMapSources.canonicalID($0, mappings: mappings) })
        return admitted.filter { requested.contains(PhotoMapSources.canonicalID($0.id, mappings: mappings)) }
    }

    func thumbnailID(for markerID: String) -> String? {
        guard isCurrentAccount else { return nil }
        let mappings = dataManager.serverAssetIDsByLocalIdentifier()
        let id = PhotoMapSources.canonicalID(markerID, mappings: mappings)
        guard admittedMarkers.contains(where: { PhotoMapSources.canonicalID($0.id, mappings: mappings) == id }) else { return nil }
        if LocalPhotoLibrary.isLocal(id) { return id }
        let hasCanonicalMetadata = dataManager.getCachedAsset(id: id) != nil || cachedAssets?.contains { $0.id == id } == true
        if markers.contains(where: { $0.id == id }) || hasCanonicalMetadata { return id }
        let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
        if let local = selectedLocalPhotos.first(where: {
            let localID = LocalPhotoLibrary.assetID(for: $0.id)
            return PhotoMapSources.canonicalID(localID, mappings: mappings) == id && policy.allows(id: localID)
        }) {
            return LocalPhotoLibrary.assetID(for: local.id)
        }
        return id
    }

    func assets(
        for ids: Set<String>, using fetch: @escaping @MainActor () async throws -> [AssetLite]
    ) async throws -> [AssetLite] {
        try Task.checkCancellation()
        guard isCurrentAccount else { throw CancellationError() }
        let mappings = dataManager.serverAssetIDsByLocalIdentifier()
        let mappingRevision = dataManager.backupMappingRevision
        let local = localPhotos()
        let requested = Set(ids.map { PhotoMapSources.canonicalID($0, mappings: mappings) })
        let admitted = requested.intersection(Set(admittedMarkers.map { PhotoMapSources.canonicalID($0.id, mappings: mappings) }))
        guard !admitted.isEmpty else { return [] }
        if admitted.allSatisfy(LocalPhotoLibrary.isLocal) { return cachedAssets(for: ids) }
        let revision = dataManager.assetMutationRevision
        if assetRevision != revision || assetMappingRevision != mappingRevision {
            cancelAssetLoading()
            cachedAssets = nil
            assetRevision = revision
            assetMappingRevision = mappingRevision
        }
        let loaded: [AssetLite]
        if let cachedAssets {
            loaded = cachedAssets
        } else {
            let task: Task<[AssetLite], Error>
            if let assetTask {
                task = assetTask
            } else {
                assetRequestID = UUID()
                task = Task { try await fetch() }
                assetTask = task
            }
            let request = assetRequestID
            do {
                loaded = try await task.value
                try Task.checkCancellation()
                guard isCurrentAccount, assetRequestID == request,
                      dataManager.assetMutationRevision == revision else { throw CancellationError() }
                cachedAssets = loaded
                assetTask = nil
            } catch {
                if assetRequestID == request { assetTask = nil }
                throw error
            }
        }
        try Task.checkCancellation()
        guard isCurrentAccount, dataManager.assetMutationRevision == revision,
              dataManager.backupMappingRevision == mappingRevision, localPhotos() == local else { throw CancellationError() }
        return selectionAssets(from: loaded, for: ids, mappings: mappings, local: local)
    }

    func cachedAssets(for ids: Set<String>) -> [AssetLite] {
        guard isCurrentAccount else { return [] }
        let current = assetRevision == dataManager.assetMutationRevision && assetMappingRevision == dataManager.backupMappingRevision
        let server = current ? cachedAssets : nil
        return selectionAssets(from: server ?? dataManager.timelineAssets().map(\.asset), for: ids,
            mappings: dataManager.serverAssetIDsByLocalIdentifier(), local: localPhotos())
    }

    private func selectionAssets(
        from server: [AssetLite], for ids: Set<String>, mappings: [String: String], local: [LocalPhoto]
    ) -> [AssetLite] {
        let requested = Set(ids.map { PhotoMapSources.canonicalID($0, mappings: mappings) })
        let admitted = requested.intersection(Set(admittedMarkers.map { PhotoMapSources.canonicalID($0.id, mappings: mappings) }))
        let assets = CollectionsAssetSources.merge(server: server, selectedLocal: local, mappings: mappings,
            knownServerIDs: Set(dataManager.timelineAssets().map(\.asset.id)),
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager))
        var seen = Set<String>()
        return assets.filter {
            let id = PhotoMapSources.canonicalID($0.id, mappings: mappings)
            return admitted.contains(id) && seen.insert(id).inserted
        }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }

    func cancelAssetLoading() {
        assetRequestID = UUID()
        assetTask?.cancel()
        assetTask = nil
    }
}
