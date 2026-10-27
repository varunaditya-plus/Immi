import Foundation

/// Runs the same durable recovery path in the app and both upload extensions.
@MainActor
final class SharedUploadProcessor {
    enum Outcome: Equatable {
        case busy
        case finished(remaining: Int)
    }

    private let store: SharedUploadStore

    init(store: SharedUploadStore = .shared) {
        self.store = store
    }

    func process(
        batchID: UUID,
        owner: SharedUploadOwner,
        upload: @MainActor (SharedUploadItem, URL, URL) async throws -> Void,
        progress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> Outcome {
        try Task.checkCancellation()
        guard let claim = try await store.claimBatch(id: batchID) else {
            return try await store.existingBatchDirectory(id: batchID) == nil
                ? .finished(remaining: 0) : .busy
        }
        defer { withExtendedLifetime(claim) {} }
        try Task.checkCancellation()
        guard var batch = try await store.batch(id: batchID, owner: owner) else {
            return .finished(remaining: 0)
        }
        let total = batch.items.count { $0.state != .uploaded }
        var current = 0
        var cleanupError: Error?

        for index in batch.items.indices {
            try Task.checkCancellation()
            if batch.items[index].state == .uploaded {
                do { try await store.removeFile(for: batch.items[index], batchID: batchID) }
                catch { cleanupError = cleanupError ?? error }
                continue
            }

            batch.items[index].state = .uploading
            batch.items[index].lastError = nil
            try await store.save(batch)
            try Task.checkCancellation()
            current += 1
            progress(current, total)

            do {
                let item = batch.items[index]
                let fileURL = try await store.fileURL(for: item, batchID: batchID)
                guard let directory = try await store.existingBatchDirectory(id: batchID) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try Task.checkCancellation()
                try await upload(item, fileURL, directory)
            } catch {
                batch.items[index].state = .queued
                batch.items[index].lastError = error.localizedDescription
                try await store.save(batch)
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                continue
            }

            // Even if cancellation arrived with an accepted response, save that
            // success before cleanup. A failed checkpoint keeps the source.
            batch.items[index].state = .uploaded
            try await store.save(batch)
            do { try await store.removeFile(for: batch.items[index], batchID: batchID) }
            catch { cleanupError = cleanupError ?? error }
        }

        if let cleanupError { throw cleanupError }
        let remaining = batch.items.count { $0.state != .uploaded }
        if remaining == 0 {
            // Keep completed rows until this final removal. If cleanup is
            // interrupted, recovery only cleans them and never uploads again.
            try await store.removeBatch(id: batchID)
        }
        return .finished(remaining: remaining)
    }
}
