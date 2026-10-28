import Foundation
import Observation

@MainActor
@Observable
final class SharePreparation {
    private(set) var isPreparing = false
    private var request = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        ids: [String],
        prepare: @escaping @MainActor ([String]) async -> [URL],
        isAllowed: @escaping @MainActor (String) -> Bool,
        onError: @escaping @MainActor (String) -> Void,
        onReady: @escaping @MainActor ([URL]) -> Void
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, !isPreparing, !ids.isEmpty, ids.allSatisfy(isAllowed) else { return nil }
        let generation = LocalSnapshot.generation
        let token = UUID()
        request = token
        isPreparing = true
        let operation = Task {
            defer {
                if request == token {
                    isPreparing = false
                    task = nil
                }
            }
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation,
                  ids.allSatisfy(isAllowed) else { return }
            let urls = await prepare(ids)
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation,
                  ids.allSatisfy(isAllowed) else {
                TemporaryMediaStore.remove(urls)
                return
            }
            guard !urls.isEmpty else {
                onError(String(localized: "Failed to prepare share"))
                return
            }
            onReady(urls)
        }
        task = operation
        return operation
    }

    func cancel() {
        request = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
    }
}
