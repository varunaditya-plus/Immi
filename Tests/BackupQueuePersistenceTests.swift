import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupQueuePersistenceTests: XCTestCase {
    private var directories: [URL] = []
    private let initial = Date(timeIntervalSince1970: 100)
    private let changed = Date(timeIntervalSince1970: 200)
    private let owner = BackupQueueOwner(server: "https://backup.example/api", userID: "first")

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testInitialBindingCannotPublishAnUnsavedOwnerOrGeneration() throws {
        let fixture = try fixture()

        try assertFailedWriteCanBeRetried(fixture) {
            let replaced = try fixture.queue.bind(to: owner)
            XCTAssertFalse(replaced)
        }

        XCTAssertEqual(fixture.queue.owner, owner)
        XCTAssertNotNil(fixture.queue.ownership?.generation)
    }

    func testReplacementBindingCannotLoseThePreviousOwnersQueueOnFailure() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["pending"], intent: .manualUpload, now: initial)
        let previous = try XCTUnwrap(fixture.queue.ownership)
        let replacement = BackupQueueOwner(server: owner.server, userID: "second")

        try assertFailedWriteCanBeRetried(fixture) {
            let replaced = try fixture.queue.bind(to: replacement)
            XCTAssertTrue(replaced)
        }

        XCTAssertEqual(fixture.queue.owner, replacement)
        XCTAssertNotEqual(fixture.queue.ownership?.generation, previous.generation)
        XCTAssertTrue(fixture.queue.items.isEmpty)
        XCTAssertEqual(fixture.queue.snapshot.total, 0)
    }

    func testLegacyBindingCannotPublishAnUnsavedGenerationOrDropPendingWork() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["pending"], now: initial)
        let original = fixture.queue.items
        try fixture.removeLedgerField("generation")
        let legacy = fixture.reopen()
        XCTAssertNil(legacy.ownership)

        try assertFailedWriteCanBeRetried(fixture, queue: legacy) {
            let replaced = try legacy.bind(to: owner)
            XCTAssertFalse(replaced)
        }

        XCTAssertEqual(legacy.items, original)
        XCTAssertEqual(legacy.owner, owner)
        XCTAssertNotNil(legacy.ownership?.generation)
    }

    func testItemTransitionsStayAtTheirPersistedStateUntilTheWriteSucceeds() throws {
        for transition in ItemTransition.allCases {
            let fixture = try fixture()
            let queue = fixture.queue
            try queue.bind(to: owner)
            try queue.enqueue(["photo", "unrelated"], intent: .manualUpload, now: initial)
            if transition != .preparing {
                try queue.markPreparing("photo", phase: .primaryAsset,
                    motionAssetID: "motion-server", now: initial)
            }
            if [.cancelling, .storageRecovery].contains(transition) {
                try queue.markUploading("photo", phase: .primaryAsset,
                    checksum: "original-checksum", taskIdentifier: 7, now: initial)
            }
            let unrelated = queue.item(id: "unrelated")

            try assertFailedWriteCanBeRetried(fixture) {
                switch transition {
                case .preparing:
                    try queue.markPreparing("photo", phase: .livePhotoMotion, now: changed)
                case .queued:
                    try queue.markQueued("photo", now: changed)
                case .uploading:
                    try queue.markUploading("photo", phase: .primaryAsset,
                        checksum: "accepted-checksum", taskIdentifier: 8, now: changed)
                case .cancelling:
                    try queue.markCancelling("photo", now: changed)
                case .retry:
                    try queue.markRetry("photo", state: .retryScheduled, error: "Try again",
                        retryAt: changed.addingTimeInterval(60), now: changed)
                case .failed:
                    try queue.markFailed("photo", error: "Rejected", now: changed)
                case .storageRecovery:
                    let requeued = try queue.requeueAfterStorageRecovery("photo", taskIdentifier: 7, now: changed)
                    XCTAssertTrue(requeued)
                }
            }

            XCTAssertEqual(queue.item(id: "photo")?.state, transition.finalState, transition.rawValue)
            XCTAssertEqual(queue.item(id: "photo")?.updatedAt, changed, transition.rawValue)
            XCTAssertEqual(queue.item(id: "photo")?.intent, .manualUpload)
            XCTAssertEqual(queue.item(id: "unrelated"), unrelated)
            if transition == .uploading {
                XCTAssertEqual(queue.item(id: "photo")?.attemptCount, 1)
                XCTAssertEqual(queue.item(id: "photo")?.taskIdentifier, 8)
                XCTAssertEqual(queue.item(id: "photo")?.checksum, "accepted-checksum")
            }
        }
    }

    func testCompletionNotificationAndRemovalFailuresCanBeRetried() throws {
        for operation in TerminalMutation.allCases {
            let fixture = try fixture()
            let queue = fixture.queue
            try queue.bind(to: owner)
            try queue.enqueue(["photo", "other"], now: initial)
            if operation != .consume { try queue.consumeCompletionNotification() }

            try assertFailedWriteCanBeRetried(fixture) {
                switch operation {
                case .complete: try queue.markCompleted("photo")
                case .consume: try queue.consumeCompletionNotification()
                case .discard: try queue.discard("photo")
                case .discardMany:
                    let discarded = try queue.discard(["photo", "other"])
                    XCTAssertEqual(discarded, 2)
                case .clear: try queue.clear()
                }
            }

            switch operation {
            case .complete:
                XCTAssertEqual(queue.items.map(\.id), ["other"])
                XCTAssertEqual(queue.snapshot.completed, 1)
                XCTAssertTrue(queue.snapshot.completionNotificationPending)
            case .consume:
                XCTAssertFalse(queue.snapshot.completionNotificationPending)
                XCTAssertFalse(fixture.reopen().snapshot.completionNotificationPending)
                XCTAssertEqual(queue.items.map(\.id), ["photo", "other"])
            case .discard:
                XCTAssertEqual(queue.items.map(\.id), ["other"])
                XCTAssertEqual(queue.snapshot.completed, 0)
            case .discardMany:
                XCTAssertTrue(queue.items.isEmpty)
                XCTAssertEqual(queue.snapshot.total, 0)
                XCTAssertEqual(queue.owner, owner)
            case .clear:
                XCTAssertTrue(queue.items.isEmpty)
                XCTAssertNil(queue.owner)
                XCTAssertNil(queue.ownership)
                XCTAssertEqual(queue.snapshot.total, 0)
                XCTAssertFalse(queue.snapshot.completionNotificationPending)
            }
        }
    }

    func testStorageRecoveryCannotLoseACancellationWhenTheFailureWriteFails() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["photo"], intent: .manualUpload, now: initial)
        try queue.markPreparing("photo", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        try queue.markUploading("photo", phase: .primaryAsset,
            checksum: "checksum", taskIdentifier: 7, now: initial)
        try queue.markCancelling("photo", now: initial)

        try assertFailedWriteCanBeRetried(fixture) {
            let handled = try queue.requeueAfterStorageRecovery("photo", taskIdentifier: 7, now: changed)
            XCTAssertTrue(handled)
        }

        XCTAssertEqual(queue.item(id: "photo")?.state, .failed)
        XCTAssertEqual(queue.item(id: "photo")?.lastError, "Upload canceled.")
        XCTAssertEqual(queue.item(id: "photo")?.motionAssetID, "motion-server")
        XCTAssertNil(queue.item(id: "photo")?.taskIdentifier)
        XCTAssertTrue(queue.snapshot.completionNotificationPending)
    }

    func testAuthenticationTransitionsAreAtomicAndLeaveTerminalItemsAlone() throws {
        for releasing in [false, true] {
            let fixture = try fixture()
            let queue = fixture.queue
            try queue.enqueue(["waiting", "queued", "failed", "canceling"], now: initial)
            try queue.markRetry("waiting", state: .waitingForAuthentication,
                error: "Sign in", retryAt: nil, now: initial)
            try queue.markFailed("failed", error: "Rejected", now: initial)
            try queue.markPreparing("canceling", phase: .primaryAsset, now: initial)
            try queue.markUploading("canceling", phase: .primaryAsset,
                checksum: "checksum", taskIdentifier: 7, now: initial)
            try queue.markCancelling("canceling", now: initial)
            let failed = queue.item(id: "failed"), canceling = queue.item(id: "canceling")

            try assertFailedWriteCanBeRetried(fixture) {
                if releasing { try queue.releaseAuthenticationWaits(now: changed) }
                else { try queue.markAllWaitingForAuthentication(error: "Expired", now: changed) }
            }

            XCTAssertEqual(queue.item(id: "waiting")?.state, releasing ? .queued : .waitingForAuthentication)
            XCTAssertEqual(queue.item(id: "waiting")?.updatedAt, changed)
            XCTAssertEqual(queue.item(id: "queued")?.state, releasing ? .queued : .waitingForAuthentication)
            XCTAssertEqual(queue.item(id: "failed"), failed)
            XCTAssertEqual(queue.item(id: "canceling"), canceling)
        }
    }

    func testReconciliationCommitsAdoptionAndInterruptedTransfersTogether() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.bind(to: owner)
        try queue.enqueue(["replace-task", "stale", "canceling"], now: initial)
        for (index, id) in ["replace-task", "stale", "canceling"].enumerated() {
            try queue.markPreparing(id, phase: .primaryAsset, now: initial)
            try queue.markUploading(id, phase: .primaryAsset,
                checksum: "old-checksum", taskIdentifier: index + 1, now: initial)
        }
        try queue.markCancelling("canceling", now: initial)
        let ownership = try XCTUnwrap(queue.ownership)
        let active = ["replace-task", "adopted"].enumerated().map { index, id in
            BackupActiveTask(taskIdentifier: index + 10, context: BackupUploadTaskContext(
                phase: .livePhotoMotion, localIdentifier: id, checksum: "new-checksum",
                bodyPath: "/tmp/\(id).multipart", ownership: ownership), isSuspended: false)
        }
        let reconciledAt = initial.addingTimeInterval(900)

        try assertFailedWriteCanBeRetried(fixture) {
            try queue.reconcile(activeTasks: active, now: reconciledAt)
        }

        XCTAssertEqual(queue.item(id: "replace-task")?.taskIdentifier, 10)
        XCTAssertEqual(queue.item(id: "replace-task")?.phase, .livePhotoMotion)
        XCTAssertEqual(queue.item(id: "replace-task")?.checksum, "new-checksum")
        XCTAssertEqual(queue.item(id: "adopted")?.taskIdentifier, 11)
        XCTAssertEqual(queue.item(id: "adopted")?.state, .uploading)
        XCTAssertEqual(queue.item(id: "stale")?.state, .retryScheduled)
        XCTAssertEqual(queue.item(id: "stale")?.nextAttemptAt, reconciledAt)
        XCTAssertEqual(queue.item(id: "canceling")?.state, .failed)
        XCTAssertNil(queue.item(id: "canceling")?.taskIdentifier)
    }

    func testFailingALegacyItemAndArmingItsNotificationUseOneWrite() throws {
        let fixture = try fixture()
        try fixture.queue.enqueue(["photo"], now: initial)
        try fixture.removeLedgerField("completionNotificationPending")
        let legacy = fixture.reopen()
        XCTAssertFalse(legacy.snapshot.completionNotificationPending)
        let attempts = fixture.fileManager.writeAttempts
        // A second write would fail, exposing a split item/notification update.
        fixture.fileManager.failOnAttempt = attempts + 2

        XCTAssertNoThrow(try legacy.markFailed("photo", error: "Rejected", now: changed))

        XCTAssertEqual(fixture.fileManager.writeAttempts, attempts + 1)
        XCTAssertEqual(legacy.item(id: "photo")?.state, .failed)
        XCTAssertTrue(legacy.snapshot.completionNotificationPending)
        let reopened = fixture.reopen()
        XCTAssertEqual(reopened.items, legacy.items)
        XCTAssertTrue(reopened.snapshot.completionNotificationPending)
    }

    private func assertFailedWriteCanBeRetried(
        _ fixture: Fixture, queue suppliedQueue: BackupQueueStore? = nil,
        file: StaticString = #filePath, line: UInt = #line,
        action: () throws -> Void
    ) throws {
        let queue = suppliedQueue ?? fixture.queue
        let owner = queue.owner, ownership = queue.ownership
        let items = queue.items, snapshot = queue.snapshot
        let saved = try? Data(contentsOf: fixture.url)
        fixture.fileManager.failOnAttempt = fixture.fileManager.writeAttempts + 1

        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            guard case BackupQueueStoreError.unavailable = error else {
                return XCTFail("Expected a persistence failure, got \(error)", file: file, line: line)
            }
        }

        XCTAssertEqual(queue.owner, owner, file: file, line: line)
        XCTAssertEqual(queue.ownership, ownership, file: file, line: line)
        XCTAssertEqual(queue.items, items, file: file, line: line)
        XCTAssertEqual(queue.snapshot, snapshot, file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: fixture.url), saved, file: file, line: line)
        let failedReopen = fixture.reopen()
        XCTAssertEqual(failedReopen.owner, owner, file: file, line: line)
        XCTAssertEqual(failedReopen.ownership, ownership, file: file, line: line)
        XCTAssertEqual(failedReopen.items, items, file: file, line: line)
        XCTAssertEqual(failedReopen.snapshot, snapshot, file: file, line: line)

        fixture.fileManager.failOnAttempt = nil
        try action()

        let reopened = fixture.reopen()
        XCTAssertEqual(reopened.owner, queue.owner, file: file, line: line)
        XCTAssertEqual(reopened.ownership, queue.ownership, file: file, line: line)
        XCTAssertEqual(reopened.items, queue.items, file: file, line: line)
        XCTAssertEqual(reopened.snapshot, queue.snapshot, file: file, line: line)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return Fixture(url: directory.appendingPathComponent("queue.json"))
    }

    private enum ItemTransition: String, CaseIterable {
        case preparing, queued, uploading, cancelling, retry, failed, storageRecovery

        var finalState: BackupQueueItemState {
            switch self {
            case .preparing: .preparing
            case .queued, .storageRecovery: .queued
            case .uploading: .uploading
            case .cancelling: .cancelling
            case .retry: .retryScheduled
            case .failed: .failed
            }
        }
    }

    private enum TerminalMutation: CaseIterable { case complete, consume, discard, discardMany, clear }

    @MainActor
    private struct Fixture {
        let url: URL
        let fileManager: FailingQueueFileManager
        let queue: BackupQueueStore

        init(url: URL) {
            self.url = url
            fileManager = FailingQueueFileManager()
            queue = BackupQueueStore(fileURL: url, fileManager: fileManager)
        }

        func reopen() -> BackupQueueStore { BackupQueueStore(fileURL: url, fileManager: fileManager) }

        func removeLedgerField(_ field: String) throws {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object.removeValue(forKey: field)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
    }
}

private final class FailingQueueFileManager: FileManager, @unchecked Sendable {
    var failOnAttempt: Int?
    private(set) var writeAttempts = 0

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        writeAttempts += 1
        if writeAttempts == failOnAttempt { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
