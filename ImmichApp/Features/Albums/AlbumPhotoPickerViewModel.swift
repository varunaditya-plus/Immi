import Foundation
import Observation

@MainActor
@Observable
final class AlbumPhotoPickerViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var loadedAssets: [AssetLite] = []
    var assets: [AssetLite] {
        guard snapshotGeneration == LocalSnapshot.generation else { return [] }
        return AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).filter(loadedAssets)
    }
    private(set) var phase: LoadingPhase<Void> = .idle

    private let repo: SearchRepository
    private let existingIDs: Set<String>
    private let dataManager: SwiftDataManager

    init(repo: SearchRepository, existingIDs: Set<String>, dataManager: SwiftDataManager? = nil) {
        self.repo = repo
        self.existingIDs = existingIDs
        self.dataManager = dataManager ?? .shared
    }

    func load() async {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
        switch phase {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        phase = .loading
        do {
            let fetched = try await repo.allMetadata(SearchRequestDTO(order: "desc", size: 200))
            try Task.checkCancellation()
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            loadedAssets = fetched.filter { $0.isTimelineVisible && !existingIDs.contains($0.id) }.map(AssetLite.init)
            phase = .loaded(())
        } catch {
            guard snapshotGeneration == LocalSnapshot.generation else { return }
            if Task.isCancelled || error is CancellationError {
                phase = .idle
            } else {
                phase = .failed((error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to load photos"))
            }
        }
    }
}
