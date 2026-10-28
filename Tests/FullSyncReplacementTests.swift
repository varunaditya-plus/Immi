import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class FullSyncReplacementTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DeletedServerAssetRegistry.shared.clear()
        RemovedAssets.shared.clear()
    }

    override func tearDown() async throws {
        DeletedServerAssetRegistry.shared.clear()
        RemovedAssets.shared.clear()
        try await super.tearDown()
    }

    func testFullSnapshotRestoresDurableTrashEvidenceAndSuppressesOnlyKnownStaleTrashRows() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        DeletedServerAssetRegistry.shared.record(["keep", "still-trashed"], permanently: false)
        let snapshot = ["keep", "still-trashed", "ordinary"].map { AssetLite(makeTestAsset(id: $0)) }
        LocalSnapshot.save(snapshot, for: LocalSnapshot.Key.trash)
        defer { LocalSnapshot.remove(LocalSnapshot.Key.trash) }
        XCTAssertTrue(RemovedAssets.shared.ids.isEmpty)
        fixture.transport.responses = [.body(FullSyncTransport.asset("keep")
            + FullSyncTransport.asset("ordinary") + FullSyncTransport.complete)]

        try await fixture.repository.fullSync()

        XCTAssertFalse(DeletedServerAssetRegistry().isTrashed("keep"))
        XCTAssertNotNil(fixture.reopen().getCachedAsset(id: "keep"))
        let library = AssetVisibilityPolicy(dataManager: fixture.dataManager)
        let trash = AssetVisibilityPolicy(removalScope: .trash, dataManager: fixture.dataManager)
        XCTAssertTrue(library.allows(id: "keep"))
        XCTAssertFalse(trash.allows(id: "keep"))
        XCTAssertTrue(trash.allows(id: "ordinary"), "Full snapshots must only suppress IDs previously known to be soft-deleted")
        RemovedAssets.shared.clear()
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.trash)?.map(\.id),
            ["still-trashed", "ordinary"], "A second launch must retain other rows without reviving the confirmed restore")
        XCTAssertTrue(DeletedServerAssetRegistry().isTrashed("still-trashed"))
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
    }

    func testMalformedStreamAfterMoreThanOneBatchPreservesWorkingCacheAndRegistries() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        DeletedServerAssetRegistry.shared.record(["keep"], permanently: false)
        fixture.transport.responses = [.body(
            FullSyncTransport.assets(700)
            + FullSyncTransport.asset("keep", favorite: true)
            + FullSyncTransport.deletion("stale") + "{broken-json}\n")]

        await expectFailure { try await fixture.repository.fullSync() }

        try assertOriginalCache(fixture)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("keep"),
            "A discarded active row must not restore the deletion registry")
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains("stale"),
            "A discarded deletion must not suppress a working photo")
        XCTAssertTrue(RemovedAssets.shared.ids.isEmpty)
    }

    func testTransportHTTPAndMissingCompletionFailuresKeepOriginalSnapshot() async throws {
        let responses: [FullSyncTransport.Response] = [
            .failure, .status(503), .body(FullSyncTransport.assets(700)), .body("")
        ]
        for response in responses {
            let fixture = try FullSyncFixture()
            defer { fixture.cleanup() }
            fixture.transport.responses = [response]
            await expectFailure { try await fixture.repository.fullSync() }
            try assertOriginalCache(fixture)
        }
    }

    func testServerVersionFailureDoesNotClearWorkingCacheOrRequestAStream() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.session.failVersion = true

        await expectFailure { try await fixture.repository.fullSync() }

        try assertOriginalCache(fixture)
        XCTAssertEqual(fixture.transport.streamRequestCount, 0)
    }

    func testResetDiscardsStagedRowsAndRetryFailureKeepsWorkingCache() async throws {
        for secondResponse: FullSyncTransport.Response in [
            .body(FullSyncTransport.reset), .status(500)
        ] {
            let fixture = try FullSyncFixture()
            defer { fixture.cleanup() }
            fixture.transport.responses = [
                .body(FullSyncTransport.assets(700) + FullSyncTransport.deletion("stale")
                    + FullSyncTransport.reset), secondResponse
            ]

            await expectFailure { try await fixture.repository.fullSync() }

            try assertOriginalCache(fixture)
            XCTAssertEqual(fixture.transport.streamRequestCount, 2)
            XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains("stale"))
        }
    }

    func testSuccessfulResetRetryPublishesOnlyTheCompletedAttempt() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [
            .body(FullSyncTransport.assets(700) + FullSyncTransport.reset),
            .body(FullSyncTransport.asset("replacement") + FullSyncTransport.complete)
        ]

        try await fixture.repository.fullSync()

        XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), ["replacement"])
        XCTAssertEqual(fixture.reopen().cachedAssetCount(), 1)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
        XCTAssertEqual(fixture.dataManager.getSyncState().totalAssets, 1)
    }

    func testFullSnapshotUpdatesRegisteredObjectsRemovesStaleRowsAndPreservesPrivateMappings() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        let registered = try XCTUnwrap(fixture.dataManager.getCachedAsset(id: "keep"))
        try fixture.dataManager.setAssetVisibility(["uncached-private"], to: "locked")
        try fixture.dataManager.insertBackupRecord(BackupRecord(id: "mapping", assetId: "uncached-private",
            deviceAssetId: "checksum", localIdentifier: "device-photo"))
        fixture.transport.responses = [.body(
            FullSyncTransport.asset("keep", favorite: true)
            + FullSyncTransport.assets(700)
            + FullSyncTransport.asset("archive", visibility: "archive")
            + FullSyncTransport.asset("locked", visibility: "locked")
            + FullSyncTransport.complete)]

        try await fixture.repository.fullSync()

        XCTAssertTrue(registered.isFavorite, "Existing UI model references must see the replacement")
        XCTAssertTrue(try XCTUnwrap(fixture.dataManager.getCachedAsset(id: "keep")).isFavorite)
        XCTAssertNil(fixture.dataManager.getCachedAsset(id: "stale"))
        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 703)
        XCTAssertEqual(fixture.dataManager.privateAssetIDs, ["uncached-private", "locked"])
        XCTAssertEqual(fixture.dataManager.archivedAssetIDs, ["archive"])
        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "device-photo")?.assetId,
            "uncached-private")
        let reopened = fixture.reopen()
        XCTAssertTrue(try XCTUnwrap(reopened.getCachedAsset(id: "keep")).isFavorite)
        XCTAssertNil(reopened.getCachedAsset(id: "stale"))
        XCTAssertEqual(reopened.cachedAssetCount(), 703)
        XCTAssertEqual(reopened.privateAssetIDs, ["uncached-private", "locked"])
        XCTAssertEqual(reopened.archivedAssetIDs, ["archive"])
        XCTAssertEqual(reopened.getBackupRecord(localIdentifier: "device-photo")?.assetId, "uncached-private")
        XCTAssertEqual(fixture.transport.acknowledgments.last,
            Set(["AssetV2|locked", "SyncCompleteV1|complete"]))
        XCTAssertGreaterThan(try XCTUnwrap(fixture.dataManager.getSyncState().lastFullSyncAt), fixture.checkpoint)
        XCTAssertEqual(fixture.dataManager.getSyncState().totalAssets, 703)
    }

    func testCompletedEmptySnapshotReplacesCacheButKeepsCheckpointUntilAcknowledged() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [.body(FullSyncTransport.complete)]
        fixture.transport.holdAcknowledgment = true
        let ackStarted = expectation(description: "Acknowledgment starts after promotion")
        fixture.transport.onAcknowledgment = { ackStarted.fulfill() }
        let sync = Task { try await fixture.repository.fullSync() }
        await fulfillment(of: [ackStarted], timeout: 5)

        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 0)
        XCTAssertEqual(fixture.reopen().cachedAssetCount(), 0)
        XCTAssertEqual(fixture.dataManager.getSyncState().lastFullSyncAt, fixture.checkpoint)
        fixture.transport.finishAcknowledgment(failing: true)
        await expectFailure { try await sync.value }

        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 0,
            "An acknowledgment failure may retain the complete valid replacement")
        XCTAssertEqual(fixture.dataManager.getSyncState().lastDeltaSyncAt, fixture.checkpoint)
        XCTAssertEqual(fixture.dataManager.getSyncState().totalAssets, 2)
    }

    func testCompletedEmptySnapshotCanBeAcknowledgedAndSaveZeroCount() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [.body(FullSyncTransport.complete)]

        try await fixture.repository.fullSync()

        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 0)
        XCTAssertEqual(fixture.dataManager.getSyncState().totalAssets, 0)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.dataManager.getSyncState().lastDeltaSyncAt), fixture.checkpoint)
    }

    func testCancellationAccountChangesAndAcceptedLocalActionsRejectHeldSnapshot() async throws {
        for change in ["cancel", "account", "visibility", "metadata"] {
            let fixture = try FullSyncFixture()
            defer { fixture.cleanup() }
            fixture.transport.responses = [.held(FullSyncTransport.assets(700))]
            let started = expectation(description: "Full stream started: \(change)")
            fixture.transport.onStream = { started.fulfill() }
            let sync = Task { try await fixture.repository.fullSync() }
            await fulfillment(of: [started], timeout: 5)
            XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 2,
                "An incomplete snapshot must not clear or publish its first chunk")
            switch change {
            case "cancel": sync.cancel()
            case "account":
                LocalSnapshot.clearAll()
                try fixture.dataManager.clearAllAccountData()
                try fixture.dataManager.insertOrUpdateCachedAsset(
                    CachedAsset(id: "next-account", assetId: "next-account", type: "IMAGE"))
            case "visibility": try fixture.dataManager.setAssetVisibility(["keep"], to: "locked")
            default: try fixture.dataManager.patchCachedAsset("keep", isFavorite: true)
            }
            fixture.transport.finishStream(with: FullSyncTransport.asset("keep") + FullSyncTransport.complete)
            do {
                try await sync.value
                XCTFail("The held snapshot must be rejected after \(change)")
            } catch is CancellationError {
            }
            XCTAssertEqual(fixture.transport.acknowledgmentCount, 0)
            if change == "account" {
                XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), ["next-account"])
                XCTAssertNil(fixture.dataManager.getSyncState().lastDeltaSyncAt)
            } else {
                XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 2)
                XCTAssertNotNil(fixture.dataManager.getCachedAsset(id: "stale"))
                XCTAssertEqual(fixture.dataManager.getSyncState().lastDeltaSyncAt, fixture.checkpoint)
                if change == "visibility" { XCTAssertTrue(fixture.dataManager.privateAssetIDs.contains("keep")) }
                if change == "metadata" {
                    XCTAssertTrue(try XCTUnwrap(fixture.dataManager.getCachedAsset(id: "keep")).isFavorite)
                }
            }
        }
    }

    func testJournalFailureRollsBackReplacementWithoutAcknowledgment() async throws {
        let fileManager = FullSyncFileManager()
        let fixture = try FullSyncFixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let oldJournal = try Data(contentsOf: fixture.journalURL)
        fileManager.rejectWrites = true
        fixture.transport.responses = [.body(
            FullSyncTransport.asset("keep", favorite: true, visibility: "locked")
            + FullSyncTransport.asset("new") + FullSyncTransport.deletion("stale")
            + FullSyncTransport.complete)]

        await expectFailure { try await fixture.repository.fullSync() }

        try assertOriginalCache(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal)
        XCTAssertTrue(fixture.dataManager.privateAssetIDs.isEmpty)
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains("stale"))
        XCTAssertTrue(RemovedAssets.shared.ids.isEmpty)
    }

    func testFullSnapshotUsesLastEventForDuplicateRowsAndStagesDeletionEffects() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [.body(
            FullSyncTransport.asset("keep", favorite: false, visibility: "locked")
            + FullSyncTransport.deletion("keep", permanently: false)
            + FullSyncTransport.assets(500)
            + FullSyncTransport.asset("keep", favorite: true)
            + FullSyncTransport.asset("removed")
            + FullSyncTransport.deletion("removed", permanently: false)
            + FullSyncTransport.deletion("stale") + FullSyncTransport.complete)]

        try await fixture.repository.fullSync()

        XCTAssertTrue(try XCTUnwrap(fixture.dataManager.getCachedAsset(id: "keep")).isFavorite)
        XCTAssertFalse(fixture.dataManager.nonTimelineAssetIDs.contains("keep"))
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains("keep"))
        XCTAssertNil(fixture.dataManager.getCachedAsset(id: "removed"))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("removed"))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted("stale"))
        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 501)
        XCTAssertEqual(fixture.reopen().cachedAssetCount(), 501)
    }

    func testLastActiveRowCancelsStagedPermanentDeleteWithoutClearingPriorConfirmedDeletes() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        DeletedServerAssetRegistry.shared.record(["previously-deleted"], permanently: true)
        fixture.transport.responses = [.body(
            FullSyncTransport.deletion("restored")
            + FullSyncTransport.asset("restored")
            + FullSyncTransport.asset("previously-deleted")
            + FullSyncTransport.deletion("soft-final")
            + FullSyncTransport.deletion("soft-final", permanently: false)
            + FullSyncTransport.complete)]

        try await fixture.repository.fullSync()

        XCTAssertNotNil(fixture.dataManager.getCachedAsset(id: "restored"))
        XCTAssertFalse(DeletedServerAssetRegistry.shared.isPermanentlyDeleted("restored"),
            "Only the last event in this completed snapshot should be published")
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted("previously-deleted"),
            "A stale active row must not undo suppression from an earlier confirmed permanent delete")
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("soft-final"))
        XCTAssertFalse(DeletedServerAssetRegistry.shared.isPermanentlyDeleted("soft-final"))
        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 2)
        XCTAssertEqual(fixture.reopen().cachedAssetCount(), 2)
    }

    func testNewerDeltaFromAnotherRepositoryInvalidatesAHeldFullSnapshot() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [
            .held(FullSyncTransport.assets(700)),
            .body(FullSyncTransport.asset("keep", favorite: true)
                + FullSyncTransport.asset("delta-new") + FullSyncTransport.complete)
        ]
        let started = expectation(description: "Older full snapshot is held")
        fixture.transport.onStream = { [weak transport = fixture.transport] in
            if transport?.streamRequestCount == 1 { started.fulfill() }
        }
        let full = Task { try await fixture.repository.fullSync() }
        await fulfillment(of: [started], timeout: 5)

        try await fixture.anotherRepository().deltaSync()
        let deltaCheckpoint = fixture.dataManager.getSyncState().lastDeltaSyncAt
        fixture.transport.finishStream(with: FullSyncTransport.asset("keep") + FullSyncTransport.complete)
        do {
            try await full.value
            XCTFail("The older full snapshot must not replace the accepted delta")
        } catch is CancellationError {}

        for store in [fixture.dataManager, fixture.reopen()] {
            XCTAssertEqual(store.cachedAssetCount(), 3)
            XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "keep")).isFavorite)
            XCTAssertNotNil(store.getCachedAsset(id: "delta-new"))
            XCTAssertNotNil(store.getCachedAsset(id: "stale"))
            XCTAssertNil(store.getCachedAsset(id: "download-0"))
            XCTAssertEqual(store.getSyncState().lastFullSyncAt, fixture.checkpoint)
            XCTAssertEqual(store.getSyncState().lastDeltaSyncAt, deltaCheckpoint)
            XCTAssertEqual(store.getSyncState().totalAssets, 3)
        }
        XCTAssertGreaterThan(try XCTUnwrap(deltaCheckpoint), fixture.checkpoint)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
    }

    func testNewerFullSnapshotInvalidatesAHeldDeltaFromAnotherRepository() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [
            .held(FullSyncTransport.asset("keep")),
            .body(FullSyncTransport.asset("keep", favorite: true)
                + FullSyncTransport.asset("full-new") + FullSyncTransport.complete)
        ]
        let started = expectation(description: "Older delta is held")
        fixture.transport.onStream = { [weak transport = fixture.transport] in
            if transport?.streamRequestCount == 1 { started.fulfill() }
        }
        let delta = Task { try await fixture.repository.deltaSync() }
        await fulfillment(of: [started], timeout: 5)

        try await fixture.anotherRepository().fullSync()
        let fullCheckpoint = fixture.dataManager.getSyncState().lastFullSyncAt
        fixture.transport.finishStream(with: FullSyncTransport.asset("old-delta-new") + FullSyncTransport.complete)
        do {
            try await delta.value
            XCTFail("An older delta must not overwrite a newly accepted full snapshot")
        } catch is CancellationError {}

        for store in [fixture.dataManager, fixture.reopen()] {
            XCTAssertEqual(store.cachedAssetCount(), 2)
            XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "keep")).isFavorite)
            XCTAssertNotNil(store.getCachedAsset(id: "full-new"))
            XCTAssertNil(store.getCachedAsset(id: "old-delta-new"))
            XCTAssertNil(store.getCachedAsset(id: "stale"))
            XCTAssertEqual(store.getSyncState().lastFullSyncAt, fullCheckpoint)
            XCTAssertEqual(store.getSyncState().lastDeltaSyncAt, fullCheckpoint)
            XCTAssertEqual(store.getSyncState().totalAssets, 2)
        }
        XCTAssertGreaterThan(try XCTUnwrap(fullCheckpoint), fixture.checkpoint)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
    }

    func testDeltaTracksItsOwnRevisionAcrossMultipleAcceptedBatches() async throws {
        let fixture = try FullSyncFixture()
        defer { fixture.cleanup() }
        fixture.transport.responses = [.body(FullSyncTransport.assets(1_200)
            + FullSyncTransport.asset("keep", favorite: true) + FullSyncTransport.complete)]

        try await fixture.repository.deltaSync()

        for store in [fixture.dataManager, fixture.reopen()] {
            XCTAssertEqual(store.cachedAssetCount(), 1_202)
            XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "keep")).isFavorite)
            XCTAssertNotNil(store.getCachedAsset(id: "download-0"))
            XCTAssertNotNil(store.getCachedAsset(id: "download-1199"))
            XCTAssertEqual(store.getSyncState().totalAssets, 1_202)
            XCTAssertGreaterThan(try XCTUnwrap(store.getSyncState().lastDeltaSyncAt), fixture.checkpoint)
        }
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
    }

    func testLateAcknowledgmentCannotOverwriteANewerSyncCheckpoint() async throws {
        for full in [false, true] {
            let fixture = try FullSyncFixture()
            defer { fixture.cleanup() }
            fixture.transport.responses = [
                .body(FullSyncTransport.asset("keep") + FullSyncTransport.complete),
                .body(FullSyncTransport.asset("keep", favorite: true)
                    + FullSyncTransport.asset("newest") + FullSyncTransport.complete)
            ]
            fixture.transport.holdAcknowledgment = true
            let started = expectation(description: "Older sync acknowledgment is held")
            fixture.transport.onAcknowledgment = { [weak transport = fixture.transport] in
                if transport?.acknowledgmentCount == 1 { started.fulfill() }
            }
            let old = Task {
                if full { try await fixture.repository.fullSync() }
                else { try await fixture.repository.deltaSync() }
            }
            await fulfillment(of: [started], timeout: 5)
            fixture.transport.holdAcknowledgment = false
            try await fixture.anotherRepository().deltaSync()
            let currentCheckpoint = fixture.dataManager.getSyncState().lastDeltaSyncAt
            fixture.transport.finishAcknowledgment(failing: false)
            do {
                try await old.value
                XCTFail("The older acknowledgment must not overwrite the accepted sync checkpoint")
            } catch is CancellationError {}

            for store in [fixture.dataManager, fixture.reopen()] {
                XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "keep")).isFavorite)
                XCTAssertNotNil(store.getCachedAsset(id: "newest"))
                XCTAssertEqual(store.getSyncState().lastDeltaSyncAt, currentCheckpoint)
                XCTAssertEqual(store.getSyncState().totalAssets, full ? 2 : 3)
            }
            XCTAssertEqual(fixture.transport.acknowledgmentCount, 2)
        }
    }

    private func expectFailure(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("The operation must fail")
        } catch {}
    }

    private func assertOriginalCache(_ fixture: FullSyncFixture,
        file: StaticString = #filePath, line: UInt = #line) throws {
        for store in [fixture.dataManager, fixture.reopen()] {
            XCTAssertEqual(store.cachedAssetCount(), 2, file: file, line: line)
            XCTAssertNotNil(store.getCachedAsset(id: "stale"), file: file, line: line)
            XCTAssertFalse(try XCTUnwrap(store.getCachedAsset(id: "keep"), file: file, line: line).isFavorite,
                file: file, line: line)
            XCTAssertEqual(store.getSyncState().lastFullSyncAt, fixture.checkpoint, file: file, line: line)
            XCTAssertEqual(store.getSyncState().lastDeltaSyncAt, fixture.checkpoint, file: file, line: line)
            XCTAssertEqual(store.getSyncState().totalAssets, 2, file: file, line: line)
        }
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 0, file: file, line: line)
    }
}

