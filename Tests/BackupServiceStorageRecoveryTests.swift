import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupServiceStorageRecoveryTests: XCTestCase {
    private var directories: [URL] = []
    private var savedDefaults: [String: Any] = [:]
    private let defaultsKeys = ["backup.enabled", "backup.syncAlbums"]
    private let owner = BackupQueueOwner(server: "https://storage-recovery.example/api", userID: "owner")

    override func setUp() async throws {
        try await super.setUp()
        for key in defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testSameSessionCanRetryAnOwnerBindingAfterQueueStorageRecovers() throws {
        let fixture = try fixture()
        defer { withExtendedLifetime(fixture.session) { fixture.service.stop() } }
        fixture.fileManager.failOnAttempt = 1

        fixture.service.configure(session: fixture.session)

        XCTAssertNil(fixture.queue.owner)
        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertNotNil(fixture.service.lastError)
        let failedAttempts = fixture.fileManager.writeAttempts
        fixture.fileManager.failOnAttempt = nil

        fixture.service.configure(session: fixture.session)

        XCTAssertGreaterThan(fixture.fileManager.writeAttempts, failedAttempts)
        XCTAssertEqual(fixture.queue.owner, owner)
        XCTAssertEqual(fixture.service.uploadOwnership, fixture.queue.ownership)
        XCTAssertNotNil(fixture.service.uploadOwnership)
        XCTAssertNil(fixture.service.lastError)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.queueURL).ownership, fixture.queue.ownership)
    }

    func testSameSessionReleasesAuthenticationWaitsAfterQueueStorageRecovers() throws {
        let fixture = try fixture()
        defer { withExtendedLifetime(fixture.session) { fixture.service.stop() } }
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["pending"], now: recordedAt)
        try fixture.queue.markAllWaitingForAuthentication(error: "Session expired", now: recordedAt)
        let original = fixture.queue.items
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        fixture.fileManager.failOnAttempt = fixture.fileManager.writeAttempts + 1

        fixture.service.configure(session: fixture.session)

        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertEqual(fixture.queue.items, original)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.queueURL).items, original)
        XCTAssertNotNil(fixture.service.lastError)
        let storageError = fixture.service.lastError
        fixture.fileManager.failOnAttempt = nil

        fixture.service.configure(session: fixture.session)

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        XCTAssertEqual(fixture.queue.ownership, ownership)
        XCTAssertEqual(fixture.queue.item(id: "pending")?.state, .queued)
        XCTAssertNil(fixture.queue.item(id: "pending")?.nextAttemptAt)
        XCTAssertNotEqual(fixture.service.lastError, storageError)
        XCTAssertFalse(fixture.service.hasStatusError)
        let reopened = BackupQueueStore(fileURL: fixture.queueURL)
        let pending = try XCTUnwrap(reopened.item(id: "pending"))
        XCTAssertEqual(reopened.ownership, ownership)
        XCTAssertEqual(reopened.items.map(\.id), ["pending"])
        XCTAssertEqual(pending.state, .queued)
        XCTAssertEqual(pending.intent, original.first?.intent)
        XCTAssertEqual(pending.phase, original.first?.phase)
        XCTAssertEqual(pending.createdAt, recordedAt)
        XCTAssertNil(pending.nextAttemptAt)
    }

    func testSameSessionKeepsRejectingResultsWhileQueueStorageStillFails() throws {
        let fixture = try fixture()
        defer { withExtendedLifetime(fixture.session) { fixture.service.stop() } }
        fixture.fileManager.failOnAttempt = 1
        fixture.service.configure(session: fixture.session)
        let failedAttempts = fixture.fileManager.writeAttempts
        fixture.fileManager.failOnAttempt = failedAttempts + 1

        fixture.service.configure(session: fixture.session)

        XCTAssertGreaterThan(fixture.fileManager.writeAttempts, failedAttempts)
        XCTAssertNil(fixture.queue.owner)
        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertNotNil(fixture.service.lastError)
        XCTAssertTrue(fixture.service.hasStatusError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.queueURL.path))
    }

    func testReplacementSessionReleasesAuthenticationWaitsAfterQueueStorageRecovers() throws {
        let fixture = try fixture()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["pending"], now: recordedAt)
        try fixture.queue.markAllWaitingForAuthentication(error: "Session expired", now: recordedAt)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        fixture.fileManager.failOnAttempt = fixture.fileManager.writeAttempts + 1
        fixture.service.configure(session: fixture.session)
        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertEqual(fixture.queue.item(id: "pending")?.state, .waitingForAuthentication)
        fixture.fileManager.failOnAttempt = nil
        let replacement = RecoverySession(owner: owner, dataManager: fixture.dataManager)
        defer { withExtendedLifetime((fixture.session, replacement)) { fixture.service.stop() } }

        fixture.service.configure(session: replacement)

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        XCTAssertFalse(fixture.service.hasStatusError)
        let reopened = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(reopened.ownership, ownership)
        XCTAssertEqual(reopened.items.map(\.id), ["pending"])
        XCTAssertEqual(reopened.item(id: "pending")?.state, .queued)
        XCTAssertEqual(reopened.item(id: "pending")?.createdAt, recordedAt)
        XCTAssertNil(reopened.item(id: "pending")?.nextAttemptAt)
    }

    func testReplacementSessionClearsRecoveredStorageErrorWhileUploadRemainsPending() throws {
        let fixture = try fixture()
        let recordedAt = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["pending"], now: recordedAt)
        try fixture.queue.markPreparing("pending", phase: .primaryAsset, now: recordedAt)
        try fixture.queue.markUploading("pending", phase: .primaryAsset,
            checksum: "saved-checksum", taskIdentifier: 91, now: recordedAt)
        fixture.service.configure(session: fixture.session)
        let ownership = try XCTUnwrap(fixture.service.uploadOwnership)
        let pending = try XCTUnwrap(fixture.queue.item(id: "pending"))
        fixture.fileManager.failOnAttempt = fixture.fileManager.writeAttempts + 1
        fixture.service.finishStorageRecovery(localIdentifier: "pending", taskIdentifier: 91)
        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertTrue(fixture.service.hasStatusError)
        fixture.fileManager.failOnAttempt = nil
        let replacement = RecoverySession(owner: owner, dataManager: fixture.dataManager)
        defer { withExtendedLifetime((fixture.session, replacement)) { fixture.service.stop() } }

        fixture.service.configure(session: replacement)

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        XCTAssertNil(fixture.service.lastError)
        XCTAssertFalse(fixture.service.hasStatusError)
        XCTAssertEqual(fixture.queue.item(id: "pending"), pending)
        let reopened = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(reopened.ownership, ownership)
        XCTAssertEqual(reopened.item(id: "pending"), pending)
    }

    func testStorageRecoveryReconcilesOrphanPreparationsBeforeResuming() async throws {
        let fixture = try fixture()
        defer { withExtendedLifetime(fixture.session) { fixture.service.stop() } }
        let recordedAt = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["orphan", "uploading"], now: recordedAt)
        try fixture.queue.markPreparing("orphan", phase: .livePhotoMotion,
            motionAssetID: "saved-motion", now: recordedAt)
        try fixture.queue.markPreparing("uploading", phase: .primaryAsset, now: recordedAt)
        try fixture.queue.markUploading("uploading", phase: .primaryAsset,
            checksum: "saved-checksum", taskIdentifier: 91, now: recordedAt)
        fixture.service.configure(session: fixture.session)
        let ownership = try XCTUnwrap(fixture.service.uploadOwnership)
        let orphan = try XCTUnwrap(fixture.queue.item(id: "orphan"))
        fixture.fileManager.failOnAttempt = fixture.fileManager.writeAttempts + 1
        fixture.service.finishStorageRecovery(localIdentifier: "uploading", taskIdentifier: 91)
        XCTAssertNil(fixture.service.uploadOwnership)
        XCTAssertEqual(fixture.queue.item(id: "orphan"), orphan)
        fixture.fileManager.failOnAttempt = nil

        fixture.service.configure(session: fixture.session)
        let reconciled = expectation(description: "Recovered service reconciles interrupted preparation")
        withObservationTracking { _ = fixture.queue.snapshot } onChange: { reconciled.fulfill() }
        await fulfillment(of: [reconciled], timeout: 5)

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        let recovered = try XCTUnwrap(fixture.queue.item(id: "orphan"))
        XCTAssertEqual(recovered.state, .retryScheduled)
        XCTAssertEqual(recovered.phase, orphan.phase)
        XCTAssertEqual(recovered.motionAssetID, orphan.motionAssetID)
        XCTAssertEqual(recovered.intent, orphan.intent)
        XCTAssertEqual(fixture.queue.item(id: "uploading")?.state, .uploading)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.queueURL).item(id: "orphan")?.state, .retryScheduled)
        XCTAssertEqual(fixture.service.scheduledForRetry, 1)
    }

    func testQueuedStorageRecoveryCannotReconcileAReplacementAccountsPreparation() async throws {
        let fixture = try fixture()
        fixture.fileManager.failOnAttempt = 1
        fixture.service.configure(session: fixture.session)
        XCTAssertNil(fixture.service.uploadOwnership)
        fixture.fileManager.failOnAttempt = nil
        fixture.service.configure(session: fixture.session)
        let oldOwnership = try XCTUnwrap(fixture.service.uploadOwnership)
        let replacementOwner = BackupQueueOwner(server: owner.server, userID: "replacement")
        let replacement = RecoverySession(owner: replacementOwner, dataManager: fixture.dataManager)
        defer { withExtendedLifetime((fixture.session, replacement)) { fixture.service.stop() } }

        fixture.service.configure(session: replacement)
        try fixture.queue.enqueue(["replacement"])
        try fixture.queue.markPreparing("replacement", phase: .primaryAsset)
        let ownership = try XCTUnwrap(fixture.service.uploadOwnership)
        let expected = fixture.queue.items
        let durable = try Data(contentsOf: fixture.queueURL)
        XCTAssertNotEqual(ownership, oldOwnership)
        XCTAssertEqual(ownership.owner, replacementOwner)
        XCTAssertEqual(fixture.queue.item(id: "replacement")?.state, .preparing)
        let obsoleteWake = expectation(description: "Previous account's queued recovery cannot change the replacement queue")
        obsoleteWake.isInverted = true
        withObservationTracking { _ = fixture.queue.snapshot } onChange: {
            MainActor.assumeIsolated {
                if fixture.session.isLoggedIn { obsoleteWake.fulfill() }
            }
        }

        await fulfillment(of: [obsoleteWake], timeout: 0.15)

        XCTAssertEqual(fixture.queue.items, expected)
        XCTAssertEqual(try Data(contentsOf: fixture.queueURL), durable)
        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        fixture.session.isLoggedIn = false

        await fixture.service.restoreBackgroundLifecycle()

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        XCTAssertEqual(fixture.queue.item(id: "replacement")?.state, .retryScheduled)
        XCTAssertEqual(BackupQueueStore(fileURL: fixture.queueURL).item(id: "replacement")?.state, .retryScheduled)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-storage-recovery-\(UUID().uuidString)")
        directories.append(directory)
        let fileManager = RecoveryQueueFileManager()
        let queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL, fileManager: fileManager)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("store.sqlite"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
        let session = RecoverySession(owner: owner, dataManager: manager)
        let service = BackupService(dataManager: manager, queue: queue)
        return Fixture(queueURL: queueURL, queue: queue, fileManager: fileManager, dataManager: manager,
            session: session, service: service)
    }

    private struct Fixture {
        let queueURL: URL
        let queue: BackupQueueStore
        let fileManager: RecoveryQueueFileManager
        let dataManager: SwiftDataManager
        let session: RecoverySession
        let service: BackupService
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

private final class RecoveryQueueFileManager: FileManager, @unchecked Sendable {
    var failOnAttempt: Int?
    private(set) var writeAttempts = 0

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil) throws {
        writeAttempts += 1
        if writeAttempts == failOnAttempt { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
