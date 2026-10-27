import Foundation

@MainActor
final class AssetVisibilityRequest {
    private let api: APIClient
    private let dataManager: SwiftDataManager
    private let context: SessionRequestContext
    private let snapshotGeneration: UUID
    private var visibilityRevision: UUID

    init(api: APIClient, dataManager: SwiftDataManager? = nil) {
        self.api = api
        self.dataManager = dataManager ?? .shared
        context = api.session.snapshot
        snapshotGeneration = LocalSnapshot.generation
        visibilityRevision = self.dataManager.visibilityMutationRevision
    }

    func record(_ assets: [AssetResponseDTO]) {
        guard !Task.isCancelled,
              snapshotGeneration == LocalSnapshot.generation,
              visibilityRevision == dataManager.visibilityMutationRevision,
              (try? api.checkCurrent(context)) != nil else { return }
        // A failed durable release stays hidden. Other valid photos in the
        // response can still render through the latest visibility policy.
        try? dataManager.recordServerVisibility(assets)
        visibilityRevision = dataManager.visibilityMutationRevision
    }
}
