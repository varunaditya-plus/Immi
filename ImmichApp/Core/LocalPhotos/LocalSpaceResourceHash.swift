import CryptoKit
import Foundation
import Photos

enum LocalSpaceResourceHash {
    static func checksum(_ resource: PHAssetResource) async -> String? {
        let manager = PHAssetResourceManager.default()
        let state = LocalSpaceChecksumState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = false
                let id = manager.requestData(for: resource, options: options,
                    dataReceivedHandler: { state.append($0) },
                    completionHandler: { state.finish(error: $0) })
                state.setRequestID(id, manager: manager)
            }
        } onCancel: {
            state.cancel(manager: manager)
        }
    }
}

/// PhotoKit callbacks and task cancellation can race. Only the first terminal
/// event resumes the continuation, and chunks are hashed without retaining them.
final class LocalSpaceChecksumState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = Insecure.SHA1()
    private var byteCount = 0
    private var continuation: CheckedContinuation<String?, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var completed = false
    private var cancelled = false

    func begin(_ continuation: CheckedContinuation<String?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !completed else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }

    func append(_ chunk: Data) {
        lock.withLock {
            guard !completed else { return }
            hasher.update(data: chunk)
            byteCount += chunk.count
        }
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID, manager: PHAssetResourceManager) {
        let mustCancel = lock.withLock {
            requestID = id
            return cancelled
        }
        if mustCancel { manager.cancelDataRequest(id) }
    }

    func finish(error: Error?) {
        let result: (CheckedContinuation<String?, Never>?, String?) = lock.withLock {
            guard !completed else { return (nil, nil) }
            completed = true
            let checksum = error == nil && byteCount > 0
                ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
            let continuation = continuation
            self.continuation = nil
            return (continuation, checksum)
        }
        result.0?.resume(returning: result.1)
    }

    func cancel(manager: PHAssetResourceManager = .default()) {
        let result: (CheckedContinuation<String?, Never>?, PHAssetResourceDataRequestID?) = lock.withLock {
            guard !completed else { return (nil, nil) }
            completed = true
            cancelled = true
            let continuation = continuation
            self.continuation = nil
            return (continuation, requestID)
        }
        result.0?.resume(returning: nil)
        if let id = result.1 { manager.cancelDataRequest(id) }
    }
}

final class LocalSpaceDeletionTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var ids: Set<String>?

    var isCancelled: Bool { lock.withLock { cancelled } }
    var authorizedIDs: Set<String>? { lock.withLock { ids } }

    func authorize(_ ids: Set<String>, changes: () -> Void) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.ids = ids
            changes()
            return true
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