@MainActor
private final class FullSyncFixture {
    let directory: URL
    private var storedDataManager: SwiftDataManager?
    var dataManager: SwiftDataManager { storedDataManager! }
    let session = FullSyncSession()
    private var storedRepository: SyncRepository?
    var repository: SyncRepository { storedRepository! }
    let transport = FullSyncTransport()
    let checkpoint = Date(timeIntervalSince1970: 1_700_000_000)
    private let urlSession: URLSession
    var storeURL: URL { directory.appendingPathComponent("test.store") }
    var journalURL: URL { directory.appendingPathComponent("backup.json") }

    init(fileManager: FileManager = .default) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("full-sync-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FullSyncURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
        storedDataManager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"), fileManager: fileManager)
        try dataManager.insertOrUpdateCachedAsset(CachedAsset(id: "keep", assetId: "keep", type: "IMAGE"))
        try dataManager.insertOrUpdateCachedAsset(CachedAsset(id: "stale", assetId: "stale", type: "IMAGE"))
        let state = dataManager.getSyncState()
        state.lastFullSyncAt = checkpoint
        state.lastDeltaSyncAt = checkpoint
        state.totalAssets = 2
        try dataManager.updateSyncState(state)
        try session.setServer(transport.baseURL.absoluteString)
        storedRepository = SyncRepository(api: APIClient(session: session, urlSession: urlSession),
            dataManager: dataManager)
    }

