import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumIntentTests: XCTestCase {
    private var directories: [URL] = []
    private let timestamp = Date(timeIntervalSince1970: 1_000)
    private let owner = BackupQueueOwner(server: "https://backup.example/api", userID: "first")
    private let albumName = "Trips / été 📷"

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testCapturedAlbumSurvivesRetryStorageRecoveryAndAnotherPreparation() throws {
        let fixture = try fixture()
        try fixture.queue.enqueue(["photo"], intent: .manualUpload, now: timestamp)
        try fixture.queue.markPreparing("photo", phase: .primaryAsset,
            sourceAlbumName: albumName, now: timestamp)
        try fixture.queue.markRetry("photo", state: .waitingForNetwork, error: "Offline",
            retryAt: timestamp, now: timestamp)

        let reopened = BackupQueueStore(fileURL: fixture.url)
        XCTAssertEqual(reopened.item(id: "photo")?.sourceAlbumName, albumName)
        try reopened.markPreparing("photo", phase: .primaryAsset,
            sourceAlbumName: "A later scan has another album", now: timestamp)
        try reopened.markUploading("photo", phase: .primaryAsset, checksum: "checksum",
            taskIdentifier: 7, now: timestamp)
        XCTAssertTrue(try reopened.requeueAfterStorageRecovery("photo", taskIdentifier: 7, now: timestamp))
        try reopened.markFailed("photo", error: "Rejected", now: timestamp)
        try BackupUploadRequests(queue: reopened).retry("photo")
        try reopened.markPreparing("photo", phase: .primaryAsset, now: timestamp)

        let retained = try XCTUnwrap(BackupQueueStore(fileURL: fixture.url).item(id: "photo"))
        XCTAssertEqual(retained.sourceAlbumName, albumName)
        XCTAssertEqual(retained.state, .preparing)
        XCTAssertEqual(retained.intent, .manualUpload)
        XCTAssertEqual(retained.checksum, "checksum")
        XCTAssertEqual(retained.attemptCount, 1)
    }

    func testTaskDescriptionAndRecoveryReceiptRetainCapturedAlbumForBothPhases() throws {
        let fixture = try fixture()
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let temporary = fixture.directory.appendingPathComponent("tmp", isDirectory: true)
        let recovery = fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let bytes = Data("last staged original".utf8)

        for phase in [BackupUploadPhase.primaryAsset, .livePhotoMotion] {
            let body = temporary.appendingPathComponent("upload-\(phase.rawValue).multipart")
            try bytes.write(to: body)
            let submitted = BackupUploadTaskContext(phase: phase, localIdentifier: "photo",
                checksum: "checksum", bodyPath: body.path, ownership: ownership,
                sourceAlbumName: albumName)
            let relaunched = try XCTUnwrap(BackupUploadTaskContext.decode(submitted.encoded))
            XCTAssertEqual(relaunched, submitted)

            try BackupTemporaryFiles.record(relaunched, in: temporary)
            XCTAssertTrue(try BackupTemporaryFiles.finish(relaunched, succeeded: false,
                sourceAvailable: false, in: temporary, recovery: recovery))

            let receipt = try XCTUnwrap(BackupTemporaryFiles.recordedContexts(in: recovery)
                .first { $0.phase == phase })
            XCTAssertEqual(receipt.sourceAlbumName, albumName)
            XCTAssertEqual(receipt.ownership, ownership)
            XCTAssertEqual(receipt, submitted)
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(body.lastPathComponent)), bytes)
        }
    }

    func testReconciliationRestoresAlbumForTrackedAndAdoptedTransfersWithoutReplacingCapturedNames() throws {
        for phase in [BackupUploadPhase.primaryAsset, .livePhotoMotion] {
            let fixture = try fixture()
            let ownership = try XCTUnwrap(fixture.queue.ownership)
            try fixture.queue.enqueue(["tracked", "captured", "legacy"], now: timestamp)
            for (index, id) in ["tracked", "captured", "legacy"].enumerated() {
                try fixture.queue.markPreparing(id, phase: phase,
                    sourceAlbumName: id == "captured" ? "Original album" : nil, now: timestamp)
                try fixture.queue.markUploading(id, phase: phase, checksum: id,
                    taskIdentifier: index + 7, now: timestamp)
            }
            let contexts = ["tracked", "captured", "legacy", "adopted"].enumerated().map { index, id in
                BackupActiveTask(taskIdentifier: index + 7,
                    context: BackupUploadTaskContext(phase: phase, localIdentifier: id,
                        checksum: id, bodyPath: "/old/tmp/upload-\(id).multipart", ownership: ownership,
                        sourceAlbumName: id == "legacy" ? nil : albumName),
                    isSuspended: false)
            }

            // The tracked task already has the same state and task ID. Its
            // missing album still has to reach disk during reconciliation.
            try fixture.queue.reconcile(activeTasks: contexts, now: timestamp)

            let reopened = BackupQueueStore(fileURL: fixture.url)
            XCTAssertEqual(reopened.item(id: "tracked")?.sourceAlbumName, albumName)
            XCTAssertEqual(reopened.item(id: "adopted")?.sourceAlbumName, albumName)
            XCTAssertEqual(reopened.item(id: "captured")?.sourceAlbumName, "Original album")
            XCTAssertNil(reopened.item(id: "legacy")?.sourceAlbumName)
            XCTAssertEqual(reopened.items.count, 4)
            XCTAssertTrue(reopened.items.allSatisfy { $0.state == .uploading && $0.phase == phase })
        }
    }

    func testAnotherOwnerOrGenerationCannotPublishAnAlbumIntoTheCurrentQueue() throws {
        let fixture = try fixture()
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        try fixture.queue.enqueue(["photo"], now: timestamp)
        try fixture.queue.markPreparing("photo", phase: .primaryAsset,
            sourceAlbumName: albumName, now: timestamp)
        try fixture.queue.markQueued("photo", now: timestamp)
        let original = fixture.queue.items
        let bytes = try Data(contentsOf: fixture.url)
        let staleOwnerships = [
            BackupUploadOwnership(owner: BackupQueueOwner(server: owner.server, userID: "other"),
                generation: ownership.generation),
            BackupUploadOwnership(owner: BackupQueueOwner(server: "https://other.example/api", userID: owner.userID),
                generation: ownership.generation),
            BackupUploadOwnership(owner: owner, generation: UUID()),
        ]

        for stale in staleOwnerships {
            let active = ["photo", "foreign-only"].map { id in
                BackupActiveTask(taskIdentifier: 77,
                    context: BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: id,
                        checksum: "stale", bodyPath: "/old/tmp/upload-\(id).multipart", ownership: stale,
                        sourceAlbumName: "Another account's album"), isSuspended: false)
            }
            try fixture.queue.reconcile(activeTasks: active, now: timestamp)
            XCTAssertEqual(fixture.queue.items, original)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        }

        try fixture.queue.bind(to: BackupQueueOwner(server: owner.server, userID: "replacement"))
        let replaced = BackupQueueStore(fileURL: fixture.url)
        XCTAssertTrue(replaced.items.isEmpty)
        XCTAssertNotEqual(replaced.ownership, ownership)
    }

    func testMotionHandoffRetainsAlbumAcrossRelaunchWithoutReadingPhotos() throws {
        for capturedBeforeUpload in [true, false] {
            let fixture = try fixture()
            try fixture.queue.enqueue(["live"], intent: .manualUpload, now: timestamp)
            try fixture.queue.markPreparing("live", phase: .livePhotoMotion,
                sourceAlbumName: capturedBeforeUpload ? albumName : nil, now: timestamp)
            try fixture.queue.markUploading("live", phase: .livePhotoMotion,
                checksum: "motion-checksum", taskIdentifier: 42, now: timestamp)
            let relaunched = BackupQueueStore(fileURL: fixture.url)

            try BackupUploadRequests(queue: relaunched).retainCompletedMotion("live",
                motionAssetID: "server-motion",
                sourceAlbumName: capturedBeforeUpload ? "Different task album" : albumName)

            let reopened = BackupQueueStore(fileURL: fixture.url)
            let still = try XCTUnwrap(reopened.item(id: "live"))
            XCTAssertEqual(still.sourceAlbumName, albumName)
            XCTAssertEqual(still.phase, .primaryAsset)
            XCTAssertEqual(still.motionAssetID, "server-motion")
            XCTAssertEqual(still.state, .queued)
            XCTAssertEqual(still.intent, .manualUpload)
            XCTAssertEqual(still.checksum, "motion-checksum")
            XCTAssertEqual(still.attemptCount, 1)
            XCTAssertEqual(BackupUploadRequests(queue: reopened).readyItems(automaticEnabled: false).map(\.id), ["live"])
        }
    }

    func testOlderLedgersAndTaskDescriptionsDecodeWithoutAnAlbum() throws {
        let fixture = try fixture()
        let legacy = """
        {"version":1,"completed":0,"owner":{"server":"https://backup.example/api","userID":"first"},
        "items":[{"id":"legacy","phase":"livePhotoMotion","state":"waitingForNetwork",
        "attemptCount":2,"checksum":"motion-checksum","motionAssetID":"saved-motion",
        "intent":"manualUpload","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}]}
        """
        try Data(legacy.utf8).write(to: fixture.url)
        let reopened = BackupQueueStore(fileURL: fixture.url)
        let item = try XCTUnwrap(reopened.item(id: "legacy"))
        XCTAssertNil(reopened.persistenceWarning)
        XCTAssertNil(item.sourceAlbumName)
        XCTAssertEqual(item.phase, .livePhotoMotion)
        XCTAssertEqual(item.motionAssetID, "saved-motion")
        XCTAssertEqual(item.intent, .manualUpload)
        XCTAssertEqual(item.attemptCount, 2)

        let oldJSON = """
        {"phase":"primaryAsset","localIdentifier":"legacy","checksum":"checksum","bodyPath":"/old/tmp/upload-legacy.multipart"}
        """
        let task = try XCTUnwrap(BackupUploadTaskContext.decode(oldJSON))
        XCTAssertNil(task.sourceAlbumName)
        XCTAssertEqual(task.localIdentifier, "legacy")
        XCTAssertEqual(task.phase, .primaryAsset)
        let oldDescription = ["legacy", "checksum", "/old/tmp/upload-legacy.multipart"].joined(separator: "\u{1}")
        XCTAssertEqual(BackupUploadTaskContext.decode(oldDescription), task)
    }

    private func fixture() throws -> (queue: BackupQueueStore, url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-album-intent-\(UUID())")
        directories.append(directory)
        let url = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: url)
        try queue.bind(to: owner)
        return (queue, url, directory)
    }
}
