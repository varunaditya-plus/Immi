import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumPlacementRecoveryTests: XCTestCase {
    private var fixtures: [PlacementFixture] = []
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["backup.enabled", "backup.syncAlbums"]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: "backup.enabled")
        UserDefaults.standard.set(true, forKey: "backup.syncAlbums")
    }

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.service.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testColdCompletionUsesThePersistedTaskAlbumWithoutPhotoKitMetadata() async throws {
        let original = try fixture()
        let context = try original.startUpload(queueName: "Trips", contextName: "Trips")
        original.service.stop()
        let cold = try fixture(directory: original.directory)
        let decoded = try XCTUnwrap(BackupUploadTaskContext.decode(context.encoded))
        let added = expectation(description: "The cold completion reached its saved album")
        cold.albums.onAdd = { added.fulfill() }

        cold.complete(decoded, assetID: "uploaded-photo")
        await fulfillment(of: [added], timeout: 2)
        await cold.service.waitUntilFinished()

        XCTAssertEqual(cold.albums.createdNames, ["Trips"])
        XCTAssertEqual(cold.albums.addedIDs, [["uploaded-photo"]])
        XCTAssertEqual(cold.albums.destinationIDs, ["album-Trips"])
        XCTAssertEqual(cold.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "uploaded-photo")
        XCTAssertNil(cold.queue.item(id: context.localIdentifier))
        XCTAssertEqual(cold.queue.snapshot.completed, 1)
    }

    func testOriginalQueueAlbumWinsAndTaskMetadataRepairsOlderOrMissingNames() async throws {
        let cases: [(String?, String?, String)] = [
            ("Queue Album", "Task Album", "Queue Album"),
            ("Queue Album", nil, "Queue Album"),
            (nil, "Task Album", "Task Album"),
        ]
        for (queueName, taskName, expectedName) in cases {
            let fixture = try fixture()
            let context = try fixture.startUpload(queueName: queueName, contextName: taskName)
            let added = expectation(description: "Saved album intent was used")
            fixture.albums.onAdd = { added.fulfill() }

            fixture.complete(context, assetID: "uploaded")
            await fulfillment(of: [added], timeout: 2)
            await fixture.service.waitUntilFinished()

            XCTAssertEqual(fixture.albums.createdNames, [expectedName])
            XCTAssertEqual(fixture.albums.addedIDs, [["uploaded"]])
        }
    }

    func testSurvivingTaskCanPlaceItsAssetAfterItsQueueRecordWasLost() async throws {
        let fixture = try fixture()
        let context = BackupUploadTaskContext(phase: .primaryAsset,
            localIdentifier: "surviving-\(UUID())", checksum: "sha", bodyPath: "/tmp/surviving.multipart",
            ownership: try XCTUnwrap(fixture.queue.ownership), sourceAlbumName: "Camera")
        let added = expectation(description: "Context-only recovery placed its uploaded photo")
        fixture.albums.onAdd = { added.fulfill() }

        fixture.complete(context, assetID: "surviving-photo")
        await fulfillment(of: [added], timeout: 2)
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.createdNames, ["Camera"])
        XCTAssertEqual(fixture.albums.addedIDs, [["surviving-photo"]])
        XCTAssertEqual(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "surviving-photo")
        XCTAssertEqual(fixture.queue.snapshot.completed, 1)
    }

    func testAcceptedSuccessWithAnExistingRecordPlacesTheAuthoritativeMappedAsset() async throws {
        let fixture = try fixture()
        let context = try fixture.startUpload(queueName: "Camera", contextName: "Camera")
        try fixture.data.upsertBackupRecord(assetID: "already-recorded", checksum: context.checksum,
            localIdentifier: context.localIdentifier)
        let added = expectation(description: "The existing mapping still gets its album placement")
        fixture.albums.onAdd = { added.fulfill() }

        fixture.complete(context, assetID: "late-response-id")
        await fulfillment(of: [added], timeout: 2)
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.albums.addedIDs, [["already-recorded"]])
        XCTAssertEqual(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "already-recorded")
        XCTAssertNil(fixture.queue.item(id: context.localIdentifier))
    }

    func testFailureWithAnExistingRecordDoesNotScheduleAlbumWork() async throws {
        let fixture = try fixture()
        let context = try fixture.startUpload(queueName: "Camera", contextName: "Camera")
        try fixture.data.upsertBackupRecord(assetID: "already-recorded", checksum: context.checksum,
            localIdentifier: context.localIdentifier)
        let lookup = expectation(description: "A failed callback must not place an album")
        lookup.isInverted = true
        fixture.albums.onLookup = { lookup.fulfill() }

        fixture.service.finishUpload(context: context, taskIdentifier: 42,
            outcome: .failure(URLError(.timedOut)), remainingBackgroundTasks: 0)
        await fixture.service.waitUntilFinished()
        await fulfillment(of: [lookup], timeout: 0.1)

        XCTAssertTrue(fixture.albums.addedIDs.isEmpty)
        XCTAssertEqual(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "already-recorded")
    }

    func testDisabledAlbumSyncAndLegacyUnnamedTasksStillCompleteWithoutAlbumWork() async throws {
        for enabled in [false, true] {
            let fixture = try fixture()
            fixture.service.syncAlbums = enabled
            let name: String? = enabled ? nil : "Camera"
            let context = try fixture.startUpload(queueName: name, contextName: name)
            let lookup = expectation(description: "No album placement was requested")
            lookup.isInverted = true
            fixture.albums.onLookup = { lookup.fulfill() }

            fixture.complete(context, assetID: "uploaded")
            await fixture.service.waitUntilFinished()
            await fulfillment(of: [lookup], timeout: 0.1)

            XCTAssertEqual(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "uploaded")
            XCTAssertEqual(fixture.queue.snapshot.completed, 1)
            XCTAssertTrue(fixture.albums.addedIDs.isEmpty)
        }
    }

    func testForeignCompletionCannotUseItsSavedAlbumName() async throws {
        let fixture = try fixture()
        var context = try fixture.startUpload(queueName: "Camera", contextName: "Camera")
        let current = try XCTUnwrap(context.ownership)
        context.ownership = .init(owner: .init(server: current.owner.server, userID: "other-account"),
                                  generation: current.generation)
        let before = fixture.queue.snapshot
        let lookup = expectation(description: "Foreign album intent must not reach the repository")
        lookup.isInverted = true
        fixture.albums.onLookup = { lookup.fulfill() }

        fixture.complete(context, assetID: "foreign-upload")
        await fixture.service.waitUntilFinished()
        await fulfillment(of: [lookup], timeout: 0.1)

        XCTAssertEqual(fixture.queue.snapshot, before)
        XCTAssertNil(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier))
    }

    func testFailedAlbumLookupDoesNotUndoTheDurableSuccessfulUpload() async throws {
        let fixture = try fixture()
        fixture.albums.lookupError = URLError(.timedOut)
        let lookup = expectation(description: "Album lookup failed after upload completion")
        fixture.albums.onLookup = { lookup.fulfill() }
        let context = try fixture.startUpload(queueName: "Camera", contextName: "Camera")

        fixture.complete(context, assetID: "uploaded")
        await fulfillment(of: [lookup], timeout: 2)
        await fixture.service.waitUntilFinished()

        XCTAssertEqual(fixture.data.getBackupRecord(localIdentifier: context.localIdentifier)?.assetId, "uploaded")
        XCTAssertEqual(fixture.queue.snapshot.completed, 1)
        XCTAssertTrue(fixture.albums.createdNames.isEmpty, "A failed lookup does not prove the album is absent")
        XCTAssertTrue(fixture.albums.addedIDs.isEmpty)
    }

    private func fixture(directory existing: URL? = nil) throws -> PlacementFixture {
        let directory = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("album-completion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let session = PlacementSession(dataManager: data)
        let albums = PlacementAlbums(api: APIClient(session: session))
        let service = BackupService(dataManager: data, queue: queue, makeAlbumRepository: { _ in albums })
        service.configure(session: session)
        let fixture = PlacementFixture(directory: directory, data: data, queue: queue,
            session: session, albums: albums, service: service)
        fixtures.append(fixture)
        return fixture
    }
}

