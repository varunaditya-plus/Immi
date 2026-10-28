import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumPlacementReplayTests: XCTestCase {
    private var fixtures: [AlbumReplayFixture] = []
    private var savedDefaults: [String: Any] = [:]
    private let defaultKeys = ["backup.enabled", "backup.syncAlbums", "backup.cellularPhotos"]
    private let owner = BackupQueueOwner(server: "https://album-replay.example/api", userID: "owner")

    override func setUp() async throws {
        try await super.setUp()
        for key in defaultKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: "backup.enabled")
        UserDefaults.standard.set(true, forKey: "backup.syncAlbums")
        UserDefaults.standard.set(false, forKey: "backup.cellularPhotos")
    }

    override func tearDown() async throws {
        for fixture in fixtures { fixture.service.stop() }
        for directory in Set(fixtures.map(\.directory)) { try? FileManager.default.removeItem(at: directory) }
        fixtures.removeAll()
        for key in defaultKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testFailedAlbumLookupAfterUploadReplaysFromDiskInAFreshService() async throws {
        let original = try fixture()
        original.albums.lookupError = URLError(.timedOut)
        let context = try original.startUpload()

        original.complete(context, assetID: "uploaded-photo")
        await original.service.waitUntilFinished()

        let placement = BackupAlbumPlacement(
            localIdentifier: context.localIdentifier, assetID: "uploaded-photo", albumName: "Camera")
        XCTAssertEqual(original.albums.lookups, 1)
        XCTAssertTrue(original.albums.createdNames.isEmpty)
        XCTAssertTrue(original.albums.addedIDs.isEmpty)
        XCTAssertNil(original.queue.item(id: context.localIdentifier))
        XCTAssertEqual(original.reopenQueue().pendingAlbumPlacements, [placement])
        XCTAssertEqual(original.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "uploaded-photo")
        original.service.stop()

        let cold = try fixture(directory: original.directory)
        await cold.service.waitUntilFinished()

        XCTAssertEqual(cold.albums.createdNames, ["Camera"])
        XCTAssertEqual(cold.albums.addedIDs, [["uploaded-photo"]])
        XCTAssertEqual(cold.albums.destinationIDs, ["created-camera"])
        XCTAssertTrue(cold.reopenQueue().pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(cold.queue.snapshot.completed, 1)
        XCTAssertEqual(cold.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "uploaded-photo")

        cold.service.configure(session: cold.session)
        await cold.service.waitUntilFinished()
        XCTAssertEqual(cold.albums.addedIDs, [["uploaded-photo"]], "Acknowledged placements must not replay again")
    }

    func testFailedAdditionInvalidatesDeletedDestinationBeforeSameSessionRetry() async throws {
        let fixture = try fixture()
        fixture.albums.listedAlbums = [album(id: "deleted-album")]
        fixture.albums.addError = APIError.server(status: 404, message: "Album was deleted")
        let context = try fixture.startUpload()
        fixture.complete(context, assetID: "uploaded-photo")
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.destinationIDs, ["deleted-album"])
        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements.count, 1)
        fixture.albums.listedAlbums = []
        fixture.albums.addError = nil

        fixture.service.configure(session: fixture.session)
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.lookups, 2, "Retry must resolve again instead of reusing the deleted album")
        XCTAssertEqual(fixture.albums.createdNames, ["Camera"])
        XCTAssertEqual(fixture.albums.destinationIDs, ["deleted-album", "created-camera"])
        XCTAssertEqual(fixture.albums.addedIDs, [["uploaded-photo"], ["uploaded-photo"]])
        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    func testDisabledAlbumSyncPreservesPendingWorkUntilItIsEnabled() async throws {
        UserDefaults.standard.set(false, forKey: "backup.syncAlbums")
        let fixture = try fixture(configure: false)
        try fixture.queue.bind(to: owner)
        let placement = BackupAlbumPlacement(localIdentifier: "photo", assetID: "uploaded", albumName: "Camera")
        try fixture.queue.recordAlbumPlacement(placement)

        fixture.service.configure(session: fixture.session)
        await fixture.service.continueInBackground()
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.lookups, 0)
        XCTAssertTrue(fixture.albums.addedIDs.isEmpty)
        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements, [placement])
        XCTAssertFalse(fixture.service.hasPendingAlbumPlacements)

        fixture.service.syncAlbums = true
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.addedIDs, [["uploaded"]])
        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    func testAnotherAccountCannotReplayThePreviousAccountsAlbumIntent() async throws {
        let original = try fixture(configure: false)
        try original.queue.bind(to: owner)
        let placement = BackupAlbumPlacement(localIdentifier: "photo", assetID: "old-account-photo", albumName: "Camera")
        try original.queue.recordAlbumPlacement(placement)
        let previousOwnership = try XCTUnwrap(original.queue.ownership)

        let replacement = BackupQueueOwner(server: owner.server, userID: "another-owner")
        let other = try fixture(directory: original.directory, owner: replacement)
        await other.service.continueInBackground()
        await other.service.waitUntilFinished()

        XCTAssertEqual(other.queue.owner, replacement)
        XCTAssertNotEqual(other.queue.ownership?.generation, previousOwnership.generation)
        XCTAssertEqual(other.albums.lookups, 0)
        XCTAssertTrue(other.albums.addedIDs.isEmpty)
        XCTAssertTrue(other.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    func testFreshServiceRecoversAFailedUploadCheckpointFromItsSavedMappingWithoutACallback() async throws {
        let original = try fixture()
        let context = try original.startUpload()
        original.fileManager.failOnAttempt = original.fileManager.writeAttempts + 1

        original.complete(context, assetID: "recorded-photo")
        await original.service.waitUntilFinished()

        XCTAssertEqual(original.queue.item(id: context.localIdentifier)?.sourceAlbumName, "Camera")
        XCTAssertEqual(original.queue.item(id: context.localIdentifier)?.state, .retryScheduled)
        XCTAssertTrue(original.reopenQueue().pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(original.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "recorded-photo")
        XCTAssertEqual(original.albums.lookups, 0, "Placement must wait for a durable checkpoint")
        original.service.stop()

        // No second upload callback or PhotoKit asset is supplied to the new service.
        let cold = try fixture(directory: original.directory)
        await cold.service.waitUntilFinished()

        XCTAssertNil(cold.queue.item(id: context.localIdentifier))
        XCTAssertEqual(cold.albums.addedIDs, [["recorded-photo"]])
        XCTAssertEqual(cold.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "recorded-photo")
        XCTAssertTrue(cold.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    func testFailedAcknowledgementReplaysAfterRelaunchAndAcceptsAnAlreadyAddedPhoto() async throws {
        let original = try fixture()
        let context = try original.startUpload()
        original.albums.onAdd = { [weak fileManager = original.fileManager] in
            guard let fileManager else { return }
            fileManager.failOnAttempt = fileManager.writeAttempts + 1
        }

        original.complete(context, assetID: "uploaded-photo")
        await original.service.waitUntilFinished()

        XCTAssertEqual(original.albums.addedIDs, [["uploaded-photo"]])
        XCTAssertEqual(original.reopenQueue().pendingAlbumPlacements, [
            BackupAlbumPlacement(localIdentifier: context.localIdentifier, assetID: "uploaded-photo", albumName: "Camera")
        ])
        XCTAssertNotNil(original.service.lastError)
        original.service.stop()

        let cold = try fixture(directory: original.directory, configure: false)
        cold.albums.listedAlbums = [album(id: "existing-camera")]
        cold.albums.duplicateIDs = ["uploaded-photo"]
        cold.service.configure(session: cold.session)
        await cold.service.waitUntilFinished()

        XCTAssertEqual(cold.albums.addedIDs, [["uploaded-photo"]])
        XCTAssertEqual(cold.albums.destinationIDs, ["existing-camera"])
        XCTAssertTrue(cold.albums.createdNames.isEmpty)
        XCTAssertTrue(cold.reopenQueue().pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(cold.queue.snapshot.completed, 1)
    }

    func testBackgroundWakeRetriesAlbumWorkWhenAutomaticUploadsAreOff() async throws {
        let fixture = try fixture()
        let placement = BackupAlbumPlacement(localIdentifier: "photo", assetID: "uploaded", albumName: "Camera")
        try fixture.queue.recordAlbumPlacement(placement)
        XCTAssertFalse(fixture.service.isEnabled)
        XCTAssertFalse(fixture.service.hasPendingRequestedUploads)
        XCTAssertTrue(fixture.service.hasPendingAlbumPlacements)

        await fixture.service.continueInBackground()
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.addedIDs, [["uploaded"]])
        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
        XCTAssertTrue(fixture.queue.items.isEmpty)
    }

    func testNewUploadDoesNotRepeatedlyRetryAnUnrelatedFailedPlacement() async throws {
        let fixture = try fixture()
        fixture.albums.lookupError = URLError(.timedOut)
        let first = try fixture.startUpload()
        fixture.complete(first, assetID: "first-upload")
        await fixture.service.waitUntilFinished()
        XCTAssertEqual(fixture.queue.pendingAlbumPlacements.count, 1)
        fixture.albums.lookupError = nil

        let second = try fixture.startUpload()
        fixture.complete(second, assetID: "second-upload")
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.addedIDs, [["second-upload"]])
        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements, [
            BackupAlbumPlacement(localIdentifier: first.localIdentifier, assetID: "first-upload", albumName: "Camera")
        ], "Failed placements retry on a wake, rather than on every unrelated upload")
    }

    func testAuthenticationPauseKeepsAHeldPlacementAndSameOwnerReconfigurationReplaysIt() async throws {
        let fixture = try fixture()
        let held = AlbumReplayAddGate()
        addTeardownBlock { await held.release() }
        fixture.albums.addGate = held
        let context = try fixture.startUpload()
        fixture.complete(context, assetID: "uploaded-photo")
        await fulfillment(of: [held.started], timeout: 2)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let placement = BackupAlbumPlacement(
            localIdentifier: context.localIdentifier, assetID: "uploaded-photo", albumName: "Camera")
        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements, [placement])

        let waiting = expectation(description: "The drain is waiting for the held placement")
        let drain = Task {
            waiting.fulfill()
            await fixture.service.waitUntilFinished()
        }
        addTeardownBlock { await held.release(); await drain.value }
        await fulfillment(of: [waiting], timeout: 2)
        fixture.service.pauseForAuthentication()
        XCTAssertNil(fixture.service.uploadOwnership)
        held.release()
        await drain.value

        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements, [placement],
            "A late successful response from the canceled attempt must not acknowledge the placement")
        XCTAssertEqual(fixture.queue.ownership, ownership)
        fixture.albums.addGate = nil
        fixture.albums.listedAlbums = [album(id: "created-camera")]
        fixture.service.configure(session: fixture.session)
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.service.uploadOwnership, ownership)
        XCTAssertEqual(fixture.albums.addedIDs, [["uploaded-photo"], ["uploaded-photo"]])
        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    func testLateCanceledAdditionCannotAcknowledgeOrRemoveANewerSamePhotoPlacement() async throws {
        let fixture = try fixture()
        let oldAdd = AlbumReplayAddGate()
        let newAdd = AlbumReplayAddGate()
        addTeardownBlock { await oldAdd.release(); await newAdd.release() }
        fixture.albums.addGate = oldAdd
        let context = try fixture.startUpload()
        fixture.complete(context, assetID: "old-upload")
        await fulfillment(of: [oldAdd.started], timeout: 2)

        let waiting = expectation(description: "The drain captured the old held attempt")
        let drain = Task {
            waiting.fulfill()
            await fixture.service.waitUntilFinished()
        }
        addTeardownBlock { drain.cancel(); await oldAdd.release(); await newAdd.release(); await drain.value }
        await fulfillment(of: [waiting], timeout: 2)
        let replacement = BackupAlbumPlacement(
            localIdentifier: context.localIdentifier, assetID: "replacement-upload", albumName: "Trips")
        try fixture.queue.recordAlbumPlacement(replacement)
        fixture.albums.addGate = newAdd
        fixture.service.configure(session: fixture.session)
        await fulfillment(of: [newAdd.started], timeout: 2)

        // End this observer after its captured attempt; keep the new addition held.
        drain.cancel()
        oldAdd.release()
        await drain.value

        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements, [replacement])
        XCTAssertEqual(fixture.albums.addedIDs, [["old-upload"], ["replacement-upload"]])
        newAdd.release()
        await fixture.service.waitUntilFinished()

        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(fixture.albums.createdNames, ["Camera", "Trips"])
        XCTAssertEqual(fixture.albums.destinationIDs, ["created-camera", "created-trips"])
    }

    func testNetworkPolicyWakeRetriesAlbumOnlyWork() async throws {
        let fixture = try fixture()
        fixture.albums.lookupError = URLError(.timedOut)
        let context = try fixture.startUpload()
        fixture.complete(context, assetID: "uploaded-photo")
        await fixture.service.waitUntilFinished()
        XCTAssertFalse(fixture.service.isEnabled)
        XCTAssertFalse(fixture.service.hasPendingRequestedUploads)
        XCTAssertEqual(fixture.albums.lookups, 1)
        XCTAssertEqual(fixture.reopenQueue().pendingAlbumPlacements.count, 1)
        fixture.albums.lookupError = nil

        fixture.service.cellularPhotos = true
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.lookups, 2)
        XCTAssertEqual(fixture.albums.addedIDs, [["uploaded-photo"]])
        XCTAssertTrue(fixture.reopenQueue().pendingAlbumPlacements.isEmpty)
    }

    private func fixture(
        directory existing: URL? = nil, owner replacement: BackupQueueOwner? = nil, configure: Bool = true
    ) throws -> AlbumReplayFixture {
        let directory = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("album-replay-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let fileManager = AlbumReplayFileManager()
        let queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"), fileManager: fileManager)
        let session = AlbumReplaySession(dataManager: data, owner: replacement ?? owner)
        let albums = AlbumReplayRepository(api: APIClient(session: session))
        let service = BackupService(dataManager: data, queue: queue, makeAlbumRepository: { _ in albums })
        let fixture = AlbumReplayFixture(directory: directory, data: data, fileManager: fileManager,
            queue: queue, session: session, albums: albums, service: service)
        fixtures.append(fixture)
        if configure { service.configure(session: session) }
        return fixture
    }

    private func album(id: String) -> AlbumResponseDTO {
        .init(id: id, albumName: "Camera", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil, ownerId: owner.userID)
    }
}

