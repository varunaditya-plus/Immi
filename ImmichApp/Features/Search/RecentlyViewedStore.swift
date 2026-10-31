import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class RecentlyViewedStore {
    private struct Storage { var assets: [AssetLite] }
    private static var activeStore: RecentlyViewedStore?
    private let owner: BackupQueueOwner?
    private let generation = LocalSnapshot.generation
    private let defaults: UserDefaults
    private let key: String?
    private let limit: Int
    let dataManager: SwiftDataManager
    private var storage: Storage

    static func forAccount(_ owner: BackupQueueOwner?) -> RecentlyViewedStore {
        if let activeStore, activeStore.owner == owner, activeStore.isCurrent { return activeStore }
        let store = RecentlyViewedStore(owner: owner)
        activeStore = store
        return store
    }

    init(owner: BackupQueueOwner?, defaults: UserDefaults = .standard,
         dataManager: SwiftDataManager? = nil, limit: Int = 100) {
        self.owner = owner
        self.defaults = defaults
        self.dataManager = dataManager ?? .shared
        self.limit = max(1, limit)
        key = owner.map {
            let identity = (try? JSONEncoder().encode([$0.server, $0.userID])) ?? Data()
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            return "search.recentlyViewed.v1.\(digest)"
        }
        let saved = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([AssetLite].self, from: $0) } ?? []
        var seen = Set<String>()
        storage = Storage(assets: Array(saved.filter { seen.insert($0.id).inserted }.prefix(max(1, limit))))
    }

    var isCurrent: Bool { generation == LocalSnapshot.generation }

    var assets: [AssetLite] {
        guard isCurrent, owner != nil else { return [] }
        return AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).filter(storage.assets)
    }

    func record(_ detail: AssetResponseDTO) {
        guard !Task.isCancelled, isCurrent, owner != nil, detail.isTimelineVisible,
              !LocalPhotoLibrary.isLocal(detail.id),
              AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: detail.id) else { return }
        let asset = AssetLite(detail)
        change {
            $0.removeAll { $0.id == asset.id }
            $0.insert(asset, at: 0)
        }
    }

    func updateFavorite(_ id: String, to value: Bool) {
        update(id) { $0.isFavorite = value }
    }

    func updateCaptureDate(_ id: String, to date: Date) {
        update(id) { $0.createdAt = date }
    }

    func clear() { change { $0 = [] } }

    private func update(_ id: String, applying update: (inout AssetLite) -> Void) {
        change { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            update(&records[index])
        }
    }

    private func change(_ operation: (inout [AssetLite]) -> Void) {
        guard !Task.isCancelled, isCurrent, let key else { return }
        var updated = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([AssetLite].self, from: $0) } ?? storage.assets
        let previous = updated
        operation(&updated)
        var seen = Set<String>()
        updated = Array(updated.filter { seen.insert($0.id).inserted }.prefix(limit))
        if !updated.elementsEqual(storage.assets, by: { $0.hasSameContent(as: $1) }) {
            storage = Storage(assets: updated)
        }
        guard !updated.elementsEqual(previous, by: { $0.hasSameContent(as: $1) }) else { return }
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: key) }
    }
}
