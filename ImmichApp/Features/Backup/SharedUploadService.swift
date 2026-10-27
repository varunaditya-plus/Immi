import Foundation

/// Mengambil alih file Share Extension yang belum selesai karena offline,
/// timeout, atau extension dihentikan sistem. Batch selalu terikat server dan
/// user id agar pergantian akun tidak pernah mengirim file memakai token baru.
@MainActor
final class SharedUploadService {
    static let shared = SharedUploadService()

    private var task: Task<Void, Never>?
    private var workID: UUID?

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

        let id = UUID()
        workID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workID == id {
                    self.task = nil
                    self.workID = nil
                }
            }
            do {
                let batches = try await SharedUploadStore.shared.batches(for: credential.owner)
                let client = SharedUploadClient(credential: credential)
                let processor = SharedUploadProcessor()
                for batch in batches {
                    guard !Task.isCancelled else { return }
                    do {
                        _ = try await processor.process(batchID: batch.id, owner: credential.owner, upload: {
                            item, fileURL, directory in
                            _ = try await client.upload(item: item, fileURL: fileURL, bodyDirectory: directory)
                        })
                    } catch {
                        // A failed checkpoint or cleanup leaves this batch on
                        // disk. Another batch can still make progress.
                        guard !Task.isCancelled else { return }
                    }
                }
            } catch {
                // Inbox tetap utuh. Membuka app atau perubahan scene berikutnya
                // akan mencoba lagi tanpa mengubah state backup PhotoKit.
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        workID = nil
    }
}