@MainActor
private struct AlbumReplayFixture {
    let directory: URL
    let data: SwiftDataManager
    let fileManager: AlbumReplayFileManager
    let queue: BackupQueueStore
    let session: AlbumReplaySession
    let albums: AlbumReplayRepository
    let service: BackupService

    func startUpload() throws -> BackupUploadTaskContext {
        let id = "photo-\(UUID())"
        try queue.enqueue([id])
        try queue.markPreparing(id, phase: .primaryAsset, sourceAlbumName: "Camera")
        try queue.markUploading(id, phase: .primaryAsset, checksum: "sha", taskIdentifier: 42)
        return BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: id,
            checksum: "sha", bodyPath: directory.appendingPathComponent("upload.multipart").path,
            ownership: try XCTUnwrap(queue.ownership), sourceAlbumName: "Camera")
    }

    func complete(_ context: BackupUploadTaskContext, assetID: String) {
        service.finishUpload(context: context, taskIdentifier: 42, outcome: .success(assetID), remainingBackgroundTasks: 0)
    }

    func reopenQueue() -> BackupQueueStore {
        BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
    }
}

@MainActor
private final class AlbumReplaySession: SessionManager {
    private let owner: BackupQueueOwner

    init(dataManager: SwiftDataManager, owner: BackupQueueOwner) {
        self.owner = owner
        super.init(dataManager: dataManager, restoresSession: false)
        isLoggedIn = true
    }

