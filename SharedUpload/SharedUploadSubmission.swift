import Foundation

enum SharedUploadSubmissionError: Error {
    case invalidState
}

/// Owns the extension's draft until its manifest is durable. Closing after
/// admission leaves recovery work and its source files in the shared inbox.
@MainActor
final class SharedUploadSubmission {
    let batchID = UUID()
    private let store: SharedUploadStore
    private var draftClaim: SharedUploadBatchClaim?
    private(set) var isCommitted = false
    private(set) var isProcessing = false
    private(set) var isClosing = false

    init(store: SharedUploadStore = .shared) {
        self.store = store
    }

    var canEdit: Bool { !isCommitted && !isProcessing && !isClosing }

    func prepareDraft() async throws -> URL {
        guard canEdit, draftClaim == nil else { throw SharedUploadSubmissionError.invalidState }
        isProcessing = true
        defer { isProcessing = false }
        try Task.checkCancellation()
        let draft = try await store.makeDraftDirectory(id: batchID)
        draftClaim = draft.claim
        try Task.checkCancellation()
        return draft.directory
    }

    func begin() -> Bool {
        guard canEdit else { return false }
        isProcessing = true
        return true
    }

    func admit(owner: SharedUploadOwner, items: [SharedUploadItem]) async throws {
        guard isProcessing, !isCommitted, !isClosing, draftClaim != nil else {
            throw SharedUploadSubmissionError.invalidState
        }
        let batch = SharedUploadBatch(id: batchID, owner: owner, createdAt: .now, items: items)
        try await store.save(batch)
        isCommitted = true
        // Keep the draft claim through cleanup; recovery retries a failed cleanup.
        try? await store.removeUnreferencedFiles(in: batch)
        draftClaim = nil
    }

    func finish() {
        isProcessing = false
    }

    func close() async throws -> Bool {
        guard !isProcessing, !isClosing else { return false }
        isClosing = true
        do {
            if !isCommitted { try await store.removeBatch(id: batchID) }
            draftClaim = nil
            return true
        } catch {
            isClosing = false
            throw error
        }
    }
}
