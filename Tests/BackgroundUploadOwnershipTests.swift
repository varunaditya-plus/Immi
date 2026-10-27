import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackgroundUploadOwnershipTests: XCTestCase {
    private let owner = BackupQueueOwner(server: "https://immich.test/api", userID: "user-a")
    private var savedDefaults: [String: Any] = [:]
    private let defaultsKeys = ["backup.enabled", "backup.syncAlbums", "backup.manualQueueRefill"]

    override func setUp() async throws {
        try await super.setUp()
        for key in defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults = [:]
        try await super.tearDown()
    }

    func testMatchingCompletionPersistsMappingAndCompletesQueue() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let original = try fixture.startUpload()
        let context = try XCTUnwrap(BackupUploadTaskContext.decode(original.encoded))
        XCTAssertEqual(context.ownership, original.ownership)
        XCTAssertEqual(context.credentialFingerprint, original.credentialFingerprint)

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("server-asset"), remainingBackgroundTasks: 0)

        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "local-a")?.assetId, "server-asset")
        XCTAssertEqual(fixture.queue.snapshot.completed, 1)
        XCTAssertNil(fixture.queue.item(id: "local-a"))
        let restored = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
        XCTAssertEqual(restored.getBackupRecord(localIdentifier: "local-a")?.assetId, "server-asset")
    }

    func testOwnedCompletionCanRecoverMissingQueueRecordAfterRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = BackupUploadTaskContext(
            phase: .primaryAsset, localIdentifier: "surviving-task", checksum: "sha",
            bodyPath: "/tmp/surviving.multipart", ownership: try XCTUnwrap(fixture.queue.ownership))

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("recovered-asset"), remainingBackgroundTasks: 0)

        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "surviving-task")?.assetId, "recovered-asset")
        XCTAssertEqual(fixture.queue.snapshot.completed, 1)
    }

    func testDifferentAccountOrServerCompletionCannotModifyMappingOrQueue() throws {
        for otherOwner in [
            BackupQueueOwner(server: owner.server, userID: "user-b"),
            BackupQueueOwner(server: "https://other.test/api", userID: owner.userID),
        ] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            var context = try fixture.startUpload()
            context.ownership = BackupUploadOwnership(
                owner: otherOwner, generation: try XCTUnwrap(fixture.queue.ownership).generation)
            let original = fixture.queue.snapshot

            fixture.service.finishUpload(
                context: context, taskIdentifier: 42,
                outcome: .success("wrong-account-asset"), remainingBackgroundTasks: 0)

            XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
            XCTAssertEqual(fixture.queue.snapshot, original)
            XCTAssertNil(fixture.service.lastError)
        }
    }

    func testLogoutRejectsOldCompletionEvenWhenSameAccountSignsInAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let old = try fixture.startUpload()
        fixture.service.resetForLogout()
        fixture.service.configure(session: fixture.session)
        let current = try fixture.startUpload()
        XCTAssertNotEqual(old.ownership, current.ownership)

        fixture.service.finishUpload(
            context: old, taskIdentifier: 42,
            outcome: .success("old-login-asset"), remainingBackgroundTasks: 0)

        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.state, .uploading)

        fixture.service.finishUpload(
            context: current, taskIdentifier: 42,
            outcome: .success("new-login-asset"), remainingBackgroundTasks: 0)
        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "local-a")?.assetId, "new-login-asset")
    }

    func testExpiredSessionRejectsCompletionButSameAccountReauthenticationPreservesOwnership() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try fixture.startUpload()
        fixture.service.pauseForAuthentication()

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("must-wait"), remainingBackgroundTasks: 0)

        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.state, .waitingForAuthentication)
        fixture.service.configure(session: fixture.session)
        XCTAssertEqual(fixture.queue.ownership, context.ownership)
        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("same-account-asset"), remainingBackgroundTasks: 0)
        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "local-a")?.assetId, "same-account-asset")
    }

    func testOldCredential401RetriesWithoutExpiringRenewedSameAccountSession() async throws {
        UserDefaults.standard.set(true, forKey: "backup.manualQueueRefill")
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try fixture.startUpload()
        fixture.service.pauseForAuthentication()
        fixture.session.uploadAuthHeaders = ["Authorization": "Bearer renewed-token"]
        fixture.service.configure(session: fixture.session)
        XCTAssertEqual(context.ownership, fixture.queue.ownership)
        let unexpectedExpiration = expectation(description: "Renewed session must remain signed in")
        unexpectedExpiration.isInverted = true
        fixture.session.onExpire = { unexpectedExpiration.fulfill() }

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .failure(APIError.server(status: 401, message: "token rejected")), remainingBackgroundTasks: 0)

        await fulfillment(of: [unexpectedExpiration], timeout: 0.1)
        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.expirationCount, 0)
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.state, .queued)
        XCTAssertEqual(fixture.queue.readyItems().map(\.id), ["local-a"])
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "backup.manualQueueRefill"))
        XCTAssertNil(fixture.service.lastError)
        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
    }

    func testCurrentCredential401PausesQueueAndExpiresCurrentSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try fixture.startUpload()
        let expiration = expectation(description: "Current rejected credentials require sign-in")
        fixture.session.onExpire = { expiration.fulfill() }

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .failure(APIError.server(status: 401, message: "token rejected")), remainingBackgroundTasks: 0)

        await fulfillment(of: [expiration], timeout: 1)
        XCTAssertFalse(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.session.expirationCount, 1)
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.state, .waitingForAuthentication)
        XCTAssertTrue(fixture.queue.readyItems().isEmpty)
        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
    }

    func testUnidentifiedCredential401CannotExpireCurrentSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var context = try fixture.startUpload()
        context.credentialFingerprint = nil

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .failure(APIError.server(status: 401, message: "token rejected")), remainingBackgroundTasks: 0)

        XCTAssertTrue(fixture.session.isLoggedIn)
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.state, .queued)
        XCTAssertEqual(fixture.queue.readyItems().map(\.id), ["local-a"])
    }

    func testForegroundSessionReplacesBackgroundSessionForSameOwner() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try fixture.startUpload()
        let foreground = UploadSession(owner: owner, dataManager: fixture.dataManager)
        foreground.uploadAuthHeaders = ["Authorization": "Bearer foreground-token"]
        fixture.service.configure(session: foreground)
        fixture.session.isLoggedIn = false

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("foreground-owned-asset"), remainingBackgroundTasks: 0)

        XCTAssertEqual(fixture.dataManager.getBackupRecord(localIdentifier: "local-a")?.assetId, "foreground-owned-asset")
        XCTAssertEqual(fixture.queue.snapshot.completed, 1)
    }

    func testUnownedLegacyCompletionCannotAdoptQueueRecordOrMapping() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try XCTUnwrap(BackupUploadTaskContext.decode(
            ["legacy-local", "checksum", "/tmp/old.multipart"].joined(separator: "\u{1}")))

        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("unowned-asset"), remainingBackgroundTasks: 0)

        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "legacy-local"))
        XCTAssertNil(fixture.queue.item(id: "legacy-local"))
        XCTAssertEqual(fixture.queue.snapshot.completed, 0)
    }

    func testSupersededTaskCannotReportProgressOrCompleteReplacement() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try fixture.startUpload(taskIdentifier: 43)

        fixture.service.reportUploadProgress(
            context: context, taskIdentifier: 42, bytesSent: 50, totalBytesExpected: 100)
        fixture.service.finishUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("stale-task-asset"), remainingBackgroundTasks: 0)

        XCTAssertNil(fixture.service.uploadProgressByID["local-a"])
        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
        XCTAssertEqual(fixture.queue.item(id: "local-a")?.taskIdentifier, 43)
        fixture.service.reportUploadProgress(
            context: context, taskIdentifier: 43, bytesSent: 50, totalBytesExpected: 100)
        XCTAssertEqual(fixture.service.uploadProgressByID["local-a"], 0.5)
    }

    func testForeignLivePhotoCallbackDoesNotAdvanceCurrentQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var context = try fixture.startUpload(phase: .livePhotoMotion)
        context.ownership = BackupUploadOwnership(owner: owner, generation: UUID())
        let original = fixture.queue.snapshot

        await fixture.service.finishLivePhotoMotionUpload(
            context: context, taskIdentifier: 42,
            outcome: .success("foreign-motion"), remainingBackgroundTasks: 0)

        XCTAssertEqual(fixture.queue.snapshot, original)
        XCTAssertNil(fixture.queue.item(id: "local-a")?.motionAssetID)
        XCTAssertNil(fixture.dataManager.getBackupRecord(localIdentifier: "local-a"))
    }

    func testOwnershipSurvivesRelaunchAndSameAccountBindingButChangesWithAccount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let original = try XCTUnwrap(fixture.queue.ownership)
        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertEqual(restored.ownership, original)
        XCTAssertFalse(try restored.bind(to: owner))
        XCTAssertEqual(restored.ownership, original)

        XCTAssertTrue(try restored.bind(to: BackupQueueOwner(server: owner.server, userID: "user-b")))
        XCTAssertNotEqual(restored.ownership?.generation, original.generation)
    }

    func testReconciliationOnlyAdoptsOwnedCurrentGenerationTasks() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let contexts = [
            BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "owned", checksum: "sha", bodyPath: "/tmp/a", ownership: ownership),
            BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "legacy", checksum: "sha", bodyPath: "/tmp/b"),
            BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "stale", checksum: "sha", bodyPath: "/tmp/c", ownership: BackupUploadOwnership(owner: owner, generation: UUID())),
            BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: "foreign", checksum: "sha", bodyPath: "/tmp/d", ownership: BackupUploadOwnership(owner: BackupQueueOwner(server: owner.server, userID: "user-b"), generation: ownership.generation)),
        ]
        try fixture.queue.reconcile(activeTasks: contexts.enumerated().map {
            BackupActiveTask(taskIdentifier: $0.offset + 1, context: $0.element, isSuspended: true)
        })

        XCTAssertEqual(fixture.queue.items.map(\.id), ["owned"])
        XCTAssertEqual(fixture.queue.item(id: "owned")?.taskIdentifier, 1)
    }

    func testBindingDoesNotAdoptQueueItemsWhoseOwnerWasNeverRecorded() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.queue.clear()
        try fixture.queue.enqueue(["unattributed-photo"])

        XCTAssertTrue(try fixture.queue.bind(to: owner))

        XCTAssertEqual(fixture.queue.snapshot.total, 0)
        XCTAssertNotNil(fixture.queue.ownership)
    }

    func testOldOwnedLedgerGetsGenerationWithoutLosingPendingWork() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.queue.enqueue(["pending-photo"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.queueURL)) as? [String: Any])
        object.removeValue(forKey: "generation")
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.queueURL)
        let restored = BackupQueueStore(fileURL: fixture.queueURL)
        XCTAssertNil(restored.ownership)

        XCTAssertFalse(try restored.bind(to: owner))

        XCTAssertNotNil(restored.ownership)
        XCTAssertEqual(restored.items.map(\.id), ["pending-photo"])
    }

    private final class UploadSession: SessionManager {
        let uploadOwner: BackupQueueOwner
        var uploadAuthHeaders = ["Authorization": "Bearer original-token"]
        private(set) var expirationCount = 0
        var onExpire: (() -> Void)?

        init(owner: BackupQueueOwner, dataManager: SwiftDataManager) {
            uploadOwner = owner
            super.init(dataManager: dataManager, restoresSession: false)
            isLoggedIn = true
        }

        override var backupQueueOwner: BackupQueueOwner? { uploadOwner }
        override var authHeaders: [String: String] { uploadAuthHeaders }

        override func expireForBackgroundUpload() async {
            expirationCount += 1
            isLoggedIn = false
            onExpire?()
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let dataManager: SwiftDataManager
        let queue: BackupQueueStore
        let service: BackupService
        let session: UploadSession
        var queueURL: URL { directory.appendingPathComponent("queue.json") }
        var storeURL: URL { directory.appendingPathComponent("test.store") }
        var journalURL: URL { directory.appendingPathComponent("journal.json") }

        func startUpload(taskIdentifier: Int = 42, phase: BackupUploadPhase = .primaryAsset) throws -> BackupUploadTaskContext {
            try queue.enqueue(["local-a"])
            try queue.markPreparing("local-a", phase: phase)
            try queue.markUploading("local-a", phase: phase, checksum: "checksum-a", taskIdentifier: taskIdentifier)
            return BackupUploadTaskContext(
                phase: phase, localIdentifier: "local-a", checksum: "checksum-a", bodyPath: "/tmp/ownership-test.multipart",
                ownership: try XCTUnwrap(queue.ownership),
                credentialFingerprint: BackupUploadTaskContext.credentialFingerprint(for: session.authHeaders))
        }

        func cleanup() {
            service.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("upload-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataManager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
        let queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let session = UploadSession(owner: owner, dataManager: dataManager)
        let service = BackupService(dataManager: dataManager, queue: queue)
        service.configure(session: session)
        XCTAssertTrue(dataManager.isPersistentStoreAvailable)
        return Fixture(directory: directory, dataManager: dataManager, queue: queue, service: service, session: session)
    }
}
