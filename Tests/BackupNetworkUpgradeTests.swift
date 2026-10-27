import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupNetworkUpgradeTests: XCTestCase {
    func testUploadRequestAppliesCellularPermissionPerTransferAndKeepsLowDataMode() {
        var original = URLRequest(url: URL(string: "https://network-upgrade.example/api/assets")!)
        original.allowsConstrainedNetworkAccess = true
        for allowed in [false, true] {
            let request = BackupUploader.uploadRequest(original, allowsCellular: allowed)
            XCTAssertEqual(request.allowsCellularAccess, allowed)
            XCTAssertEqual(request.allowsExpensiveNetworkAccess, allowed)
            XCTAssertFalse(request.allowsConstrainedNetworkAccess)
        }
        XCTAssertTrue(original.allowsConstrainedNetworkAccess, "Configuring a transfer must not alter the reusable input request")
    }

    func testOnlySelectedBlockedTransfersAreMarkedBeforeCancellation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let selected = try fixture.task("selected", identifier: 1)
        let unrelated = try fixture.task("unrelated", identifier: 2)
        let permitted = try fixture.task("already-permitted", identifier: 3, cellular: true, expensive: true)
        let original = try XCTUnwrap(fixture.queue.item(id: "selected"))

        BackupNetworkUpgrade.requeue(tasks: [selected, unrelated, permitted],
            eligibleIDs: ["selected", "already-permitted"],
            availableOriginalIDs: ["selected", "unrelated", "already-permitted"], queue: fixture.queue)

        XCTAssertEqual(selected.cancelledContexts.count, 1)
        XCTAssertEqual(selected.cancelledContexts.first?.isStorageRecovery, true,
            "The persisted task description must be marked before cancellation can finish")
        XCTAssertEqual(selected.cancelledContexts.first?.localIdentifier, "selected")
        XCTAssertTrue(unrelated.cancelledContexts.isEmpty)
        XCTAssertTrue(permitted.cancelledContexts.isEmpty)
        XCTAssertEqual(fixture.queue.item(id: "selected"), original,
            "The queue cannot release its staging slot until the old task's callback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.body.path))
    }

    func testCancellationRequeuesBothLivePhotoPhasesAndPreservesManualIntent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for (index, phase) in [BackupUploadPhase.livePhotoMotion, .primaryAsset].enumerated() {
            let id = "live-\(phase.rawValue)"
            let task = try fixture.task(id, identifier: 10 + index, phase: phase,
                motionID: phase == .primaryAsset ? "server-motion" : nil)

            BackupNetworkUpgrade.requeue(tasks: [task], eligibleIDs: [id], availableOriginalIDs: [id], queue: fixture.queue)

            let context = try XCTUnwrap(task.cancelledContexts.first)
            XCTAssertEqual(context.phase, phase)
            XCTAssertEqual(context.checksum, "checksum-\(id)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.body.path))
            // This is the existing production cancellation completion path.
            // The source was checked before cancellation, so cleanup may release
            // its staged body only after the old URLSession task acknowledges it.
            XCTAssertFalse(try BackupTemporaryFiles.finish(context, succeeded: false,
                sourceAvailable: true, in: fixture.directory))
            XCTAssertTrue(try fixture.queue.requeueAfterStorageRecovery(id, taskIdentifier: task.taskIdentifier,
                now: fixture.now.addingTimeInterval(10)))
            let reopened = BackupQueueStore(fileURL: fixture.queueURL)
            let item = try XCTUnwrap(reopened.item(id: id))
            XCTAssertEqual(item.state, .queued)
            XCTAssertEqual(item.phase, phase)
            XCTAssertEqual(item.motionAssetID, phase == .primaryAsset ? "server-motion" : nil)
            XCTAssertEqual(item.intent, .manualUpload)
            XCTAssertTrue(item.allowsCellularOverride)
            XCTAssertEqual(item.attemptCount, 1)
            XCTAssertEqual(item.checksum, context.checksum)
            XCTAssertNil(item.taskIdentifier)
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.body.path))

            try fixture.queue.markPreparing(id, phase: phase, motionAssetID: item.motionAssetID, now: fixture.now)
            try fixture.queue.markUploading(id, phase: phase, checksum: context.checksum,
                taskIdentifier: 100 + index, now: fixture.now)
            XCTAssertFalse(try fixture.queue.requeueAfterStorageRecovery(id, taskIdentifier: task.taskIdentifier))
            XCTAssertEqual(fixture.queue.item(id: id)?.taskIdentifier, 100 + index,
                "A late cancellation callback cannot reset its replacement transfer")
        }
    }

    func testCancellingStaleAndCompletedTasksAreNotCancelledAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cancelling = try fixture.task("cancelling", identifier: 1)
        try fixture.queue.markCancelling("cancelling", now: fixture.now)
        let stale = try fixture.task("stale", identifier: 2)
        XCTAssertTrue(try fixture.queue.requeueAfterStorageRecovery("stale", taskIdentifier: 2, now: fixture.now))
        try fixture.queue.markPreparing("stale", phase: .primaryAsset, now: fixture.now)
        try fixture.queue.markUploading("stale", phase: .primaryAsset, checksum: "new", taskIdentifier: 3, now: fixture.now)
        let completed = try fixture.task("completed", identifier: 4)
        completed.simulatedState = .completed
        let cancellingTask = try fixture.task("system-cancelling", identifier: 5)
        cancellingTask.simulatedState = .canceling
        let tasks = [cancelling, stale, completed, cancellingTask]
        let ids = Set(tasks.compactMap { BackupUploadTaskContext.decode($0.taskDescription)?.localIdentifier })

        BackupNetworkUpgrade.requeue(tasks: tasks, eligibleIDs: ids, availableOriginalIDs: ids, queue: fixture.queue)

        XCTAssertTrue(tasks.allSatisfy { $0.cancelledContexts.isEmpty })
        XCTAssertEqual(fixture.queue.item(id: "cancelling")?.state, .cancelling)
        XCTAssertEqual(fixture.queue.item(id: "stale")?.taskIdentifier, 3)
        XCTAssertTrue(tasks.allSatisfy { FileManager.default.fileExists(atPath: $0.body.path) })
    }

    func testMissingOriginalProtectsItsStagedOnlyCopyAndReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let protected = try fixture.task("only-copy", identifier: 1)
        let before = try Data(contentsOf: protected.body)
        let receipt = protected.body.appendingPathExtension("json")
        let receiptBefore = try Data(contentsOf: receipt)

        BackupNetworkUpgrade.requeue(tasks: [protected], eligibleIDs: ["only-copy"],
            availableOriginalIDs: [], queue: fixture.queue)

        XCTAssertTrue(protected.cancelledContexts.isEmpty)
        XCTAssertNil(BackupUploadTaskContext.decode(protected.taskDescription)?.isStorageRecovery)
        XCTAssertEqual(try Data(contentsOf: protected.body), before)
        XCTAssertEqual(try Data(contentsOf: receipt), receiptBefore)
        XCTAssertEqual(fixture.queue.item(id: "only-copy")?.state, .uploading)
    }

    func testRepeatedUpgradeUsesPersistedMarkerAndDoesNotDuplicateCancellation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try fixture.task("once", identifier: 1)
        // Leave its simulated state running after cancel to prove that the
        // serialized marker, rather than an assumed immediate state change,
        // prevents a second cancellation during overlapping wakeups.
        for _ in 0..<2 {
            BackupNetworkUpgrade.requeue(tasks: [task], eligibleIDs: ["once"],
                availableOriginalIDs: ["once"], queue: fixture.queue)
        }

        XCTAssertEqual(task.cancelledContexts.count, 1)
        let persisted = try XCTUnwrap(BackupUploadTaskContext.decode(task.taskDescription))
        XCTAssertEqual(persisted.isStorageRecovery, true)
        XCTAssertEqual(BackupUploadTaskContext.decode(persisted.encoded), persisted)
        XCTAssertEqual(fixture.queue.snapshot.active, 1)
    }

    func testExpensiveAccessCanUpgradeWithoutOverridingLowDataMode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = try fixture.task("expensive", identifier: 1, cellular: true, expensive: false)
        task.simulatedState = .suspended

        BackupNetworkUpgrade.requeue(tasks: [task], eligibleIDs: ["expensive"],
            availableOriginalIDs: ["expensive"], queue: fixture.queue)

        XCTAssertEqual(task.cancelledContexts.count, 1)
        XCTAssertEqual(task.currentRequest?.allowsConstrainedNetworkAccess, false)
        XCTAssertEqual(task.currentRequest?.allowsCellularAccess, true)
        XCTAssertEqual(task.currentRequest?.allowsExpensiveNetworkAccess, false,
            "The old request stays immutable; its replacement receives the new policy")
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let queueURL: URL
        let queue: BackupQueueStore
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-upgrade-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            queueURL = directory.appendingPathComponent("queue.json")
            queue = BackupQueueStore(fileURL: queueURL)
        }

        func task(_ id: String, identifier: Int, phase: BackupUploadPhase = .primaryAsset,
                  motionID: String? = nil, cellular: Bool = false, expensive: Bool = false) throws -> ControlledTask {
            try queue.enqueue([id], intent: .manualUpload, now: now)
            try queue.markPreparing(id, phase: phase, motionAssetID: motionID, now: now)
            try queue.markUploading(id, phase: phase, checksum: "checksum-\(id)", taskIdentifier: identifier, now: now)
            let body = directory.appendingPathComponent("upload-\(id).multipart")
            try Data("original-\(id)".utf8).write(to: body)
            let context = BackupUploadTaskContext(phase: phase, localIdentifier: id,
                checksum: "checksum-\(id)", bodyPath: body.path)
            try BackupTemporaryFiles.record(context, in: directory)
            var request = URLRequest(url: URL(string: "https://network-upgrade.example/api/assets")!)
            request.allowsCellularAccess = cellular
            request.allowsExpensiveNetworkAccess = expensive
            request.allowsConstrainedNetworkAccess = false
            return ControlledTask(identifier: identifier, request: request, context: context, body: body)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class ControlledTask: BackupNetworkUpgradeTask {
    let taskIdentifier: Int
    let originalRequest: URLRequest?
    let currentRequest: URLRequest?
    var taskDescription: String?
    let body: URL
    var simulatedState: URLSessionTask.State = .running
    var state: URLSessionTask.State { simulatedState }
    private(set) var cancelledContexts: [BackupUploadTaskContext] = []

    init(identifier: Int, request: URLRequest, context: BackupUploadTaskContext, body: URL) {
        taskIdentifier = identifier
        originalRequest = request
        currentRequest = request
        taskDescription = context.encoded
        self.body = body
    }

    func cancel() {
        if let context = BackupUploadTaskContext.decode(taskDescription) {
            cancelledContexts.append(context)
        }
    }
}
