import Foundation
import Observation

@MainActor
@Observable
final class MemoriesViewModel {
    private var loadedStories: [MemoryStory] = []
    var stories: [MemoryStory] {
        get {
            guard snapshotGeneration == LocalSnapshot.generation else { return [] }
            let policy = AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager)
            return loadedStories.compactMap { $0.filteringAssets(using: policy) }
        }
        set { loadedStories = newValue }
    }
    var phase: LoadingPhase<Void> = .idle

    private let snapshotGeneration = LocalSnapshot.generation
    private let repo: MemoriesRepository
    private let assetRepo: AssetDetailRepository
    private let dataManager: SwiftDataManager

    init(repo: MemoriesRepository, assetRepo: AssetDetailRepository, dataManager: SwiftDataManager? = nil) {
        self.repo = repo
        self.assetRepo = assetRepo
        self.dataManager = dataManager ?? .shared
    }

    func loadMemories() async {
        guard snapshotGeneration == LocalSnapshot.generation else { return }
        phase = .loading
        do {
            // Layar penuh, jadi tidak dipotong seperti baris di Library.
            let memories = try await repo.getMemories()
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
            stories = MemoryStory.build(from: memories, limit: .max)
            phase = .loaded(())
        } catch {
            guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation else { return }
            phase = .failed((error as? APIError)?.errorDescription
                ?? String(localized: "Failed to load memories"))
        }
    }

    func retry() async {
        await loadMemories()
    }

    /// Unduh berkas asli ke lokasi sementara untuk dibagikan lewat share sheet
    /// (URL server polos akan kena 401).
    func shareURL(for asset: AssetLite) async -> URL? {
        guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
              AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: asset.id) else { return nil }
        do {
            let url = try await assetRepo.shareFile(asset.id)
            guard snapshotGeneration == LocalSnapshot.generation, !Task.isCancelled,
                  AssetVisibilityPolicy(scope: .timeline, dataManager: dataManager).allows(id: asset.id) else {
                TemporaryMediaStore.remove(url)
                return nil
            }
            return url
        } catch {
            return nil
        }
    }
}
