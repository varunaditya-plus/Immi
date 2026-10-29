import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackgroundUploadQueueTests: XCTestCase {
    func testQueueSurvivesProcessRelaunchWithUploadingTask() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.bind(to: BackupQueueOwner(server: "https://immich.test/api", userID: "user-1"))
        try queue.enqueue(["local-a", "local-b"], now: Date(timeIntervalSince1970: 10))
        try queue.markPreparing("local-a", phase: .primaryAsset)
        try queue.markUploading(
            "local-a",
            phase: .primaryAsset,
            checksum: "sha1-a",
            taskIdentifier: 42)

        let restored = BackupQueueStore(fileURL: fixture.queueURL)

        XCTAssertEqual(restored.snapshot.total, 2)
        XCTAssertEqual(restored.snapshot.active, 1)
        XCTAssertEqual(restored.snapshot.queued, 1)
        XCTAssertEqual(restored.item(id: "local-a")?.taskIdentifier, 42)
        XCTAssertEqual(restored.owner?.userID, "user-1")
    }

    func testCompletedBatchNotificationIsConsumedAcrossRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["local-a"])
        try queue.markCompleted("local-a")

        XCTAssertTrue(queue.snapshot.completionNotificationPending)
        try queue.consumeCompletionNotification()

        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(restored.snapshot.completed, 1)
        XCTAssertFalse(restored.snapshot.completionNotificationPending)
    }

    func testNewBatchRearmsCompletionNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["first"])
        try queue.markCompleted("first")
        try queue.consumeCompletionNotification()

        try queue.enqueue(["second"])

        XCTAssertEqual(queue.snapshot.completed, 0)
        XCTAssertEqual(queue.snapshot.queued, 1)
        XCTAssertTrue(queue.snapshot.completionNotificationPending)
    }

    func testAutomaticContinuationPreservesProgressAfterAnEntireWindowFinishes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        let first = (0..<100).map { "first-\($0)" }
        let second = (0..<100).map { "second-\($0)" }
        let last = (0..<25).map { "last-\($0)" }
        try queue.enqueue(first)
        for id in first { try queue.markCompleted(id) }
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.snapshot.completed, 100)

        try queue.enqueue(second, continuingBatch: true)

        let secondWindow = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(secondWindow.snapshot.total, 200)
        XCTAssertEqual(secondWindow.snapshot.completed, 100)
        XCTAssertEqual(secondWindow.snapshot.queued, 100)
        XCTAssertEqual(Set(secondWindow.readyItems().map(\.id)), Set(second))

        for id in second { try queue.markCompleted(id) }
        try queue.enqueue(last, continuingBatch: true)
        let finalWindow = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(finalWindow.snapshot.total, 225)
        XCTAssertEqual(finalWindow.snapshot.completed, 200)
        XCTAssertEqual(finalWindow.snapshot.queued, 25)

        for id in last { try queue.markCompleted(id) }
        let completed = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(completed.snapshot.total, 225)
        XCTAssertEqual(completed.snapshot.completed, 225)
        XCTAssertEqual(completed.snapshot.unfinished, 0)
        XCTAssertTrue(completed.snapshot.completionNotificationPending)
        try queue.consumeCompletionNotification()
        XCTAssertFalse(BackupQueueStore(fileURL: fixture.queueURL).snapshot.completionNotificationPending)
    }

    func testContinuationDoesNotResetExistingFailuresRetriesOrUploadAttempts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        let started = Date(timeIntervalSince1970: 100)
        let retryAt = Date(timeIntervalSince1970: 500)
        try queue.enqueue(["failed", "retry", "uploading", "completed"], now: started)
        try queue.markPreparing("failed", phase: .livePhotoMotion, motionAssetID: "motion-failed", now: started)
        try queue.markUploading("failed", phase: .livePhotoMotion, checksum: "failed-checksum", taskIdentifier: 1, now: started)
        try queue.markFailed("failed", error: "invalid asset", now: started)
        try queue.markPreparing("retry", phase: .primaryAsset, now: started)
        try queue.markUploading("retry", phase: .primaryAsset, checksum: "retry-checksum", taskIdentifier: 2, now: started)
        try queue.markRetry("retry", state: .retryScheduled, error: "temporary error", retryAt: retryAt, now: started)
        try queue.markPreparing("uploading", phase: .primaryAsset, now: started)
        try queue.markUploading("uploading", phase: .primaryAsset, checksum: "upload-checksum", taskIdentifier: 3, now: started)
        try queue.markCompleted("completed")
        let original = queue.items

        try queue.enqueue(["failed", "retry", "uploading", "new", "new"], continuingBatch: true,
            now: Date(timeIntervalSince1970: 200))

        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(Array(restored.items.prefix(original.count)), original)
        XCTAssertEqual(restored.snapshot.total, 5)
        XCTAssertEqual(restored.snapshot.completed, 1)
        XCTAssertEqual(restored.snapshot.failed, 1)
        XCTAssertEqual(restored.snapshot.retryScheduled, 1)
        XCTAssertEqual(restored.snapshot.active, 1)
        XCTAssertEqual(restored.snapshot.queued, 1)
        XCTAssertEqual(restored.readyItems(now: started).map(\.id), ["new"])
        XCTAssertEqual(restored.item(id: "new")?.attemptCount, 0)
    }

    func testEnqueueingSameFailedItemDoesNotReplayCompletion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["failed"])
        try queue.markFailed("failed", error: "invalid asset")
        try queue.consumeCompletionNotification()

        // A repeated enqueue request does not represent fresh work.
        try queue.enqueue(["failed"])

        XCTAssertFalse(queue.snapshot.completionNotificationPending)
        XCTAssertEqual(queue.snapshot.failed, 1)
    }

    func testCancellingTransferBecomesRetryableFailureWhenTaskIsGone() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["cancel-me"])
        try queue.markPreparing("cancel-me", phase: .primaryAsset)
        try queue.markUploading(
            "cancel-me",
            phase: .primaryAsset,
            checksum: "sha1",
            taskIdentifier: 9)
        try queue.markCancelling("cancel-me")

        XCTAssertEqual(queue.item(id: "cancel-me")?.state, .cancelling)
        XCTAssertEqual(queue.snapshot.active, 1)

        try queue.reconcile(activeTasks: [])

        XCTAssertEqual(queue.item(id: "cancel-me")?.state, .failed)
        XCTAssertEqual(queue.item(id: "cancel-me")?.lastError, "Upload canceled.")
        XCTAssertEqual(queue.snapshot.failed, 1)
        XCTAssertEqual(queue.snapshot.active, 0)
    }

    func testRetrySingleFailureLeavesOtherFailuresUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["retry-me", "leave-me"])
        try queue.markFailed("retry-me", error: "first")
        try queue.markFailed("leave-me", error: "second")

        try queue.retryFailed("retry-me")

        XCTAssertEqual(queue.item(id: "retry-me")?.state, .queued)
        XCTAssertNil(queue.item(id: "retry-me")?.lastError)
        XCTAssertEqual(queue.item(id: "leave-me")?.state, .failed)
        XCTAssertEqual(queue.snapshot.queued, 1)
        XCTAssertEqual(queue.snapshot.failed, 1)
    }

    func testDiscardedFailureStaysRemovedAfterRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["remove-me", "keep-me"])
        try queue.markFailed("remove-me", error: "missing local asset")

        try queue.discard("remove-me")

        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertNil(restored.item(id: "remove-me"))
        XCTAssertEqual(restored.item(id: "keep-me")?.state, .queued)
        XCTAssertEqual(restored.snapshot.failed, 0)
        XCTAssertEqual(restored.snapshot.queued, 1)
    }

    func testUnavailableFailuresAreDiscardedAsOnePersistedCleanup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["deleted-a", "deleted-b", "real-failure"])
        try queue.markFailed("deleted-a", error: "asset unavailable")
        try queue.markFailed("deleted-b", error: "asset unavailable")
        try queue.markFailed("real-failure", error: "server rejected asset")

        let removed = try queue.discard(Set(["deleted-a", "deleted-b"]))

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(queue.failedIDs, ["real-failure"])
        XCTAssertEqual(queue.snapshot.failed, 1)

        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(restored.failedIDs, ["real-failure"])
        XCTAssertNil(restored.item(id: "deleted-a"))
        XCTAssertNil(restored.item(id: "deleted-b"))
    }

    func testOwnedBackgroundTaskWithoutQueueRecordIsAdoptedAfterRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.bind(to: BackupQueueOwner(server: "https://immich.test/api", userID: "user-1"))
        let context = BackupUploadTaskContext(
            phase: .livePhotoMotion,
            localIdentifier: "legacy-live",
            checksum: "motion-sha1",
            bodyPath: "/tmp/legacy.multipart",
            ownership: try XCTUnwrap(queue.ownership))

        try queue.reconcile(activeTasks: [
            BackupActiveTask(taskIdentifier: 7, context: context, isSuspended: true),
        ])

        XCTAssertEqual(queue.snapshot.active, 1)
        XCTAssertEqual(queue.item(id: "legacy-live")?.phase, .livePhotoMotion)
        XCTAssertEqual(queue.item(id: "legacy-live")?.taskIdentifier, 7)
    }

    func testNetworkAndAuthenticationWaitsResumeWithoutBackupView() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.enqueue(["network", "auth"])
        try queue.markRetry(
            "network",
            state: .waitingForNetwork,
            error: "offline",
            retryAt: .distantFuture)
        try queue.markRetry(
            "auth",
            state: .waitingForAuthentication,
            error: "expired",
            retryAt: nil)

        XCTAssertEqual(queue.snapshot.waitingForNetwork, 1)
        XCTAssertEqual(queue.snapshot.waitingForAuthentication, 1)
        XCTAssertEqual(queue.snapshot.presentation?.title, "Backup Needs Sign In")

        try queue.releaseNetworkWaits()
        try queue.releaseAuthenticationWaits()

        XCTAssertEqual(Set(queue.readyItems().map(\.id)), Set(["network", "auth"]))
        XCTAssertEqual(queue.snapshot.queued, 2)
    }

    func testQueueCannotCrossIntoAnotherAccount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let queue = BackupQueueStore(fileURL: fixture.queueURL)
        try queue.bind(to: BackupQueueOwner(server: "https://immich.test/api", userID: "user-1"))
        try queue.enqueue(["private-asset"])

        let replaced = try queue.bind(
            to: BackupQueueOwner(server: "https://immich.test/api", userID: "user-2"))

        XCTAssertTrue(replaced)
        XCTAssertEqual(queue.snapshot.total, 0)
        XCTAssertEqual(queue.owner?.userID, "user-2")
    }

    func testCorruptQueueIsQuarantinedAndRebuildable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.queueURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fixture.queueURL)

        let queue = BackupQueueStore(fileURL: fixture.queueURL)

        XCTAssertEqual(queue.snapshot.total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.queueURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("BackgroundBackupQueue-corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
        let quarantine = try XCTUnwrap(quarantined.first)
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("not-json".utf8))
        try queue.enqueue(["rediscovered"])
        XCTAssertEqual(queue.snapshot.queued, 1)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.queueURL).items.map(\.id), ["rediscovered"])
    }

    private struct Fixture {
        let directory: URL
        var queueURL: URL { directory.appendingPathComponent("queue.json") }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-queue-tests-\(UUID().uuidString)", isDirectory: true)
        return Fixture(directory: directory)
    }
}

final class BackgroundUploadFailureClassificationTests: XCTestCase {
    func testConnectivityFailuresStayRetryable() {
        XCTAssertEqual(
            BackupUploadFailureDisposition.classify(URLError(.networkConnectionLost)),
            .retryNetwork)
        XCTAssertEqual(
            BackupUploadFailureDisposition.classify(URLError(.cannotConnectToHost)),
            .retryNetwork)
    }

    func testExpiredTokenWaitsForAuthentication() {
        XCTAssertEqual(
            BackupUploadFailureDisposition.classify(
                APIError.server(status: 401, message: "expired")),
            .authenticationRequired)
    }

    func testServerErrorsRetryButInvalidAssetDoesNotLoopForever() {
        XCTAssertEqual(
            BackupUploadFailureDisposition.classify(
                APIError.server(status: 503, message: "unavailable")),
            .retryServer)
        XCTAssertEqual(
            BackupUploadFailureDisposition.classify(
                APIError.server(status: 400, message: "invalid asset")),
            .permanent)
    }
}
