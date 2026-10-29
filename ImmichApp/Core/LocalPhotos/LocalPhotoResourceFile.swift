import Foundation
import Photos

enum LocalPhotoResourceFile {
    typealias Request = (
        Bool, @escaping @Sendable (Data) -> Void, @escaping @Sendable (Error?) -> Void
    ) -> PHAssetResourceDataRequestID

    static func export(
        filename: String, allowsNetworkFallback: Bool,
        directory: URL = FileManager.default.temporaryDirectory,
        request: Request,
        cancel: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void
    ) async -> URL? {
        for allowsNetwork in allowsNetworkFallback ? [false, true] : [false] {
            guard !Task.isCancelled else { return nil }
            let state: LocalPhotoResourceFileState
            do {
                state = try LocalPhotoResourceFileState(filename: filename, directory: directory, cancel: cancel)
            } catch { return nil }
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard state.begin(continuation) else { return }
                    let id = request(allowsNetwork, { state.append($0) }, { state.finish(error: $0) })
                    state.setRequestID(id)
                }
            } onCancel: {
                state.cancel()
            }
            guard !Task.isCancelled else {
                if let result { try? FileManager.default.removeItem(at: result) }
                return nil
            }
            if let result { return result }
        }
        return nil
    }
}

private final class LocalPhotoResourceFileState: @unchecked Sendable {
    private struct Completion {
        let continuation: CheckedContinuation<URL?, Never>?
        let requestID: PHAssetResourceDataRequestID?
        let succeeded: Bool
    }

    private let lock = NSLock()
    private let url: URL
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void
    private var output: FileHandle?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var completed = false
    private var needsCancellation = false

    init(
        filename: String, directory: URL,
        cancel: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void
    ) throws {
        let ext = URL(fileURLWithPath: filename).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        url = directory.appendingPathComponent("backup-source-\(UUID().uuidString)\(suffix)")
        cancelRequest = cancel
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { output = try FileHandle(forWritingTo: url) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func begin(_ continuation: CheckedContinuation<URL?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !completed else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        let mustCancel = lock.withLock {
            requestID = id
            return needsCancellation
        }
        // Cancellation can arrive before PhotoKit returns its request ID.
        if mustCancel { cancelRequest(id) }
    }

    func append(_ data: Data) {
        let completion: Completion? = lock.withLock {
            guard !completed else { return nil }
            do { try output?.write(contentsOf: data); return nil }
            catch { return completeLocked(succeeded: false, cancelRequest: true) }
        }
        complete(completion)
    }

    func finish(error: Error?) {
        complete(lock.withLock { completeLocked(succeeded: error == nil, cancelRequest: false) })
    }

    func cancel() {
        complete(lock.withLock { completeLocked(succeeded: false, cancelRequest: true) })
    }

    private func completeLocked(succeeded: Bool, cancelRequest: Bool) -> Completion? {
        guard !completed else { return nil }
        completed = true
        needsCancellation = cancelRequest
        var succeeded = succeeded
        do { try output?.close() } catch { succeeded = false }
        output = nil
        let result = Completion(continuation: continuation,
            requestID: cancelRequest ? requestID : nil, succeeded: succeeded)
        continuation = nil
        return result
    }

    private func complete(_ completion: Completion?) {
        guard let completion else { return }
        if let id = completion.requestID { cancelRequest(id) }
        if !completion.succeeded { try? FileManager.default.removeItem(at: url) }
        completion.continuation?.resume(returning: completion.succeeded ? url : nil)
    }
}
