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
    private(set) var isCommitted = false
    private(set) var isProcessing = false
    private(set) var isClosing = false

    init(store: SharedUploadStore = .shared) {
        self.store = store
    }

    var canEdit: Bool { !isCommitted && !isProcessing && !isClosing }

    func begin() -> Bool {
        guard canEdit else { return false }
        isProcessing = true
        return true
    }

    func admit(owner: SharedUploadOwner, items: [SharedUploadItem]) async throws {
        guard isProcessing, !isCommitted, !isClosing else {
            throw SharedUploadSubmissionError.invalidState
        }
        let batch = SharedUploadBatch(id: batchID, owner: owner, createdAt: .now, items: items)
        try await store.save(batch)
        isCommitted = true
    }

    func finish() {
        isProcessing = false
    }

    func close() async throws -> Bool {
        guard !isProcessing, !isClosing else { return false }
        isClosing = true
        do {
            if !isCommitted { try await store.removeBatch(id: batchID) }
            return true
        } catch {
            isClosing = false
            throw error
        }
    }
}
