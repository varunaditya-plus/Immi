import Foundation
import XCTest
@testable import ImmichApp

final class BackupStorageTests: XCTestCase {
    func testCompletedUploadCleanupPreservesOnlyUnrecoverableFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-cleanup-\(UUID())")
        let tmp = root.appendingPathComponent("tmp")
        let recovery = root.appendingPathComponent("recovery")
        let ownership = BackupUploadOwnership(
            owner: BackupQueueOwner(server: "https://backup.example/api", userID: "current"), generation: UUID())
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (index, succeeded, sourceAvailable) in [(0, true, false), (1, false, true), (2, false, false)] {
            let body = tmp.appendingPathComponent("upload-\(index).multipart")
            let context = BackupUploadTaskContext(
                phase: .primaryAsset, localIdentifier: "photo-\(index)", checksum: "sha",
                bodyPath: body.path, ownership: ownership)
            let bytes = Data(repeating: UInt8(index), count: 1024)
            try bytes.write(to: body)
            try BackupTemporaryFiles.record(context, in: tmp)
            let preserved = try BackupTemporaryFiles.finish(
                context, succeeded: succeeded, sourceAvailable: sourceAvailable, in: tmp, recovery: recovery)
            XCTAssertEqual(preserved, !succeeded && !sourceAvailable)
            XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: body.appendingPathExtension("json").path))
            let saved = recovery.appendingPathComponent(body.lastPathComponent)
            XCTAssertEqual(FileManager.default.fileExists(atPath: saved.path), preserved)
            if preserved { XCTAssertEqual(try Data(contentsOf: saved), bytes) }
        }

        // An app launch and general temp cleanup must not touch recovery copies.
        TemporaryMediaStore.cleanupStaleFiles(in: tmp, olderThan: .distantFuture)
        BackupTemporaryFiles.cleanupOrphans(in: tmp, activeBodyPaths: [], olderThan: .distantFuture)
        let contexts = BackupTemporaryFiles.recordedContexts(in: recovery)
        XCTAssertEqual(contexts.map(\.localIdentifier), ["photo-2"])
        let savedBody = recovery.appendingPathComponent("upload-2.multipart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedBody.path))

        // A different checksum or Live Photo phase must not clear the copy.
        for (checksum, phase) in [("other", BackupUploadPhase.primaryAsset), ("sha", .livePhotoMotion)] {
            let unrelated = BackupUploadTaskContext(
                phase: phase, localIdentifier: "photo-2", checksum: checksum,
                bodyPath: tmp.appendingPathComponent("upload-retry.multipart").path, ownership: ownership)
            try BackupTemporaryFiles.finish(unrelated, succeeded: true, sourceAvailable: true, in: tmp, recovery: recovery)
            XCTAssertTrue(FileManager.default.fileExists(atPath: savedBody.path))
        }
        let retry = BackupUploadTaskContext(
            phase: .primaryAsset, localIdentifier: "photo-2", checksum: "sha",
            bodyPath: tmp.appendingPathComponent("upload-retry.multipart").path, ownership: ownership)
        try BackupTemporaryFiles.finish(retry, succeeded: true, sourceAvailable: true, in: tmp, recovery: recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedBody.path))
        XCTAssertTrue(BackupTemporaryFiles.recordedContexts(in: recovery).isEmpty)
    }

    func testLateSuccessCannotRemoveAnotherAccountOrGenerationRecoveryCopy() throws {
        let current = BackupUploadOwnership(
            owner: BackupQueueOwner(server: "https://backup.example/api", userID: "current"), generation: UUID())
        let staleOwnerships = [
            BackupUploadOwnership(owner: BackupQueueOwner(server: current.owner.server, userID: "other"),
                generation: current.generation),
            BackupUploadOwnership(owner: BackupQueueOwner(server: "https://other.example/api", userID: current.owner.userID),
                generation: current.generation),
            BackupUploadOwnership(owner: current.owner, generation: UUID()),
        ]

        for phase in [BackupUploadPhase.primaryAsset, .livePhotoMotion] {
            for staleOwnership in staleOwnerships {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-owner-\(UUID())")
                let temporary = root.appendingPathComponent("tmp")
                let recovery = root.appendingPathComponent("recovery")
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let bytes = Data("only remaining original".utf8)
                let preserved = try recoveryContext(in: temporary, phase: phase, ownership: current, bytes: bytes)
                XCTAssertTrue(try BackupTemporaryFiles.finish(preserved, succeeded: false, sourceAvailable: false,
                    in: temporary, recovery: recovery))
                let saved = recovery.appendingPathComponent(URL(fileURLWithPath: preserved.bodyPath).lastPathComponent)
                let receipt = saved.appendingPathExtension("json")
                let savedReceipt = try Data(contentsOf: receipt)
                XCTAssertEqual(BackupTemporaryFiles.recordedContexts(in: recovery), [preserved])

                let stale = try recoveryContext(in: temporary, phase: phase, ownership: staleOwnership, bytes: bytes)
                XCTAssertFalse(try BackupTemporaryFiles.finish(stale, succeeded: true, sourceAvailable: false,
                    in: temporary, recovery: recovery))

                XCTAssertFalse(FileManager.default.fileExists(atPath: stale.bodyPath),
                    "An old callback may still release its own unique temporary body")
                XCTAssertFalse(FileManager.default.fileExists(atPath: stale.bodyPath + ".json"))
                XCTAssertEqual(try Data(contentsOf: saved), bytes,
                    "Another owner or generation cannot delete this account's only recovery copy")
                XCTAssertEqual(try Data(contentsOf: receipt), savedReceipt)
                XCTAssertEqual(BackupTemporaryFiles.recordedContexts(in: recovery), [preserved])

                let matching = try recoveryContext(in: temporary, phase: phase, ownership: current, bytes: bytes)
                try BackupTemporaryFiles.finish(matching, succeeded: true, sourceAvailable: true,
                    in: temporary, recovery: recovery)

                XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path),
                    "A confirmed upload for the same ownership and content must retire its recovery copy")
                XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: matching.bodyPath))
                XCTAssertTrue(BackupTemporaryFiles.recordedContexts(in: recovery).isEmpty)
            }
        }
    }

    func testUnownedRecoveryReceiptsCannotBeRetiredByLegacyOrOwnedSuccesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-recovery-\(UUID())")
        let temporary = root.appendingPathComponent("tmp")
        let recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownership = BackupUploadOwnership(
            owner: BackupQueueOwner(server: "https://backup.example/api", userID: "current"), generation: UUID())
        let bytes = Data("unattributed original".utf8)
        let unowned = try recoveryContext(in: temporary, phase: .primaryAsset, ownership: nil, bytes: bytes)
        let owned = try recoveryContext(in: temporary, phase: .primaryAsset, ownership: ownership, bytes: bytes)
        for context in [unowned, owned] {
            XCTAssertTrue(try BackupTemporaryFiles.finish(context, succeeded: false, sourceAvailable: false,
                in: temporary, recovery: recovery))
        }
        let legacyBody = recovery.appendingPathComponent(URL(fileURLWithPath: unowned.bodyPath).lastPathComponent)
        let ownedBody = recovery.appendingPathComponent(URL(fileURLWithPath: owned.bodyPath).lastPathComponent)
        let legacyReceipt = try Data(contentsOf: legacyBody.appendingPathExtension("json"))
        let ownedReceipt = try Data(contentsOf: ownedBody.appendingPathExtension("json"))
        XCTAssertEqual(Set(BackupTemporaryFiles.recordedContexts(in: recovery).map(\.bodyPath)),
            Set([unowned.bodyPath, owned.bodyPath]))

        let legacySuccess = try recoveryContext(in: temporary, phase: .primaryAsset, ownership: nil, bytes: bytes)
        try BackupTemporaryFiles.finish(legacySuccess, succeeded: true, sourceAvailable: true,
            in: temporary, recovery: recovery)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySuccess.bodyPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySuccess.bodyPath + ".json"))
        XCTAssertEqual(try Data(contentsOf: legacyBody), bytes)
        XCTAssertEqual(try Data(contentsOf: legacyBody.appendingPathExtension("json")), legacyReceipt)
        XCTAssertEqual(try Data(contentsOf: ownedBody), bytes,
            "An unidentified callback cannot clear a receipt with a known owner")
        XCTAssertEqual(try Data(contentsOf: ownedBody.appendingPathExtension("json")), ownedReceipt)

        let currentSuccess = try recoveryContext(in: temporary, phase: .primaryAsset, ownership: ownership, bytes: bytes)
        try BackupTemporaryFiles.finish(currentSuccess, succeeded: true, sourceAvailable: true,
            in: temporary, recovery: recovery)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedBody.path))
        XCTAssertEqual(try Data(contentsOf: legacyBody), bytes,
            "A current account's success cannot claim an unattributed legacy copy")
        XCTAssertEqual(try Data(contentsOf: legacyBody.appendingPathExtension("json")), legacyReceipt)
        XCTAssertEqual(BackupTemporaryFiles.recordedContexts(in: recovery), [unowned])
    }

    private func recoveryContext(
        in directory: URL, phase: BackupUploadPhase, ownership: BackupUploadOwnership?, bytes: Data
    ) throws -> BackupUploadTaskContext {
        let body = directory.appendingPathComponent("upload-\(UUID()).multipart")
        try bytes.write(to: body)
        let context = BackupUploadTaskContext(phase: phase, localIdentifier: "same-photo", checksum: "same-checksum",
            bodyPath: body.path, ownership: ownership)
        try BackupTemporaryFiles.record(context, in: directory)
        return context
    }

    func testReceiptsProtectMediaDuringColdLaunchAndFailedCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("upload-owned.multipart")
        try Data([1, 2, 3]).write(to: body)
        let context = BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "photo", checksum: "sha", bodyPath: body.path)
        try BackupTemporaryFiles.record(context, in: root)
        XCTAssertEqual(BackupTemporaryFiles.recordedContexts(in: root), [context])

        // Simulate an unwritable destination: cleanup must leave source + receipt.
        let invalidRecovery = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalidRecovery)
        XCTAssertThrowsError(try BackupTemporaryFiles.finish(
            context, succeeded: false, sourceAvailable: false, in: root, recovery: invalidRecovery))
        BackupTemporaryFiles.cleanupOrphans(in: root, activeBodyPaths: [], olderThan: .distantFuture)
        XCTAssertEqual(try Data(contentsOf: body), Data([1, 2, 3]))

        // Corrupt ownership metadata is not permission to delete the media.
        try Data("invalid".utf8).write(to: body.appendingPathExtension("json"))
        BackupTemporaryFiles.cleanupOrphans(in: root, activeBodyPaths: [], olderThan: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
    }

    func testUpgradeShrinksExistingFortyGBQueueInsteadOfProtectingEveryUpload() {
        let oldUploads = (1...100).map {
            BackupStagingPolicy.Upload(
                taskIdentifier: $0, bytes: 400_000_000, progress: $0 == 73 ? 0.9 : 0)
        }
        let retained = BackupStagingPolicy.retainedTaskIDs(from: oldUploads)
        XCTAssertEqual(retained, [73])
        let releasedBytes = oldUploads.filter { !retained.contains($0.taskIdentifier) }
            .reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(releasedBytes, 39_600_000_000)
        // Relaunch must not continually cancel the one oversized video left.
        XCTAssertEqual(BackupStagingPolicy.retainedTaskIDs(
            from: oldUploads.filter { retained.contains($0.taskIdentifier) }), retained)
    }

    func testUpgradeHonorsBothTaskAndByteLimits() {
        let megabyte = 1024 * 1024
        let uploads = (1...10).map {
            BackupStagingPolicy.Upload(taskIdentifier: $0, bytes: 100 * megabyte, progress: 0)
        }
        XCTAssertEqual(BackupStagingPolicy.retainedTaskIDs(from: uploads), [1, 2])
        let smallUploads = (1...10).map {
            BackupStagingPolicy.Upload(taskIdentifier: $0, bytes: megabyte, progress: 0)
        }
        XCTAssertEqual(BackupStagingPolicy.retainedTaskIDs(from: smallUploads), [1, 2, 3])
    }

    func testRecoveryNeverReclaimsTheOnlyRemainingCopyOfAnOriginal() {
        let uploads = (1...5).map {
            BackupStagingPolicy.Upload(taskIdentifier: $0, bytes: 500_000_000, progress: $0 == 1 ? 0.9 : 0)
        }
        XCTAssertEqual(BackupStagingPolicy.retainedTaskIDs(
            from: uploads, protectedTaskIDs: [4, 5]), [4, 5])
    }

    func testStorageRecoveryContextSurvivesRelaunchAndReadsLegacyTasks() throws {
        let original = BackupUploadTaskContext(
            phase: .livePhotoMotion, localIdentifier: "live", checksum: "sha",
            bodyPath: "/old/tmp/upload-live.multipart")
        XCTAssertNil(BackupUploadTaskContext.decode(original.encoded)?.isStorageRecovery)
        var recovering = original
        recovering.isStorageRecovery = true
        XCTAssertEqual(BackupUploadTaskContext.decode(recovering.encoded), recovering)
        let legacy = ["local", "checksum", "/old/tmp/upload-local.multipart"].joined(separator: "\u{1}")
        XCTAssertNil(try XCTUnwrap(BackupUploadTaskContext.decode(legacy)).isStorageRecovery)
    }

    @MainActor
    func testUpgradeRequeuesReleasedFilesAndKeepsLivePhotoMapping() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-recovery-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL)
        try queue.enqueue(["live"])
        try queue.markPreparing("live", phase: .primaryAsset, motionAssetID: "server-motion")
        try queue.markUploading("live", phase: .primaryAsset, checksum: "sha", taskIdentifier: 42)
        try queue.requeueAfterStorageRecovery("live", taskIdentifier: 42)

        let restored = BackupQueueStore(fileURL: queueURL)
        XCTAssertEqual(restored.readyItems().map(\.id), ["live"])
        XCTAssertEqual(restored.item(id: "live")?.motionAssetID, "server-motion")
        XCTAssertEqual(restored.item(id: "live")?.phase, .primaryAsset)
        XCTAssertEqual(restored.snapshot.failed, 0)
        XCTAssertNil(restored.item(id: "live")?.taskIdentifier)

        try restored.markPreparing("live", phase: .primaryAsset, motionAssetID: "server-motion")
        try restored.markUploading("live", phase: .primaryAsset, checksum: "sha", taskIdentifier: 43)
        // A late callback from the reclaimed task cannot reset the new upload.
        XCTAssertFalse(try restored.requeueAfterStorageRecovery("live", taskIdentifier: 42))
        XCTAssertEqual(restored.item(id: "live")?.taskIdentifier, 43)
        XCTAssertEqual(restored.item(id: "live")?.state, .uploading)

        try restored.markCancelling("live")
        try restored.requeueAfterStorageRecovery("live", taskIdentifier: 43)
        XCTAssertEqual(restored.item(id: "live")?.state, .failed)
        XCTAssertTrue(restored.readyItems().isEmpty)
    }

    func testColdLaunchRemovesOrphansButPreservesActiveAndNewFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cutoff = Date()
        let names = ["upload-orphan.multipart", "backup-source-orphan.mov",
                     "upload-active.multipart", "upload-new.multipart", "unrelated.json"]
        for name in names {
            let file = directory.appendingPathComponent(name)
            try Data(repeating: 1, count: 64).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: cutoff.addingTimeInterval(name == "upload-new.multipart" ? 60 : -60)],
                ofItemAtPath: file.path)
        }
        let folder = directory.appendingPathComponent("backup-source-directory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The container prefix can change during an app update.
        BackupTemporaryFiles.cleanupOrphans(
            in: directory,
            activeBodyPaths: ["/previous-container/tmp/upload-active.multipart"],
            olderThan: cutoff)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(names[0]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(names[1]).path))
        for name in names.dropFirst(2) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testStagingStopsAtGlobalTaskOrByteThreshold() {
        XCTAssertTrue(BackupStagingPolicy.canPrepare(activeCount: 0, stagedBytes: 0))
        XCTAssertTrue(BackupStagingPolicy.canPrepare(activeCount: 2, stagedBytes: 100))
        XCTAssertFalse(BackupStagingPolicy.canPrepare(activeCount: 3, stagedBytes: 100))
        XCTAssertFalse(BackupStagingPolicy.canPrepare(activeCount: 100, stagedBytes: 0))
        XCTAssertFalse(BackupStagingPolicy.canPrepare(activeCount: 1, stagedBytes: 256 * 1024 * 1024))
        XCTAssertFalse(BackupStagingPolicy.canPrepare(activeCount: 1, stagedBytes: 40_000_000_000))
    }

    func testBodyPathIsResolvedInsideCurrentTempContainer() {
        let directory = URL(fileURLWithPath: "/current-container/tmp")
        XCTAssertEqual(
            BackupTemporaryFiles.bodyURL(for: "/old-container/tmp/upload-a.multipart", in: directory),
            directory.appendingPathComponent("upload-a.multipart"))
        XCTAssertNil(BackupTemporaryFiles.bodyURL(for: "/private/important-file", in: directory))
    }

    @MainActor
    func testFullWindowSurvivesRelaunchAndReleasesASlotAfterCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-window-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL)
        try queue.enqueue((0..<100).map { "asset-\($0)" })
        for index in 0..<3 {
            try queue.markPreparing("asset-\(index)", phase: .primaryAsset)
            try queue.markUploading(
                "asset-\(index)", phase: .primaryAsset,
                checksum: "checksum-\(index)", taskIdentifier: index + 1)
        }

        let restored = BackupQueueStore(fileURL: queueURL)
        XCTAssertEqual(restored.snapshot.queued, 97)
        XCTAssertFalse(BackupStagingPolicy.canPrepare(
            activeCount: restored.snapshot.active, stagedBytes: 1024))

        try restored.markCompleted("asset-0")
        XCTAssertTrue(BackupStagingPolicy.canPrepare(
            activeCount: restored.snapshot.active, stagedBytes: 1024))
        let next = try XCTUnwrap(restored.readyItems(limit: 1).first)
        try restored.markPreparing(next.id, phase: .primaryAsset)
        XCTAssertEqual(restored.snapshot.active, 3)
        XCTAssertFalse(BackupStagingPolicy.canPrepare(
            activeCount: restored.snapshot.active, stagedBytes: 1024))
    }

    func testStorageMeasurementIncludesNestedAndHiddenFilesWithoutDoubleCounting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-usage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("app")
        let shared = directory.appendingPathComponent("shared")
        let files = [
            home.appendingPathComponent("Library/Caches/immich-image-cache/image"),
            home.appendingPathComponent("Library/Caches/network/.hidden/body"),
            home.appendingPathComponent("tmp/upload-test.multipart"),
            home.appendingPathComponent("tmp/backup-source-test.mov"),
            home.appendingPathComponent("tmp/share/video.mov"),
            home.appendingPathComponent("Library/Application Support/default.store-wal"),
            shared.appendingPathComponent("ShareUploadInbox/batch/video.mov"),
            home.appendingPathComponent(BackupTemporaryFiles.recoveryRelativePath + "/upload-preserved.multipart"),
        ]
        for file in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: file)
        }
        let sizes = try files.map {
            let values = try $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        }
        let alias = directory.appendingPathComponent("container-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        // Production constructs its home URL with isDirectory: true. Also
        // exercise aliases such as /var and /private/var on physical devices.
        let roots = [
            home,
            URL(fileURLWithPath: home.path + "/", isDirectory: true),
            URL(fileURLWithPath: alias.path, isDirectory: true),
        ]
        for root in roots {
            let usage = AppStorageUsage.scan(home: root, shared: shared)
            XCTAssertEqual(usage.imageCache, sizes[0], root.absoluteString)
            XCTAssertEqual(usage.otherCaches, sizes[1], root.absoluteString)
            XCTAssertEqual(usage.backupFiles, sizes[2] + sizes[3], root.absoluteString)
            XCTAssertEqual(usage.temporaryFiles, sizes[4], root.absoluteString)
            XCTAssertEqual(usage.appData, sizes[5], root.absoluteString)
            XCTAssertEqual(usage.sharedData, sizes[6], root.absoluteString)
            XCTAssertEqual(usage.recoveredUploads, sizes[7], root.absoluteString)
            XCTAssertEqual(usage.total, sizes.reduce(0, +), root.absoluteString)
        }
    }
}