@MainActor
private struct PlacementFixture {
    let directory: URL
    let data: SwiftDataManager
    let queue: BackupQueueStore
    let session: PlacementSession
    let albums: PlacementAlbums
    let service: BackupService

    func startUpload(
        queueName: String?, contextName: String?, taskIdentifier: Int = 42
    ) throws -> BackupUploadTaskContext {
        let id = "device-photo-\(UUID())"
        try queue.enqueue([id])
        try queue.markPreparing(id, phase: .primaryAsset, sourceAlbumName: queueName)
        try queue.markUploading(id, phase: .primaryAsset, checksum: "sha", taskIdentifier: taskIdentifier)
        return BackupUploadTaskContext(phase: .primaryAsset, localIdentifier: id,
            checksum: "sha", bodyPath: directory.appendingPathComponent("upload.multipart").path,
            ownership: try XCTUnwrap(queue.ownership), sourceAlbumName: contextName)
    }

    func complete(_ context: BackupUploadTaskContext, assetID: String, taskIdentifier: Int = 42) {
        service.finishUpload(context: context, taskIdentifier: taskIdentifier,
            outcome: .success(assetID), remainingBackgroundTasks: 0)
    }
}

@MainActor
private final class PlacementSession: SessionManager {
    init(dataManager: SwiftDataManager) {
        super.init(dataManager: dataManager, restoresSession: false)
        isLoggedIn = true
    }
    override var backupQueueOwner: BackupQueueOwner? {
        .init(server: "https://album-recovery.example/api", userID: "owner")
    }
}

@MainActor
private final class PlacementAlbums: AlbumRepository {
    var createdNames: [String] = []
    var addedIDs: [[String]] = []
    var destinationIDs: [String] = []
    var onLookup: (() -> Void)?
    var onAdd: (() -> Void)?
    var lookupError: Error?

    override func all() async throws -> [AlbumResponseDTO] {
        onLookup?()
        if let lookupError { throw lookupError }
        return []
    }

    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        createdNames.append(name)
        return .init(id: "album-\(name)", albumName: name, description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
    }

    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        addedIDs.append(ids)
        destinationIDs.append(albumId)
        onAdd?()
        return []
    }
}
