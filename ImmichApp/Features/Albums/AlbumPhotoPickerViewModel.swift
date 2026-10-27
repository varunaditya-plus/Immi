import Foundation
import Observation

@MainActor
@Observable
final class AlbumPhotoPickerViewModel {
    private(set) var assets: [AssetLite] = []
    private(set) var phase: LoadingPhase<Void> = .idle

    private let repo: SearchRepository
    private let existingIDs: Set<String>

    init(repo: SearchRepository, existingIDs: Set<String>) {
        self.repo = repo
        self.existingIDs = existingIDs
    }

    func load() async {
        switch phase {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        phase = .loading
        do {
            let fetched = try await repo.allMetadata(SearchRequestDTO(order: "desc", size: 200))
            try Task.checkCancellation()
            assets = fetched.filter { !existingIDs.contains($0.id) }.map(AssetLite.init)
            phase = .loaded(())
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .idle
            } else {
                phase = .failed((error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to load photos"))
            }
        }
    }
}