    func reopen() -> SwiftDataManager { SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL) }

    func anotherRepository() -> SyncRepository {
        SyncRepository(api: APIClient(session: session, urlSession: urlSession), dataManager: dataManager)
    }

    func cleanup() {
        urlSession.invalidateAndCancel()
        transport.close()
        storedRepository = nil
        storedDataManager = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class FullSyncSession: MockSessionManager {
    var failVersion = false
    override func serverVersion() async throws -> ServerVersionDTO {
        if failVersion { throw APIError.server(status: 503, message: "version unavailable") }
        return try await super.serverVersion()
    }
}

private final class FullSyncFileManager: FileManager, @unchecked Sendable {
    var rejectWrites = false
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
        attributes: [FileAttributeKey: Any]? = nil) throws {
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes)
    }
}

private final class FullSyncTransport: @unchecked Sendable {
    enum Response { case body(String), held(String), status(Int), failure }
    let baseURL = URL(string: "https://full-sync-\(UUID().uuidString.lowercased()).invalid")!
    var responses: [Response] = []
    var holdAcknowledgment = false
    var onStream: (() -> Void)?
    var onAcknowledgment: (() -> Void)?
    private let lock = NSLock()
    private var stream: FullSyncURLProtocol?
    private var acknowledgment: FullSyncURLProtocol?
    private var requestCount = 0
    private var acks: [Set<String>] = []
    var streamRequestCount: Int { lock.withLock { requestCount } }
    var acknowledgmentCount: Int { lock.withLock { acks.count } }
    var acknowledgments: [Set<String>] { lock.withLock { acks } }

