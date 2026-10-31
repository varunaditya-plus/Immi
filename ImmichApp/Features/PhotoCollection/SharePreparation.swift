import Foundation
import Observation

@MainActor
@Observable
final class SharePreparation {
    private(set) var isPreparing = false
    private(set) var preparedSourceIDs: [String] = []
    private(set) var preparedContext: SessionRequestContext?
    private var request = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        ids: [String],
        session: SessionManager? = nil,
        prepare: @escaping @MainActor ([String]) async -> [URL],
        isAllowed: @escaping @MainActor (String) -> Bool,
        onError: @escaping @MainActor (String) -> Void,
        onReady: @escaping @MainActor ([URL]) -> Void
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, !isPreparing, !ids.isEmpty, ids.allSatisfy(isAllowed) else { return nil }
        let generation = LocalSnapshot.generation
        let context = session?.snapshot
        let sourceIDs = AssetServerIdentity.exportIDs(for: ids)
        let token = UUID()
        request = token
        preparedSourceIDs = []
        preparedContext = nil
        isPreparing = true
        let operation = Task {
            defer {
                if request == token {
                    isPreparing = false
                    task = nil
                }
            }
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation, session?.snapshot == context,
                  AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                  ids.allSatisfy(isAllowed) else { return }
            let urls = await prepare(ids)
            guard !Task.isCancelled, request == token, generation == LocalSnapshot.generation, session?.snapshot == context,
                  AssetServerIdentity.exportIDs(for: ids) == sourceIDs,
                  ids.allSatisfy(isAllowed) else {
                TemporaryMediaStore.remove(urls)
                return
            }
            guard !urls.isEmpty else {
                onError(String(localized: "Failed to prepare share"))
                return
            }
            preparedSourceIDs = sourceIDs
            preparedContext = context
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
        preparedSourceIDs = []
        preparedContext = nil
    }
}
