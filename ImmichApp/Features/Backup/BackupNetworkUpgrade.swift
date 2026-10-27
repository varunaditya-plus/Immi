import Foundation

/// The task boundary permits cancellation tests without starting a system upload.
protocol BackupNetworkUpgradeTask: AnyObject {
    var taskIdentifier: Int { get }
    var state: URLSessionTask.State { get }
    var originalRequest: URLRequest? { get }
    var currentRequest: URLRequest? { get }
    var taskDescription: String? { get set }
    func cancel()
}

extension URLSessionTask: BackupNetworkUpgradeTask {}

@MainActor
enum BackupNetworkUpgrade {
    /// A submitted request cannot gain cellular permission in place. Reuse the
    /// existing storage-recovery cancellation marker and its task-ID-checked
    /// completion path, which requeues only after URLSession releases the task.
    static func requeue(
        tasks: [any BackupNetworkUpgradeTask],
        eligibleIDs: Set<String>,
        availableOriginalIDs: Set<String>,
        queue: BackupQueueStore
    ) {
        for task in tasks {
            guard task.state == .running || task.state == .suspended,
                  var context = BackupUploadTaskContext.decode(task.taskDescription),
                  context.ownership == queue.ownership,
                  eligibleIDs.contains(context.localIdentifier),
                  availableOriginalIDs.contains(context.localIdentifier),
                  context.isStorageRecovery != true,
                  let item = queue.item(id: context.localIdentifier),
                  item.state == .uploading,
                  item.taskIdentifier == task.taskIdentifier,
                  let request = task.currentRequest ?? task.originalRequest,
                  !request.allowsCellularAccess || !request.allowsExpensiveNetworkAccess
            else { continue }

            // Keep the body until the cancellation callback. If Photos access
            // disappears before then, existing cleanup preserves that copy.
            context.isStorageRecovery = true
            task.taskDescription = context.encoded
            task.cancel()
        }
    }
}