    override var backupQueueOwner: BackupQueueOwner? { owner }
}

@MainActor
private final class AlbumReplayRepository: AlbumRepository {
    var listedAlbums: [AlbumResponseDTO] = []
    var lookupError: Error?
    var addError: Error?
    var duplicateIDs: [String] = []
    var onAdd: (() -> Void)?
    var addGate: AlbumReplayAddGate?
    private(set) var lookups = 0
    private(set) var createdNames: [String] = []
    private(set) var addedIDs: [[String]] = []
    private(set) var destinationIDs: [String] = []

    override func all() async throws -> [AlbumResponseDTO] {
        lookups += 1
        if let lookupError { throw lookupError }
        return listedAlbums
    }

    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        createdNames.append(name)
        return .init(id: "created-\(name.lowercased())", albumName: name, description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
    }

    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        addedIDs.append(ids)
        destinationIDs.append(albumId)
        if let addGate { await addGate.wait() }
        onAdd?()
        if let addError { throw addError }
        return duplicateIDs
    }
}

@MainActor
private final class AlbumReplayAddGate {
    let started = XCTestExpectation(description: "An album addition is held before its response")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    // Deliberately ignores cancellation so the service must reject a late response.
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AlbumReplayFileManager: FileManager, @unchecked Sendable {
    var failOnAttempt: Int?
    private(set) var writeAttempts = 0

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        writeAttempts += 1
        if writeAttempts == failOnAttempt { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
