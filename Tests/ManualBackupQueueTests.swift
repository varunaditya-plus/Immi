import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class ManualBackupQueueTests: XCTestCase {
    private var directories: [URL] = []
    private let initial = Date(timeIntervalSince1970: 100)
    private let requested = Date(timeIntervalSince1970: 200)

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testLegacyLedgerKeepsAutomaticRestrictionsAndExistingProgress() throws {
        let fixture = try fixture()
        let json = """
        {"version":1,"owner":{"server":"https://immich.test/api","userID":"u"},"completed":4,
         "completionNotificationPending":true,"items":[{"id":"legacy","phase":"livePhotoMotion",
         "state":"waitingForNetwork","attemptCount":2,"lastError":"Waiting for Wi-Fi",
         "checksum":"motion-checksum","nextAttemptAt":"2030-01-01T00:00:00Z",
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]}
        """
        try Data(json.utf8).write(to: fixture.url)

        let restored = fixture.reopen()
        let item = try XCTUnwrap(restored.item(id: "legacy"))

        XCTAssertNil(restored.persistenceWarning)
        XCTAssertNil(item.intent)
        XCTAssertFalse(item.isUserRequested)
        XCTAssertFalse(item.allowsCellularOverride)
        XCTAssertFalse(restored.hasPendingUserRequests)
        XCTAssertEqual(item.phase, .livePhotoMotion)
        XCTAssertEqual(item.attemptCount, 2)
        XCTAssertEqual(item.checksum, "motion-checksum")
        XCTAssertEqual(restored.snapshot.completed, 4)
        XCTAssertEqual(restored.snapshot.total, 5)
        XCTAssertEqual(restored.owner?.userID, "u")
        XCTAssertTrue(restored.readyItems(now: .distantFuture, userRequestedOnly: true).isEmpty)
    }

    func testManualAdmissionRequeuesOnlyRequestedFailuresAndPersistsTheirGrant() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["selected", "other", "canceled"], now: initial)
        try queue.markPreparing("selected", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        try queue.markUploading("selected", phase: .primaryAsset, checksum: "still-checksum", taskIdentifier: 7, now: initial)
        try queue.markFailed("selected", error: "Rejected original", now: initial)
        try queue.markFailed("other", error: "Keep this failure", now: initial)
        try queue.markFailed("canceled", error: "Upload canceled.", now: initial)
        let other = queue.item(id: "other")
        let canceled = queue.item(id: "canceled")

        try queue.enqueue(["selected", "new", "selected"], intent: .manualUpload, now: requested)

        let selected = try XCTUnwrap(queue.item(id: "selected"))
        XCTAssertEqual(selected.state, .queued)
        XCTAssertEqual(selected.intent, .manualUpload)
        XCTAssertTrue(selected.allowsCellularOverride)
        XCTAssertEqual(selected.phase, .primaryAsset)
        XCTAssertEqual(selected.motionAssetID, "motion-server")
        XCTAssertEqual(selected.checksum, "still-checksum")
        XCTAssertEqual(selected.attemptCount, 1)
        XCTAssertNil(selected.taskIdentifier)
        XCTAssertNil(selected.lastError)
        XCTAssertNil(selected.nextAttemptAt)
        XCTAssertEqual(selected.createdAt, initial)
        XCTAssertEqual(selected.updatedAt, requested)
        XCTAssertEqual(queue.item(id: "other"), other)
        XCTAssertEqual(queue.item(id: "canceled"), canceled)
        XCTAssertEqual(queue.items.count, 4)
        XCTAssertEqual(queue.snapshot.failed, 2)
        XCTAssertEqual(Set(queue.readyItems(userRequestedOnly: true).map(\.id)), ["selected", "new"])
        XCTAssertEqual(fixture.reopen().items, queue.items)
    }

    func testManualAdmissionReleasesIdleWaitsButKeepsAuthenticationWaiting() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        let states: [(String, BackupQueueItemState)] = [
            ("network", .waitingForNetwork), ("cloud", .waitingForICloud),
            ("retry", .retryScheduled), ("auth", .waitingForAuthentication), ("other", .waitingForNetwork),
        ]
        try queue.enqueue(states.map(\.0), now: initial)
        for (id, state) in states {
            try queue.markRetry(id, state: state, error: "Hold \(id)", retryAt: .distantFuture, now: initial)
        }
        var auth = try XCTUnwrap(queue.item(id: "auth"))
        auth.intent = .manualUpload
        let other = queue.item(id: "other")

        try queue.enqueue(["network", "cloud", "retry", "auth"], intent: .manualUpload, now: requested)

        for id in ["network", "cloud", "retry"] {
            XCTAssertEqual(queue.item(id: id)?.state, .queued)
            XCTAssertNil(queue.item(id: id)?.lastError)
            XCTAssertNil(queue.item(id: id)?.nextAttemptAt)
        }
        XCTAssertEqual(queue.item(id: "auth"), auth)
        XCTAssertEqual(queue.item(id: "other"), other)
        XCTAssertEqual(Set(queue.readyItems(userRequestedOnly: true).map(\.id)), ["network", "cloud", "retry"])
        XCTAssertEqual(fixture.reopen().items, queue.items)
    }

    func testManualAdmissionPreservesPreparingUploadingAndCancellingTransferIdentity() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["preparing", "uploading", "canceling"], now: initial)
        try queue.markPreparing("preparing", phase: .livePhotoMotion, now: initial)
        for (offset, id) in ["uploading", "canceling"].enumerated() {
            try queue.markPreparing(id, phase: .primaryAsset, motionAssetID: "motion-\(id)", now: initial)
            try queue.markUploading(id, phase: .primaryAsset, checksum: "hash-\(id)", taskIdentifier: offset + 1, now: initial)
        }
        try queue.markCancelling("canceling", now: initial)
        let expected = queue.items.map { item in
            var requested = item
            requested.intent = .manualUpload
            return requested
        }

        try queue.enqueue(["preparing", "uploading", "canceling"], intent: .manualUpload, now: requested)

        XCTAssertEqual(queue.items, expected)
        XCTAssertTrue(queue.readyItems(userRequestedOnly: true).isEmpty)
        XCTAssertEqual(queue.snapshot.active, 3)
        XCTAssertEqual(fixture.reopen().items, expected)
    }

    func testAutomaticEnqueueCannotDowngradeManualIntentOrReviveAFailure() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["manual"], intent: .manualUpload, now: initial)
        try queue.markFailed("manual", error: "Rejected", now: initial)
        try queue.consumeCompletionNotification()
        let original = queue.item(id: "manual")

        try queue.enqueue(["manual"], now: requested)

        XCTAssertEqual(queue.item(id: "manual"), original)
        XCTAssertFalse(queue.snapshot.completionNotificationPending)
        XCTAssertFalse(queue.hasPendingUserRequests)
        try queue.retryFailed("manual", now: requested)
        XCTAssertEqual(queue.item(id: "manual")?.intent, .manualUpload)
        XCTAssertTrue(queue.item(id: "manual")?.allowsCellularOverride == true)
        XCTAssertEqual(fixture.reopen().items, queue.items)
    }

    func testSingleUserRetryDoesNotGrantCellularOrTouchOtherFailures() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["selected", "other"], now: initial)
        try queue.markFailed("selected", error: "First", now: initial)
        try queue.markFailed("other", error: "Other", now: initial)
        let other = queue.item(id: "other")

        try queue.retryFailed("selected", userRequested: true, now: requested)

        let selected = try XCTUnwrap(queue.item(id: "selected"))
        XCTAssertEqual(selected.intent, .retry)
        XCTAssertTrue(selected.isUserRequested)
        XCTAssertFalse(selected.allowsCellularOverride)
        XCTAssertEqual(selected.state, .queued)
        XCTAssertEqual(queue.item(id: "other"), other)
        XCTAssertEqual(queue.readyItems(userRequestedOnly: true).map(\.id), ["selected"])
        XCTAssertEqual(fixture.reopen().items, queue.items)
    }

    func testRetryAllMarksOnlyFailuresAndKeepsAnExistingManualCellularGrant() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["manual"], intent: .manualUpload, now: initial)
        try queue.enqueue(["automatic", "queued", "waiting"], now: initial)
        for id in ["manual", "automatic"] { try queue.markFailed(id, error: id, now: initial) }
        try queue.markRetry("waiting", state: .waitingForNetwork, error: "Wi-Fi", retryAt: .distantFuture, now: initial)
        let queued = queue.item(id: "queued"), waiting = queue.item(id: "waiting")

        try queue.retryFailed(userRequested: true, now: requested)

        XCTAssertEqual(queue.item(id: "manual")?.intent, .manualUpload)
        XCTAssertEqual(queue.item(id: "automatic")?.intent, .retry)
        XCTAssertEqual(queue.item(id: "queued"), queued)
        XCTAssertEqual(queue.item(id: "waiting"), waiting)
        XCTAssertEqual(Set(queue.readyItems(userRequestedOnly: true).map(\.id)), ["manual", "automatic"])
        XCTAssertEqual(fixture.reopen().items, queue.items)
    }

    func testUserRequestedSelectionExcludesAutomaticWorkAndAppliesTheReadyLimit() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        let automatic = (0..<120).map { "automatic-\($0)" }
        try queue.enqueue(automatic, now: initial)
        try queue.enqueue(["retry"], intent: .retry, now: requested)
        try queue.enqueue(["manual"], intent: .manualUpload, now: requested.addingTimeInterval(1))

        XCTAssertEqual(queue.readyItems(limit: 100).count, 100)
        XCTAssertEqual(queue.readyItems(limit: 1, userRequestedOnly: true).map(\.id), ["retry"])
        XCTAssertEqual(fixture.reopen().readyItems(limit: 2, userRequestedOnly: true).map(\.id), ["retry", "manual"])
    }

    func testPersistedUserRequestsLeadAutomaticBacklogWithoutChangingItsOrderOrRecords() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        let automatic = (0..<120).map { "automatic-\($0)" }
        for (offset, id) in automatic.enumerated() {
            try queue.enqueue([id], now: initial.addingTimeInterval(Double(offset)))
        }
        let originalAutomatic = queue.items
        try queue.enqueue(["manual"], intent: .manualUpload, now: requested.addingTimeInterval(1_000))
        try queue.enqueue(["retry"], intent: .retry, now: requested.addingTimeInterval(1_001))
        let original = queue.items
        let reopened = fixture.reopen()

        XCTAssertEqual(reopened.readyItems().map(\.id), ["manual", "retry"] + automatic.prefix(98))
        XCTAssertEqual(reopened.readyItems(limit: 122).map(\.id), ["manual", "retry"] + automatic)
        XCTAssertEqual(reopened.items, original)
        XCTAssertEqual(Array(reopened.items.prefix(120)), originalAutomatic)
    }

    func testItemReadinessFollowsDeadlineAndExcludesActiveAuthenticationAndFailedStates() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["queued", "network", "cloud", "retry", "auth", "preparing", "uploading", "canceling", "failed"], now: initial)
        let deadline = requested.addingTimeInterval(10)
        try queue.markRetry("network", state: .waitingForNetwork, error: "Offline", retryAt: deadline, now: initial)
        try queue.markRetry("cloud", state: .waitingForICloud, error: "Cloud", retryAt: nil, now: initial)
        try queue.markRetry("retry", state: .retryScheduled, error: "Server", retryAt: deadline, now: initial)
        try queue.markRetry("auth", state: .waitingForAuthentication, error: "Auth", retryAt: nil, now: initial)
        try queue.markPreparing("preparing", phase: .primaryAsset, now: initial)
        for (index, id) in ["uploading", "canceling"].enumerated() {
            try queue.markPreparing(id, phase: .primaryAsset, now: initial)
            try queue.markUploading(id, phase: .primaryAsset, checksum: id, taskIdentifier: index + 1, now: initial)
        }
        try queue.markCancelling("canceling", now: initial)
        try queue.markFailed("failed", error: "Failed", now: initial)

        let restored = fixture.reopen()
        XCTAssertEqual(Set(restored.readyItems(now: requested).map(\.id)), ["queued", "cloud"])
        XCTAssertFalse(try XCTUnwrap(restored.item(id: "network")).isReady(now: requested))
        XCTAssertTrue(try XCTUnwrap(restored.item(id: "network")).isReady(now: deadline))
        XCTAssertTrue(try XCTUnwrap(restored.item(id: "retry")).isReady(now: deadline))
        for id in ["auth", "preparing", "uploading", "canceling", "failed"] {
            XCTAssertFalse(try XCTUnwrap(restored.item(id: id)).isReady(now: .distantFuture), "\(id) cannot become runnable merely because its deadline passed")
        }
    }

    func testPendingUserRequestsIncludesWaitsAndActiveWorkButNotTerminalFailures() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["automatic"], now: initial)
        XCTAssertFalse(queue.hasPendingUserRequests)
        try queue.enqueue(["manual"], intent: .manualUpload, now: initial)
        try queue.markRetry("manual", state: .waitingForICloud, error: "Cloud", retryAt: .distantFuture, now: initial)
        XCTAssertTrue(queue.hasPendingUserRequests)
        XCTAssertTrue(queue.readyItems(userRequestedOnly: true).isEmpty)
        try queue.markPreparing("manual", phase: .primaryAsset, now: initial)
        try queue.markUploading("manual", phase: .primaryAsset, checksum: "hash", taskIdentifier: 1, now: initial)
        XCTAssertTrue(queue.hasPendingUserRequests)
        try queue.markCancelling("manual", now: initial)
        XCTAssertTrue(queue.hasPendingUserRequests)
        try queue.markFailed("manual", error: "Canceled", now: initial)
        XCTAssertFalse(queue.hasPendingUserRequests)
        try queue.retryFailed("manual", userRequested: true, now: requested)
        try queue.markCompleted("manual")
        XCTAssertFalse(queue.hasPendingUserRequests)
    }

    func testTargetedNetworkReleasePreservesOtherWaitsAndLegacyReleaseStillWorks() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        let states: [(String, BackupQueueItemState)] = [
            ("selected", .waitingForNetwork), ("other", .waitingForNetwork),
            ("cloud", .waitingForICloud), ("auth", .waitingForAuthentication), ("server", .retryScheduled),
        ]
        try queue.enqueue(states.map(\.0), now: initial)
        for (id, state) in states {
            try queue.markRetry(id, state: state, error: id, retryAt: .distantFuture, now: initial)
        }
        let preserved = queue.items.filter { $0.id != "selected" }

        try queue.releaseNetworkWaits(Set(["selected", "cloud", "auth", "server"]), now: requested)

        XCTAssertEqual(queue.item(id: "selected")?.state, .queued)
        XCTAssertNil(queue.item(id: "selected")?.nextAttemptAt)
        XCTAssertEqual(queue.items.filter { $0.id != "selected" }, preserved)
        XCTAssertEqual(fixture.reopen().items, queue.items)
        try queue.releaseNetworkWaits(now: requested.addingTimeInterval(1))
        XCTAssertEqual(queue.item(id: "other")?.state, .queued)
        for (id, state) in states where id != "selected" && id != "other" {
            XCTAssertEqual(queue.item(id: id)?.state, state)
            XCTAssertEqual(queue.item(id: id)?.nextAttemptAt, .distantFuture)
        }
    }

    func testFailedManualAdmissionCannotPublishAnUnsavedPermissionOrStateChange() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["selected", "other"], now: initial)
        try queue.markFailed("selected", error: "Original error", now: initial)
        let original = queue.items, snapshot = queue.snapshot
        let saved = try fixture.blockWrites()

        XCTAssertThrowsError(try queue.enqueue(["selected", "new"], intent: .manualUpload, now: requested))

        XCTAssertEqual(queue.items, original)
        XCTAssertEqual(queue.snapshot, snapshot)
        XCTAssertFalse(queue.hasPendingUserRequests)
        XCTAssertNil(queue.item(id: "new"))
        XCTAssertNotNil(queue.persistenceWarning)
        XCTAssertEqual(BackupQueueStore(fileURL: saved).items, original)
    }

    func testFailedSingleAndBulkRetriesDoNotPublishIntentOrHideFailures() throws {
        for single in [false, true] {
            let fixture = try fixture()
            let queue = fixture.queue
            try queue.enqueue(["selected", "other"], now: initial)
            for id in ["selected", "other"] { try queue.markFailed(id, error: id, now: initial) }
            let original = queue.items, snapshot = queue.snapshot
            let saved = try fixture.blockWrites()

            if single {
                XCTAssertThrowsError(try queue.retryFailed("selected", userRequested: true, now: requested))
            } else {
                XCTAssertThrowsError(try queue.retryFailed(userRequested: true, now: requested))
            }

            XCTAssertEqual(queue.items, original)
            XCTAssertEqual(queue.snapshot, snapshot)
            XCTAssertFalse(queue.hasPendingUserRequests)
            XCTAssertEqual(BackupQueueStore(fileURL: saved).items, original)
        }
    }

    func testFailedTargetedNetworkReleaseKeepsTheOriginalWaitAndDeadline() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["manual"], intent: .manualUpload, now: initial)
        try queue.markRetry("manual", state: .waitingForNetwork, error: "Offline", retryAt: .distantFuture, now: initial)
        let original = queue.items, snapshot = queue.snapshot
        let saved = try fixture.blockWrites()

        XCTAssertThrowsError(try queue.releaseNetworkWaits(["manual"], now: requested))

        XCTAssertEqual(queue.items, original)
        XCTAssertEqual(queue.snapshot, snapshot)
        XCTAssertTrue(queue.readyItems(userRequestedOnly: true).isEmpty)
        XCTAssertEqual(BackupQueueStore(fileURL: saved).items, original)
    }

    func testStoppedPreparationClaimsResumeWithoutChangingOtherWorkOrMediaIdentity() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["manual", "uploading", "canceling", "auth", "cloud", "callback"], intent: .manualUpload, now: initial)
        try queue.enqueue(["retry"], intent: .retry, now: initial)
        try queue.enqueue(["automatic", "automatic-target"], now: initial)
        try queue.markPreparing("manual", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        try queue.markUploading("manual", phase: .primaryAsset, checksum: "still-hash", taskIdentifier: 7, now: initial)
        try queue.markRetry("manual", state: .retryScheduled, error: "Interrupted", retryAt: nil, now: initial)
        try queue.markPreparing("manual", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        try queue.markPreparing("retry", phase: .livePhotoMotion, now: initial)
        try queue.markPreparing("automatic", phase: .primaryAsset, now: initial)
        try queue.markPreparing("automatic-target", phase: .primaryAsset, now: initial)
        try queue.markPreparing("callback", phase: .primaryAsset, motionAssetID: "callback-motion", now: initial)
        for (index, id) in ["uploading", "canceling"].enumerated() {
            try queue.markPreparing(id, phase: .primaryAsset, now: initial)
            try queue.markUploading(id, phase: .primaryAsset, checksum: id, taskIdentifier: index + 20, now: initial)
        }
        try queue.markCancelling("canceling", now: initial)
        try queue.markRetry("auth", state: .waitingForAuthentication, error: "Auth", retryAt: nil, now: initial)
        try queue.markRetry("cloud", state: .waitingForICloud, error: "Cloud", retryAt: .distantFuture, now: initial)
        let expected = queue.items.map { item in
            guard ["manual", "retry", "automatic-target"].contains(item.id) else { return item }
            var resumed = item
            resumed.state = .queued
            resumed.updatedAt = requested
            return resumed
        }

        try queue.releasePreparations(["manual", "retry", "automatic-target", "uploading", "canceling", "auth"], now: requested)

        XCTAssertEqual(queue.items, expected)
        XCTAssertEqual(fixture.reopen().items, expected)
        XCTAssertEqual(Set(fixture.reopen().readyItems(userRequestedOnly: true).map(\.id)), ["manual", "retry"])
        let manual = try XCTUnwrap(queue.item(id: "manual"))
        XCTAssertEqual(manual.motionAssetID, "motion-server")
        XCTAssertEqual(manual.phase, .primaryAsset)
        XCTAssertEqual(manual.checksum, "still-hash")
        XCTAssertEqual(manual.attemptCount, 1)
        XCTAssertEqual(manual.intent, .manualUpload)
        XCTAssertEqual(queue.item(id: "automatic-target")?.state, .queued)
        XCTAssertNil(queue.item(id: "automatic-target")?.intent)
        XCTAssertEqual(queue.item(id: "automatic")?.state, .preparing)
        XCTAssertEqual(queue.item(id: "callback")?.state, .preparing)
        XCTAssertEqual(queue.item(id: "callback")?.motionAssetID, "callback-motion")
    }

    func testStoppedPreparationReleaseCannotPublishAnUnsavedState() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["manual"], intent: .manualUpload, now: initial)
        try queue.markPreparing("manual", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        let original = queue.items, snapshot = queue.snapshot
        let saved = try fixture.blockWrites()

        XCTAssertThrowsError(try queue.releasePreparations(["manual"], now: requested))

        XCTAssertEqual(queue.items, original)
        XCTAssertEqual(queue.snapshot, snapshot)
        XCTAssertTrue(queue.readyItems(userRequestedOnly: true).isEmpty)
        XCTAssertEqual(BackupQueueStore(fileURL: saved).items, original)
    }

    func testManualLivePhotoIntentSurvivesAuthenticationStorageRecoveryAndReconciliation() throws {
        let fixture = try fixture()
        let queue = fixture.queue
        try queue.enqueue(["live"], intent: .manualUpload, now: initial)
        try queue.markPreparing("live", phase: .primaryAsset, motionAssetID: "motion-server", now: initial)
        try queue.markUploading("live", phase: .primaryAsset, checksum: "still-hash", taskIdentifier: 7, now: initial)
        try queue.markRetry("live", state: .waitingForAuthentication, error: "Sign in", retryAt: nil, now: initial)
        let restored = fixture.reopen()
        try restored.releaseAuthenticationWaits(now: requested)
        try restored.markPreparing("live", phase: .primaryAsset, motionAssetID: "motion-server", now: requested)
        try restored.markUploading("live", phase: .primaryAsset, checksum: "still-hash", taskIdentifier: 8, now: requested)
        XCTAssertTrue(try restored.requeueAfterStorageRecovery("live", taskIdentifier: 8, now: requested))
        let context = BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "live",
            checksum: "still-hash", bodyPath: "/tmp/unused-live.multipart")
        try restored.reconcile(activeTasks: [BackupActiveTask(taskIdentifier: 9, context: context, isSuspended: false)], now: requested)

        let item = try XCTUnwrap(fixture.reopen().item(id: "live"))
        XCTAssertEqual(item.intent, .manualUpload)
        XCTAssertTrue(item.allowsCellularOverride)
        XCTAssertEqual(item.phase, .primaryAsset)
        XCTAssertEqual(item.motionAssetID, "motion-server")
        XCTAssertEqual(item.checksum, "still-hash")
        XCTAssertEqual(item.attemptCount, 2)
        XCTAssertEqual(item.taskIdentifier, 9)
        XCTAssertEqual(item.state, .uploading)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-queue-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return Fixture(url: directory.appendingPathComponent("queue.json"))
    }

    @MainActor
    private struct Fixture {
        let url: URL
        let queue: BackupQueueStore

        init(url: URL) {
            self.url = url
            queue = BackupQueueStore(fileURL: url)
        }

        func reopen() -> BackupQueueStore { BackupQueueStore(fileURL: url) }

        func blockWrites() throws -> URL {
            let saved = url.deletingLastPathComponent().appendingPathComponent("saved.json")
            try FileManager.default.moveItem(at: url, to: saved)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return saved
        }
    }
}
