import Foundation

@MainActor
struct AssetVisibilityPolicy {
    enum Scope: Equatable { case collection, timeline, locked }

    struct State: Equatable {
        let suppressedIDs: Set<String>
        let removedIDs: Set<String>
        let deletedIDs: Set<String>
        let mappingRevision: UUID
    }

    let scope: Scope
    let removalScope: RemovedAssets.Scope
    private let dataManager: SwiftDataManager
    private let removed: RemovedAssets
    private let deleted: DeletedServerAssetRegistry
    private let mappingCache = MappingCache()

    @MainActor
    private final class MappingCache {
        private var revision: UUID?
        private var links: [String: String] = [:]

        func mappings(in manager: SwiftDataManager) -> [String: String] {
            let current = manager.backupMappingRevision
            if revision == current, !links.isEmpty { return links }
            links = manager.serverAssetIDsByLocalIdentifier()
            // The store's fetch helper also returns empty on a read failure.
            // Let the next lookup retry instead of pinning an unknown result.
            revision = links.isEmpty ? nil : current
            return links
        }
    }

    init(
        scope: Scope = .collection,
        removalScope: RemovedAssets.Scope = .library,
        dataManager: SwiftDataManager? = nil,
        removed: RemovedAssets? = nil,
        deleted: DeletedServerAssetRegistry? = nil
    ) {
        self.scope = scope
        self.removalScope = removalScope
        self.dataManager = dataManager ?? .shared
        self.removed = removed ?? .shared
        self.deleted = deleted ?? .shared
    }

    var state: State {
        State(suppressedIDs: suppressedIDs, removedIDs: removed.excludedIDs(scope: removalScope),
              deletedIDs: deletedIDs,
              mappingRevision: dataManager.backupMappingRevision)
    }

    func allows(id: String) -> Bool {
        let isLocal = LocalPhotoLibrary.isLocal(id)
        let suppressed = suppressedIDs
        if isLocal {
            // Keep the fast path observable when a private mapping is added.
            _ = dataManager.backupMappingRevision
            let hasDurableRemoval = removalScope == .trash
                ? deleted.hasPermanentlyDeletedAssets : deleted.hasSuppressedAssets
            if suppressed.isEmpty, removed.ids.isEmpty, !hasDurableRemoval { return true }
        }
        let serverID = isLocal
            ? mappingCache.mappings(in: dataManager)[LocalPhotoLibrary.localIdentifier(from: id)]
            : id
        guard !deleted.isPermanentlyDeleted(id), removalScope == .trash || !deleted.isTrashed(id),
              serverID.map({ !deleted.isPermanentlyDeleted($0)
                  && (removalScope == .trash || !deleted.isTrashed($0)) }) ?? true else { return false }
        return allows(id: id, serverID: serverID, suppressed: suppressed)
    }

    func filter(_ assets: [AssetLite]) -> [AssetLite] {
        let current = state
        let suppressed = current.suppressedIDs
        let deleted = current.deletedIDs
        guard !suppressed.isEmpty || !current.removedIDs.isEmpty || !deleted.isEmpty else { return assets }
        let links = assets.contains { LocalPhotoLibrary.isLocal($0.id) }
            ? mappingCache.mappings(in: dataManager) : [:]
        return assets.filter { asset in
            let serverID = LocalPhotoLibrary.isLocal(asset.id)
                ? links[LocalPhotoLibrary.localIdentifier(from: asset.id)] : asset.id
            return !deleted.contains(asset.id) && !(serverID.map(deleted.contains) ?? false)
                && allows(id: asset.id, serverID: serverID, suppressed: suppressed)
        }
    }

    func filterSections(_ sections: [TimelineSection]) -> [TimelineSection] {
        let allowed = Set(filter(sections.flatMap(\.assets)).map(\.id))
        var offset = 0
        return sections.compactMap { section in
            let assets = section.assets.filter { allowed.contains($0.id) }
            guard !assets.isEmpty else { return nil }
            defer { offset += assets.count }
            return TimelineSection(id: section.id, title: section.title,
                                   assets: assets, count: assets.count, startIndex: offset)
        }
    }

    private var suppressedIDs: Set<String> {
        switch scope {
        case .collection: dataManager.privateAssetIDs
        case .timeline: dataManager.nonTimelineAssetIDs
        case .locked: []
        }
    }

    private var deletedIDs: Set<String> {
        removalScope == .trash ? deleted.permanentlyDeletedIDs : deleted.suppressedIDs
    }

    private func allows(id: String, serverID: String?, suppressed: Set<String>) -> Bool {
        guard !removed.contains(id, scope: removalScope) else { return false }
        guard let serverID else { return true }
        return !suppressed.contains(serverID) && !removed.contains(serverID, scope: removalScope)
    }
}
