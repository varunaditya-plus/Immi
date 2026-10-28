import Foundation

/// Operasi khusus tong sampah.
///
/// Terpisah dari `AssetDetailRepository` karena artinya berbeda: di sana
/// "delete" berarti MEMINDAHKAN ke tong sampah, sedangkan di sini penghapusannya
/// permanen dan tidak bisa dibatalkan.
class TrashRepository {
    private let api: APIClient
    private let dataManager: SwiftDataManager?

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.dataManager = dataManager
    }

    /// Trash spans ordinary and archived visibility. Omit the browsing default
    /// and keep the deleted-date predicate so live assets cannot enter the grid.
    @MainActor
    func assets() async throws -> [AssetResponseDTO] {
        let manager = dataManager ?? .shared
        let generation = LocalSnapshot.generation
        let context = api.session.snapshot
        let assetRevision = manager.assetMutationRevision
        let removedRevision = RemovedAssets.shared.trashRevision
        let items = try await SearchRepository(api: api, dataManager: manager, recordsVisibility: false).allMetadata(
            SearchRequestDTO(order: "desc", size: 200, visibility: nil, withDeleted: true,
                trashedAfter: "1970-01-01T00:00:00.000Z"))
        try Task.checkCancellation()
        try api.checkCurrent(context)
        guard generation == LocalSnapshot.generation,
              removedRevision == RemovedAssets.shared.trashRevision else { throw CancellationError() }
        let trashed = items.filter(\.isTrashed)
        let ids = trashed.map(\.id)
        if assetRevision == manager.assetMutationRevision,
           RemovedAssets.shared.confirmTrashed(ids, expectedRevision: removedRevision) {
            // Private rows stay out of Trash, but their device/cache copies must
            // also stay out of the library after the app restarts.
            DeletedServerAssetRegistry.shared.record(ids, permanently: false)
        }
        let policy = AssetVisibilityPolicy(scope: .collection, removalScope: .trash, dataManager: manager)
        return trashed.filter {
            ($0.visibility == nil || $0.visibility == "timeline" || $0.visibility == "archive")
                && policy.allows(id: $0.id)
        }
    }

    /// Menghapus PERMANEN seluruh isi tong sampah.
    func empty() async throws {
        try await api.sendVoid(.init(path: "/trash/empty", method: .post))
    }

    /// Mengembalikan seluruh isi tong sampah ke perpustakaan.
    func restoreAll() async throws {
        try await api.sendVoid(.init(path: "/trash/restore", method: .post))
    }

    func restore(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await api.sendVoid(
            .json("/trash/restore/assets", method: .post, body: ["ids": ids]))
    }
}
