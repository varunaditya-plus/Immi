import Foundation
import Observation

@MainActor
@Observable
final class PhotoMapViewModel {
    private let snapshotGeneration = LocalSnapshot.generation
    private var requestID = UUID()
    private var hasSnapshot: Bool
    private(set) var markers: [MapMarkerDTO]
    private(set) var isLoading: Bool
    private(set) var loadError: String?

    var isCurrentAccount: Bool { snapshotGeneration == LocalSnapshot.generation }

    init() {
        let cached = LocalSnapshot.load([MapMarkerDTO].self, for: LocalSnapshot.Key.places)
        markers = cached ?? []
        hasSnapshot = cached != nil
        isLoading = cached == nil
    }

    func load(using fetch: @MainActor () async throws -> [MapMarkerDTO]) async {
        guard !Task.isCancelled, isCurrentAccount else { return }
        let request = UUID()
        requestID = request
        loadError = nil
        isLoading = !hasSnapshot
        defer {
            if requestID == request, isCurrentAccount { isLoading = false }
        }
        do {
            let fetched = try await fetch()
            guard !Task.isCancelled, isCurrentAccount, requestID == request else { return }
            LocalSnapshot.save(fetched, for: LocalSnapshot.Key.places, expectedGeneration: snapshotGeneration)
            if markers != fetched { markers = fetched }
            hasSnapshot = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  isCurrentAccount, requestID == request else { return }
            if !hasSnapshot {
                loadError = (error as? APIError)?.errorDescription
                    ?? String(localized: "Failed to load places")
            }
        }
    }
}
