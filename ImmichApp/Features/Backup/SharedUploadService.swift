import Foundation

/// Mengambil alih file Share Extension yang belum selesai karena offline,
/// timeout, atau extension dihentikan sistem. Batch selalu terikat server dan
/// user id agar pergantian akun tidak pernah mengirim file memakai token baru.
@MainActor
final class SharedUploadService {
    static let shared = SharedUploadService()

    private var task: Task<Void, Never>?
    private var generation = UUID()

    private init() {}

    func processPending(session: SessionManager) {
        guard task == nil,
              session.isLoggedIn,
              let apiURL = session.baseURL,
              let userID = session.currentUser?.id
        else { return }

        let credential = SharedUploadCredential(
            apiURL: apiURL,
            owner: SharedUploadOwner(server: apiURL.absoluteString, userID: userID),
            authHeaders: session.authHeaders)

        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.task = nil }
            }
            do {
                let batches = try await SharedUploadStore.shared.batches(for: credential.owner)
                let client = SharedUploadClient(credential: credential)
                for var batch in batches {
                    guard !Task.isCancelled else { return }
                    await self.process(&batch, client: client)
                }
            } catch {
                // Inbox tetap utuh. Membuka app atau perubahan scene berikutnya
                // akan mencoba lagi tanpa mengubah state backup PhotoKit.
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func process(
        _ batch: inout SharedUploadBatch,
        client: SharedUploadClient
    ) async {
        for index in batch.items.indices {
            guard !Task.isCancelled else { return }
            batch.items[index].state = .uploading
            batch.items[index].lastError = nil
            try? await SharedUploadStore.shared.save(batch)

            do {
                let item = batch.items[index]
                let fileURL = try await SharedUploadStore.shared.fileURL(
                    for: item,
                    batchID: batch.id)
                let directory = try await SharedUploadStore.shared.makeBatchDirectory(id: batch.id)
                _ = try await client.upload(
                    item: item,
                    fileURL: fileURL,
                    bodyDirectory: directory)
                batch.items[index].state = .uploaded
                try? await SharedUploadStore.shared.removeFile(for: item, batchID: batch.id)
            } catch {
                batch.items[index].state = .queued
                batch.items[index].lastError = error.localizedDescription
                try? await SharedUploadStore.shared.save(batch)
                continue
            }
            try? await SharedUploadStore.shared.save(batch)
        }

        batch.items.removeAll { $0.state == .uploaded }
        if batch.items.isEmpty {
            try? await SharedUploadStore.shared.removeBatch(id: batch.id)
        } else {
            try? await SharedUploadStore.shared.save(batch)
        }
    }
}
