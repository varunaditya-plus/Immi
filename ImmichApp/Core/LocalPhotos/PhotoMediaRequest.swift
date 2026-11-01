import Foundation
import Photos
import UIKit

/// PhotoKit may finish synchronously, report more than once, or return its ID after cancellation.
enum PhotoMediaRequest {
    static func image(
        request: (@escaping (UIImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID,
        cancel: @escaping @Sendable (PHImageRequestID) -> Void
    ) async -> UIImage? {
        await load(request: { completion in
            request { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                completion(image)
            }
        }, cancel: cancel)
    }

    static func load<Value>(
        request: (@escaping (Value?) -> Void) -> PHImageRequestID,
        cancel: @escaping @Sendable (PHImageRequestID) -> Void
    ) async -> Value? {
        let state = PhotoMediaRequestState<Value>(cancel: cancel)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.begin(continuation) else { return }
                state.setRequestID(request { state.finish($0) })
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class PhotoMediaRequestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void
    private var continuation: CheckedContinuation<Value?, Never>?
    private var requestID: PHImageRequestID?
    private var finished = false
    private var needsCancellation = false

    init(cancel: @escaping @Sendable (PHImageRequestID) -> Void) { cancelRequest = cancel }

    func begin(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !finished else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }

    func setRequestID(_ id: PHImageRequestID) {
        let shouldCancel = lock.withLock { requestID = id; return needsCancellation }
        if shouldCancel { cancelRequest(id) }
    }

    func finish(_ value: Value?) { complete(value, cancelling: false) }
    func cancel() { complete(nil, cancelling: true) }

    private func complete(_ value: Value?, cancelling: Bool) {
        let completion: (CheckedContinuation<Value?, Never>?, PHImageRequestID?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            needsCancellation = cancelling
            let result = (continuation, cancelling ? requestID : nil)
            continuation = nil
            return result
        }
        guard let completion else { return }
        if let id = completion.1 { cancelRequest(id) }
        completion.0?.resume(returning: value)
    }
}
