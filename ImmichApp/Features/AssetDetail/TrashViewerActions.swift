import Foundation

@MainActor
struct TrashViewerActions {
    enum Mutation: Equatable { case restore, deletePermanently }

    let restore: @MainActor (String) async -> Bool
    let deletePermanently: @MainActor (String) async -> Bool
    let errorMessage: @MainActor () -> String?
    private let snapshotGeneration: UUID

    init(
        restore: @escaping @MainActor (String) async -> Bool,
        deletePermanently: @escaping @MainActor (String) async -> Bool,
        errorMessage: @escaping @MainActor () -> String? = { nil }
    ) {
        self.restore = restore
        self.deletePermanently = deletePermanently
        self.errorMessage = errorMessage
        snapshotGeneration = LocalSnapshot.generation
    }

    @discardableResult
    func perform(
        _ mutation: Mutation, target: AssetViewerState.Target, in viewer: AssetViewerState,
        onError: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (_ isPresented: Bool) -> Void
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, snapshotGeneration == LocalSnapshot.generation,
              viewer.isCurrent(target), let serverID = target.serverID else { return nil }
        let generation = snapshotGeneration
        return viewer.remove(target, operation: {
            guard !Task.isCancelled, generation == LocalSnapshot.generation else { return false }
            let accepted: Bool
            switch mutation {
            case .restore: accepted = await restore(serverID)
            case .deletePermanently: accepted = await deletePermanently(serverID)
            }
            guard !Task.isCancelled, generation == LocalSnapshot.generation else { return false }
            if !accepted, viewer.isCurrent(target) {
                onError(errorMessage() ?? (mutation == .restore
                    ? String(localized: "Failed to restore photos")
                    : String(localized: "Failed to delete photos")))
            }
            return accepted
        }, completion: completion)
    }
}
