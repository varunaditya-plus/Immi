import Foundation

/// Keeps a bounded window of runnable metadata ahead of upload preparation.
/// The service owns the task; this loop also advances when preparation finishes
/// synchronously without creating a URLSession transfer.
@MainActor
final class AutomaticBackupDiscovery {
    private let queue: BackupQueueStore
    private let batchSize: Int
    private var seenIDs: Set<String> = []
    private var batchStarted = false
    private var cycle = UUID()

    init(queue: BackupQueueStore, batchSize: Int = 100) {
        precondition(batchSize > 0)
        self.queue = queue
        self.batchSize = batchSize
    }

    func beginCycle() {
        cycle = UUID()
        seenIDs.removeAll()
        batchStarted = false
    }

    func hasCandidates(
        photos: [LocalPhoto], uploadedIDs: Set<String>, activeIDs: Set<String> = []
    ) -> Bool {
        let excluded = Set(queue.items.map(\.id)).union(seenIDs).union(uploadedIDs).union(activeIDs)
        return photos.contains { !excluded.contains($0.id) }
    }

    func run(
        photos: @MainActor () -> [LocalPhoto],
        uploadedIDs: @MainActor () -> Set<String>,
        activeIDs: @MainActor () async -> Set<String>,
        shouldContinue: @MainActor () -> Bool,
        processReady: @MainActor () async -> Void
    ) async throws {
        let admittedCycle = cycle
        while !Task.isCancelled, cycle == admittedCycle, shouldContinue() {
            let active = await activeIDs()
            guard !Task.isCancelled, cycle == admittedCycle, shouldContinue() else { return }

            // Failed and future-waiting entries remain tracked, but cannot
            // consume the window needed by older photos that can upload now.
            let readyCount = queue.readyItems(limit: batchSize).count
            // Drain the current metadata window before scanning the library
            // again; a completion usually only needs to stage the next item.
            let available = readyCount == 0 ? max(0, batchSize - queue.snapshot.active) : 0
            let known = Set(queue.items.map(\.id))
            seenIDs.formUnion(known)
            var candidates: [String] = []
            if available > 0 {
                let excluded = seenIDs.union(uploadedIDs()).union(active)
                candidates = photos()
                    .filter { !excluded.contains($0.id) }
                    .sorted { lhs, rhs in
                        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt > rhs.createdAt
                    }
                    .prefix(available)
                    .map(\.id)
            }

            if !candidates.isEmpty {
                try queue.enqueue(candidates, continuingBatch: batchStarted || !known.isEmpty)
                seenIDs.formUnion(candidates)
            }
            batchStarted = batchStarted || !queue.items.isEmpty

            guard !queue.readyItems(limit: 1).isEmpty else { return }
            let before = queue.items
            await processReady()
            guard !Task.isCancelled, cycle == admittedCycle, shouldContinue(),
                  queue.items != before else { return }

            let hasReady = !queue.readyItems(limit: 1).isEmpty
            let hasReadyCapacity = queue.snapshot.active < BackupStagingPolicy.maximumActiveUploads
                && hasReady
            let canDiscover = !hasReady && queue.snapshot.active < batchSize
                && hasCandidates(photos: photos(), uploadedIDs: uploadedIDs(), activeIDs: active)
            guard hasReadyCapacity || canDiscover
            else { return }
            await Task.yield()
        }
    }
}
