import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupPreparationRecoveryTests: XCTestCase {
    private let owner = BackupQueueOwner(server: "https://immich.test/api", userID: "recovery-user")
    private let started = Date(timeIntervalSince1970: 100)
    private var directories: [URL] = []
    private var savedEnabled: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedEnabled = UserDefaults.standard.object(forKey: "backup.enabled")
        UserDefaults.standard.set(false, forKey: "backup.enabled")
    }

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: "backup.enabled") }
        else { UserDefaults.standard.removeObject(forKey: "backup.enabled") }
        savedEnabled = nil
        try await super.tearDown()
    }

    func testRecentPreparationsBecomeReadyImmediatelyAfterRelaunch() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        for (id, phase) in [("motion", BackupUploadPhase.livePhotoMotion), ("still", .primaryAsset)] {
            try queue.enqueue([id], intent: .manualUpload, now: started)
            try queue.markPreparing(id, phase: phase, now: started)
            try queue.markUploading(id, phase: phase, checksum: "checksum-\(id)", taskIdentifier: 4, now: started)
            try queue.markPreparing(id, phase: phase, motionAssetID: "saved-motion", now: started)
        }
        let originals = queue.items
        let restored = BackupQueueStore(fileURL: fixture.url)
        let now = started.addingTimeInterval(1)
        XCTAssertEqual(restored.snapshot.active, 2)
        XCTAssertTrue(restored.readyItems(now: now).isEmpty)

        try restored.reconcile(activeTasks: [], now: now)

        XCTAssertEqual(restored.ownership, queue.ownership)
        XCTAssertEqual(restored.snapshot.active, 0)
        XCTAssertEqual(restored.snapshot.retryScheduled, 2)
        XCTAssertEqual(Set(BackupUploadRequests(queue: restored)
            .readyItems(automaticEnabled: false, now: now).map(\.id)), ["motion", "still"])
        for original in originals {
            let recovered = try XCTUnwrap(restored.item(id: original.id))
            XCTAssertEqual(recovered.state, .retryScheduled)
            XCTAssertEqual(recovered.phase, original.phase)
            XCTAssertEqual(recovered.motionAssetID, original.motionAssetID)
            XCTAssertEqual(recovered.checksum, original.checksum)
            XCTAssertEqual(recovered.attemptCount, original.attemptCount)
            XCTAssertEqual(recovered.intent, original.intent)
            XCTAssertEqual(recovered.createdAt, original.createdAt)
            XCTAssertEqual(recovered.updatedAt, now)
            XCTAssertEqual(recovered.nextAttemptAt, now)
            XCTAssertNil(recovered.taskIdentifier)
            XCTAssertFalse(try XCTUnwrap(recovered.lastError).isEmpty)
        }
        let reopened = BackupQueueStore(fileURL: fixture.url)
        XCTAssertEqual(reopened.items, restored.items)
        XCTAssertEqual(reopened.snapshot, restored.snapshot)

        // Reconciliation must not reset an already recovered retry deadline.
        try restored.reconcile(activeTasks: [], now: now.addingTimeInterval(1))
        XCTAssertEqual(restored.items, reopened.items)
    }

    func testLivePreparationClaimProtectsEvenAnOldExportUntilItsWorkerEnds() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["busy", "interrupted"], now: started)
        for id in ["busy", "interrupted"] {
            try queue.markPreparing(id, phase: .primaryAsset, motionAssetID: "motion", now: started)
        }
        let busy = try XCTUnwrap(queue.item(id: "busy"))

        try queue.reconcile(activeTasks: [], livePreparationIDs: ["busy"],
                            now: started.addingTimeInterval(900))

        XCTAssertEqual(queue.item(id: "busy"), busy)
        XCTAssertEqual(queue.item(id: "interrupted")?.state, .retryScheduled)
        XCTAssertEqual(queue.snapshot.active, 1)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.url).item(id: "busy"), busy)

        try queue.reconcile(activeTasks: [], now: started.addingTimeInterval(901))

        XCTAssertEqual(queue.item(id: "busy")?.state, .retryScheduled)
        XCTAssertEqual(queue.item(id: "busy")?.motionAssetID, "motion")
        XCTAssertEqual(queue.snapshot.active, 0)
    }

    func testOwnedBackgroundTaskWinsWhileForeignTaskCannotProtectAnOrphan() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["owned", "foreign"], now: started)
        for id in ["owned", "foreign"] {
            try queue.markPreparing(id, phase: .livePhotoMotion, now: started)
        }
        let ownership = try XCTUnwrap(queue.ownership)
        let tasks = [
            task(id: "owned", identifier: 7, ownership: ownership),
            task(id: "foreign", identifier: 8,
                 ownership: BackupUploadOwnership(owner: owner, generation: UUID())),
        ]

        try queue.reconcile(activeTasks: tasks, now: started.addingTimeInterval(1))

        XCTAssertEqual(queue.item(id: "owned")?.state, .uploading)
        XCTAssertEqual(queue.item(id: "owned")?.taskIdentifier, 7)
        XCTAssertEqual(queue.item(id: "owned")?.checksum, "confirmed-checksum")
        XCTAssertEqual(queue.item(id: "owned")?.phase, .livePhotoMotion)
        XCTAssertEqual(queue.item(id: "foreign")?.state, .retryScheduled)
        XCTAssertNil(queue.item(id: "foreign")?.taskIdentifier)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.url).items, queue.items)
    }

    func testMissingTransferKeepsItsGracePeriodAndActiveTransferIsNeverRetried() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["missing", "active"], now: started)
        for (id, identifier) in [("missing", 1), ("active", 2)] {
            try queue.markPreparing(id, phase: .livePhotoMotion, now: started)
            try queue.markUploading(id, phase: .livePhotoMotion, checksum: "confirmed-checksum",
                                    taskIdentifier: identifier, now: started)
        }
        let active = task(id: "active", identifier: 2, ownership: try XCTUnwrap(queue.ownership))
        let originals = queue.items

        try queue.reconcile(activeTasks: [active], now: started.addingTimeInterval(1))
        XCTAssertEqual(queue.items, originals)

        try queue.reconcile(activeTasks: [active], now: started.addingTimeInterval(600))

        XCTAssertEqual(queue.item(id: "missing")?.state, .retryScheduled)
        XCTAssertNil(queue.item(id: "missing")?.taskIdentifier)
        XCTAssertEqual(queue.item(id: "active"), originals.first { $0.id == "active" })
        XCTAssertEqual(queue.snapshot.active, 1)
        XCTAssertEqual(queue.snapshot.retryScheduled, 1)
    }

    func testServiceRestorationRecoversRecentPreparationWithoutAnotherStart() async throws {
        let fixture = try fixture()
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        try fixture.queue.enqueue(["recent"], now: now)
        try fixture.queue.markPreparing("recent", phase: .primaryAsset,
                                        motionAssetID: "uploaded-motion", now: now)
        let (restored, service, session) = restoredService(fixture)
        defer { withExtendedLifetime(session) { service.stop() } }
        // Disabled automatic backup keeps the recovered item idle; this tests
        // restoration without requiring a PhotoKit original or exporting one.
        XCTAssertTrue(session.isLoggedIn)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(restored.item(id: "recent")?.state, .preparing)

        await service.restoreBackgroundLifecycle()

        XCTAssertEqual(restored.item(id: "recent")?.state, .retryScheduled)
        XCTAssertEqual(restored.item(id: "recent")?.motionAssetID, "uploaded-motion")
        XCTAssertEqual(restored.snapshot.active, 0)
        XCTAssertEqual(service.scheduledForRetry, 1)
        XCTAssertEqual(service.uploadItems.map(\.state), [.retryScheduled])
        XCTAssertEqual(BackupUploadRequests(queue: restored)
            .readyItems(automaticEnabled: true).map(\.id), ["recent"])
        try assertPersisted("recent", queue: restored, url: fixture.url)
    }

    func testMissingTransferDeadlineSurvivesSameAccountSessionReplacement() async throws {
        let fixture = try fixture()
        try queueMissingTransfer(fixture.queue)
        let (restored, service, session) = restoredService(fixture)
        defer { withExtendedLifetime(session) { service.stop() } }
        XCTAssertTrue(session.isLoggedIn)
        let original = try XCTUnwrap(restored.item(id: "recent"))
        let recovered = expectation(description: "Missing transfer is reconciled at its grace deadline")
        withObservationTracking { _ = restored.snapshot } onChange: { recovered.fulfill() }

        await service.restoreBackgroundLifecycle()
        XCTAssertEqual(restored.item(id: "recent"), original,
                       "A fresh missing transfer must retain its grace period")
        let previousOwnership = restored.ownership
        let dataManager = SwiftDataManager(
            storeURL: fixture.directory.appendingPathComponent("foreground.store"),
            backupJournalURL: fixture.directory.appendingPathComponent("foreground-journal.json"))
        let foreground = RecoverySession(owner: owner, dataManager: dataManager)
        defer { withExtendedLifetime(foreground) {} }
        service.configure(session: foreground)
        XCTAssertEqual(restored.ownership, previousOwnership)
        await fulfillment(of: [recovered], timeout: 6)

        let item = try XCTUnwrap(restored.item(id: "recent"))
        XCTAssertEqual(item.state, .retryScheduled)
        XCTAssertNil(item.taskIdentifier)
        XCTAssertEqual(item.phase, original.phase)
        XCTAssertEqual(item.motionAssetID, original.motionAssetID)
        XCTAssertEqual(item.checksum, original.checksum)
        XCTAssertEqual(item.attemptCount, original.attemptCount)
        XCTAssertEqual(item.intent, original.intent)
        XCTAssertEqual(item.createdAt, original.createdAt)
        XCTAssertEqual(service.scheduledForRetry, 1)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.uploadOwnership, previousOwnership)
        XCTAssertEqual(service.uploadItems.map(\.state), [.retryScheduled])
        try assertPersisted("recent", queue: restored, url: fixture.url)
    }

    func testPreviousAccountsRecoveryWakeCannotReconcileTheReplacementQueue() async throws {
        let fixture = try fixture()
        try queueMissingTransfer(fixture.queue)
        let (restored, service, session) = restoredService(fixture)
        defer { withExtendedLifetime(session) { service.stop() } }
        XCTAssertTrue(session.isLoggedIn)
        let previous = try XCTUnwrap(restored.item(id: "recent"))
        let deadline = previous.updatedAt.addingTimeInterval(BackupQueueStore.staleTransferInterval)
        await service.restoreBackgroundLifecycle()
        XCTAssertEqual(restored.item(id: "recent")?.state, .uploading)
        let otherOwner = BackupQueueOwner(server: owner.server, userID: "replacement")
        let dataManager = SwiftDataManager(
            storeURL: fixture.directory.appendingPathComponent("replacement.store"),
            backupJournalURL: fixture.directory.appendingPathComponent("replacement-journal.json"))
        let replacement = RecoverySession(owner: otherOwner, dataManager: dataManager)
        service.configure(session: replacement)
        try restored.enqueue(["replacement"], now: .now)
        try restored.markPreparing("replacement", phase: .primaryAsset, now: .now)
        let expected = restored.items
        let unexpected = expectation(description: "An obsolete wake must not reconcile a different account")
        unexpected.isInverted = true
        withObservationTracking { _ = restored.snapshot } onChange: { unexpected.fulfill() }

        await fulfillment(of: [unexpected], timeout: max(0.1, deadline.timeIntervalSinceNow) + 0.5)

        XCTAssertEqual(restored.owner, otherOwner)
        XCTAssertEqual(restored.items, expected)
        XCTAssertEqual(restored.item(id: "replacement")?.state, .preparing)
        XCTAssertNil(restored.item(id: "recent"))
        XCTAssertEqual(service.uploadOwnership?.owner, otherOwner)
        XCTAssertTrue(replacement.isLoggedIn)
    }

    private func assertPersisted(_ id: String, queue: BackupQueueStore, url: URL) throws {
        let reopened = BackupQueueStore(fileURL: url)
        var expected = try XCTUnwrap(queue.item(id: id))
        let persisted = try XCTUnwrap(reopened.item(id: id))
        // The existing ledger date format persists whole seconds.
        XCTAssertEqual(persisted.updatedAt.timeIntervalSince1970,
                       expected.updatedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(persisted.nextAttemptAt).timeIntervalSince1970,
                       try XCTUnwrap(expected.nextAttemptAt).timeIntervalSince1970, accuracy: 1)
        expected.updatedAt = persisted.updatedAt
        expected.nextAttemptAt = persisted.nextAttemptAt
        XCTAssertEqual(persisted, expected)
        XCTAssertEqual(reopened.ownership, queue.ownership)
    }

    private func queueMissingTransfer(_ queue: BackupQueueStore) throws {
        let recent = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
            .addingTimeInterval(-BackupQueueStore.staleTransferInterval + 3)
        try queue.enqueue(["recent"], now: recent)
        try queue.markPreparing("recent", phase: .primaryAsset, motionAssetID: "uploaded-motion", now: recent)
        try queue.markUploading("recent", phase: .primaryAsset,
                                checksum: "saved-checksum", taskIdentifier: 9, now: recent)
    }

    private func restoredService(_ fixture: Fixture) -> (BackupQueueStore, BackupService, RecoverySession) {
        let restored = BackupQueueStore(fileURL: fixture.url)
        let dataManager = SwiftDataManager(
            storeURL: fixture.directory.appendingPathComponent("test.store"),
            backupJournalURL: fixture.directory.appendingPathComponent("journal.json"))
        XCTAssertTrue(dataManager.isPersistentStoreAvailable)
        let session = RecoverySession(owner: owner, dataManager: dataManager)
        let service = BackupService(dataManager: dataManager, queue: restored)
        service.configure(session: session)
        return (restored, service, session)
    }

    private struct Fixture {
        let directory: URL
        let queue: BackupQueueStore
        var url: URL { directory.appendingPathComponent("queue.json") }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preparation-recovery-\(UUID().uuidString)")
        directories.append(directory)
        let queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        try queue.bind(to: owner)
        return Fixture(directory: directory, queue: queue)
    }

    private func task(id: String, identifier: Int, ownership: BackupUploadOwnership) -> BackupActiveTask {
        BackupActiveTask(taskIdentifier: identifier,
            context: BackupUploadTaskContext(phase: .livePhotoMotion, localIdentifier: id,
                checksum: "confirmed-checksum", bodyPath: "/tmp/upload-\(id).multipart", ownership: ownership),
            isSuspended: false)
    }

    private final class RecoverySession: SessionManager {
        private let owner: BackupQueueOwner

        init(owner: BackupQueueOwner, dataManager: SwiftDataManager) {
            self.owner = owner
            super.init(dataManager: dataManager, restoresSession: false)
            isLoggedIn = true
        }

        override var backupQueueOwner: BackupQueueOwner? { owner }
    }
}