    init() { FullSyncURLProtocol.register(self) }

    func receive(_ request: FullSyncURLProtocol) {
        let isStream = request.request.url!.path == "/api/sync/stream"
        let response: Response = lock.withLock {
            if isStream {
                requestCount += 1
                return responses.isEmpty ? .status(500) : responses.removeFirst()
            }
            var body = request.request.httpBody
            if body == nil, let input = request.request.httpBodyStream {
                input.open()
                defer { input.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            acks.append(Set(object?["acks"] as? [String] ?? []))
            if holdAcknowledgment { acknowledgment = request }
            return .body("{}")
        }
        if !isStream {
            onAcknowledgment?()
            if holdAcknowledgment { return }
        }
        switch response {
        case .failure:
            request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost))
        case .status(let status): finish(request, status: status, body: "error")
        case .body(let body): finish(request, body: body)
        case .held(let body):
            lock.withLock { stream = request }
            sendResponse(request)
            request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        }
        if isStream { onStream?() }
    }

    func finishStream(with body: String) {
        guard let request = lock.withLock({ let current = stream; stream = nil; return current }) else {
            XCTFail("Expected an open full-sync stream")
            return
        }
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }

    func finishAcknowledgment(failing: Bool) {
        guard let request = lock.withLock({ let current = acknowledgment; acknowledgment = nil; return current }) else {
            XCTFail("Expected an open acknowledgment")
            return
        }
        if failing { request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost)) }
        else { finish(request, body: "{}") }
    }

    private func sendResponse(_ request: FullSyncURLProtocol, status: Int = 200) {
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(url: request.request.url!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!,
            cacheStoragePolicy: .notAllowed)
    }

    private func finish(_ request: FullSyncURLProtocol, status: Int = 200, body: String) {
        sendResponse(request, status: status)
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }

    func close() {
        FullSyncURLProtocol.unregister(self)
        let requests = lock.withLock {
            let pending = [stream, acknowledgment].compactMap { $0 }
            stream = nil
            acknowledgment = nil
            return pending
        }
        for request in requests { request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled)) }
    }

    static func assets(_ count: Int) -> String { (0..<count).map { asset("download-\($0)") }.joined() }
    static let complete = "{\"type\":\"SyncCompleteV1\",\"ack\":\"SyncCompleteV1|complete\",\"data\":{}}\n"
    static let reset = "{\"type\":\"SyncResetV1\",\"ack\":\"SyncResetV1|reset\",\"data\":{}}\n"
    static func asset(_ id: String, favorite: Bool = false, visibility: String = "timeline") -> String {
        #"{"type":"AssetV2","ack":"AssetV2|\#(id)","data":{"id":"\#(id)","ownerId":"owner","originalFileName":"photo.jpg","checksum":"YWJj","type":"IMAGE","visibility":"\#(visibility)","isFavorite":\#(favorite),"isEdited":false,"fileCreatedAt":"2026-01-01T00:00:00Z"}}"# + "\n"
    }
    static func deletion(_ id: String, permanently: Bool = true) -> String {
        if permanently {
            return #"{"type":"AssetDeleteV1","ack":"AssetDeleteV1|\#(id)","data":{"assetId":"\#(id)"}}"# + "\n"
        }
        return #"{"type":"AssetV2","ack":"AssetV2|\#(id)","data":{"id":"\#(id)","ownerId":"owner","originalFileName":"photo.jpg","checksum":"YWJj","type":"IMAGE","visibility":"timeline","isFavorite":false,"isEdited":false,"deletedAt":"2026-01-01T00:00:00Z"}}"# + "\n"
    }
}

private final class FullSyncURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var transports: [String: FullSyncTransport] = [:]
    static func register(_ transport: FullSyncTransport) {
        lock.withLock { transports[transport.baseURL.host!] = transport }
    }
    static func unregister(_ transport: FullSyncTransport) {
        _ = lock.withLock { transports.removeValue(forKey: transport.baseURL.host!) }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { transports[request.url?.host ?? ""] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let transport = Self.lock.withLock({ Self.transports[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        transport.receive(self)
    }
    override func stopLoading() {}
}
