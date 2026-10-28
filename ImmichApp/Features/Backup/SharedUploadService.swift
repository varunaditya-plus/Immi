import Foundation
import Observation

struct SharedUploadQueueItem: Identifiable, Equatable {
    let batchID: UUID
    let owner: SharedUploadOwner
    let item: SharedUploadItem
    var id: String { "\(batchID)/\(item.id)" }
}

enum SharedUploadActionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "This shared upload is busy or no longer available. Try again.")
    }
}

@MainActor
@Observable
final class SharedUploadService {
    static let shared = SharedUploadService()

    private(set) var items: [SharedUploadQueueItem] = []
    private(set) var lastError: String?
    private let store: SharedUploadStore
    private let upload: @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var listingID = UUID()
    @ObservationIgnored private var retryRequested = false

    init(
        store: SharedUploadStore = .shared,
        upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void = {
            credential, item, file, directory in
            _ = try await SharedUploadClient(credential: credential).upload(
                item: item, fileURL: file, bodyDirectory: directory)
        }
    ) {
        self.store = store
        self.upload = upload
    }

    @discardableResult
    func processPending(session: SessionManager) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        if let task { return task }
        let credential = credential(for: session)
        let context = session.snapshot
        lastError = nil
        let id = UUID()
        workID = id
        let work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workID == id {
                    self.task = nil
                    self.workID = nil
                    if self.retryRequested, !Task.isCancelled,
                       (try? session.checkCurrent(context)) != nil {
                        self.retryRequested = false
                        self.processPending(session: session)
                    }
                }
            }
            do {
                _ = try? await self.store.cleanupAbandonedDrafts()
                guard let credential else { return }
                let batches = try await self.store.batches(for: credential.owner)
                try session.checkCurrent(context)
                await self.refreshPending(session: session)
                let processor = SharedUploadProcessor(store: self.store)
                for batch in batches {
                    try Task.checkCancellation()
                    try session.checkCurrent(context)
                    do {
                        _ = try await processor.process(batchID: batch.id, owner: credential.owner, upload: {
                            item, fileURL, directory in
                            try session.checkCurrent(context)
                            await self.refreshPending(session: session)
                            try Task.checkCancellation()
                            try session.checkCurrent(context)
                            try await self.upload(credential, item, fileURL, directory)
                        })
                    } catch {
                        try Task.checkCancellation()
                        try session.checkCurrent(context)
                        self.lastError = error.localizedDescription
                    }
                    await self.refreshPending(session: session)
                }
            } catch {
                guard !Task.isCancelled, self.workID == id,
                      (try? session.checkCurrent(context)) != nil else { return }
                self.lastError = error.localizedDescription
            }
        }
        task = work
        return work
    }

    func refreshPending(session: SessionManager) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        listingID = id
        guard let credential = credential(for: session) else {
            items = []
            lastError = nil
            return
        }
        let context = session.snapshot
        do {
            let batches = try await store.batches(for: credential.owner)
            try session.checkCurrent(context)
            guard !Task.isCancelled, listingID == id else { return }
            items = batches.flatMap { batch in
                batch.items.filter { !$0.state.isFinished }.map {
                    SharedUploadQueueItem(batchID: batch.id, owner: batch.owner, item: $0)
                }
            }
        } catch {
            guard !Task.isCancelled, listingID == id,
                  (try? session.checkCurrent(context)) != nil else { return }
            lastError = error.localizedDescription
        }
    }

    func retry(_ entry: SharedUploadQueueItem, session: SessionManager) async throws {
        let context = try validate(entry, session: session)
        guard try await store.retryFailedItem(id: entry.item.id, batchID: entry.batchID, owner: entry.owner) else {
            throw SharedUploadActionError.unavailable
        }
        try session.checkCurrent(context)
        await refreshPending(session: session)
        try Task.checkCancellation()
        try session.checkCurrent(context)
        retryRequested = task != nil
        processPending(session: session)
    }

    func remove(_ entry: SharedUploadQueueItem, session: SessionManager) async throws {
        let context = try validate(entry, session: session)
        do {
            guard try await store.discardFailedItem(id: entry.item.id, batchID: entry.batchID, owner: entry.owner) else {
                throw SharedUploadActionError.unavailable
            }
        } catch {
            await refreshPending(session: session)
            throw error
        }
        try session.checkCurrent(context)
        await refreshPending(session: session)
    }

    func cancel() {
        task?.cancel()
        task = nil
        workID = nil
        listingID = UUID()
        retryRequested = false
        items = []
        lastError = nil
    }

    private func credential(for session: SessionManager) -> SharedUploadCredential? {
        guard session.isLoggedIn, let apiURL = session.baseURL,
              let owner = session.backupQueueOwner else { return nil }
        return SharedUploadCredential(apiURL: apiURL,
            owner: SharedUploadOwner(server: owner.server, userID: owner.userID),
            authHeaders: session.authHeaders)
    }

    private func validate(_ entry: SharedUploadQueueItem, session: SessionManager) throws -> SessionRequestContext {
        try Task.checkCancellation()
        guard credential(for: session)?.owner == entry.owner else { throw CancellationError() }
        return session.snapshot
    }
}
