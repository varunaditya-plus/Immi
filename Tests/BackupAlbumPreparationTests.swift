import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumPreparationTests: XCTestCase {
    private var fixtures: [AlbumPreparationFixture] = []
    private var closeReads: [() -> Void] = []
    private var savedDefaults: [String: Any] = [:]
    private let defaultKeys = ["backup.enabled", "backup.syncAlbums", "backup.cellularPhotos", "backup.cellularVideos"]

    override func setUp() async throws {
        try await super.setUp()
        for key in defaultKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(key == "backup.syncAlbums", forKey: key)
        }
    }

    override func tearDown() async throws {
        closeReads.forEach { $0() }
        closeReads.removeAll()
        for fixture in fixtures { fixture.cleanup() }
        fixtures.removeAll()
        for key in defaultKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testColdManualPreparationPersistsSelectedAlbumBeforeExportingOriginal() async throws {
        let held = gate()
        let fixture = try fixture { ids in
            XCTAssertEqual(ids, ["selected"])
            return await held.value()
        }
        try fixture.enqueue()
        let preparation = Task { await fixture.prepare() }
        addTeardownBlock { preparation.cancel(); await held.close(); await preparation.value }
        await fulfillment(of: [held.started], timeout: 2)

        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.state, .preparing)
        XCTAssertTrue(fixture.exports.records.isEmpty, "Export must wait for the selected-album metadata")
        XCTAssertTrue(fixture.library.albumTitles.isEmpty)
        XCTAssertTrue(fixture.library.photos.isEmpty)
        held.complete([fixture.photo.id: "Cold Launch Album"])
        await preparation.value

        let exported = try XCTUnwrap(fixture.exports.records.first)
        XCTAssertEqual(fixture.exports.records.count, 1)
        XCTAssertEqual(exported.id, LocalPhotoLibrary.assetID(for: fixture.photo.id))
        XCTAssertFalse(exported.allowsNetwork)
        XCTAssertEqual(exported.item?.state, .preparing)
        XCTAssertEqual(exported.item?.sourceAlbumName, "Cold Launch Album")
        XCTAssertEqual(exported.persistedItem?.sourceAlbumName, "Cold Launch Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.state, .waitingForICloud)
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.sourceAlbumName, "Cold Launch Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.intent, .manualUpload)
        XCTAssertTrue(fixture.library.photos.isEmpty)
    }

    func testPersistedDestinationWinsWithoutReadingTheCurrentSelectedAlbums() async throws {
        var scans = 0
        let fixture = try fixture { _ in
            scans += 1
            return .init(photos: [], albumTitles: [:])
        }
        try fixture.enqueue(sourceAlbumName: "Original Queued Album")

        await fixture.prepare()

        XCTAssertEqual(scans, 0)
        XCTAssertEqual(fixture.exports.records.count, 1)
        XCTAssertEqual(fixture.exports.records.first?.persistedItem?.sourceAlbumName, "Original Queued Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.sourceAlbumName, "Original Queued Album")
    }

    func testColdManualPreparationReadsAndPersistsAlbumMetadataWithoutATimelineLoad() async throws {
        var scans = 0
        let fixture = try fixture { ids in
            XCTAssertEqual(ids, ["selected"])
            scans += 1
            return .init(photos: [], albumTitles: ["photo": "Selected Album"])
        }
        try fixture.enqueue()
        XCTAssertTrue(fixture.library.albumTitles.isEmpty)

        await fixture.prepare()

        XCTAssertEqual(scans, 1)
        XCTAssertEqual(fixture.exports.records.count, 1)
        XCTAssertEqual(fixture.exports.records.first?.item?.sourceAlbumName, "Selected Album")
        XCTAssertEqual(fixture.exports.records.first?.persistedItem?.sourceAlbumName, "Selected Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.sourceAlbumName, "Selected Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.intent, .manualUpload)
        XCTAssertTrue(fixture.library.photos.isEmpty)
    }

    func testDisabledAlbumSyncDoesNotEnumerateAlbumsBeforeOrdinaryPreparation() async throws {
        var scans = 0
        let fixture = try fixture { _ in
            scans += 1
            return .init(photos: [], albumTitles: [:])
        }
        fixture.service.syncAlbums = false
        try fixture.enqueue()

        await fixture.prepare()

        XCTAssertEqual(scans, 0)
        XCTAssertEqual(fixture.exports.records.count, 1)
        XCTAssertNil(fixture.exports.records.first?.item?.sourceAlbumName)
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.state, .waitingForICloud)
    }

    func testLibraryChangeDuringMetadataReadRetainsManualIntentAndRetriesBeforeExport() async throws {
        let held = gate()
        var scans = 0
        let fixture = try fixture { _ in
            scans += 1
            return scans == 1 ? await held.value() : .init(photos: [], albumTitles: ["photo": "Current Album"])
        }
        try fixture.enqueue()
        let preparation = Task { await fixture.prepare() }
        addTeardownBlock { preparation.cancel(); await held.close(); await preparation.value }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.library.libraryDidChange()
        held.complete([fixture.photo.id: "Obsolete Album"])
        await preparation.value

        let retry = try XCTUnwrap(fixture.queue.item(id: fixture.photo.id))
        XCTAssertEqual(retry.state, .retryScheduled)
        XCTAssertEqual(retry.intent, .manualUpload)
        XCTAssertNotNil(retry.nextAttemptAt)
        XCTAssertNil(retry.sourceAlbumName)
        XCTAssertTrue(fixture.exports.records.isEmpty)
        XCTAssertNotNil(fixture.service.lastError)
        try fixture.queue.markQueued(fixture.photo.id)

        await fixture.prepare()

        XCTAssertEqual(scans, 2)
        XCTAssertEqual(fixture.exports.records.count, 1)
        XCTAssertEqual(fixture.exports.records.first?.persistedItem?.sourceAlbumName, "Current Album")
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.intent, .manualUpload)
    }

    func testDeniedMetadataAccessPreservesTheQueuedRequestWithoutExporting() async throws {
        let access = AlbumPreparationAccess(.denied)
        var scans = 0
        let fixture = try fixture(access: access) { _ in
            scans += 1
            return .init(photos: [], albumTitles: [:])
        }
        try fixture.enqueue()

        await fixture.prepare()

        let retry = try XCTUnwrap(fixture.queue.item(id: fixture.photo.id))
        XCTAssertEqual(retry.state, .retryScheduled)
        XCTAssertEqual(retry.intent, .manualUpload)
        XCTAssertNotNil(retry.nextAttemptAt)
        XCTAssertNil(retry.sourceAlbumName)
        XCTAssertEqual(scans, 0)
        XCTAssertTrue(fixture.exports.records.isEmpty)
        XCTAssertNotNil(fixture.service.lastError)
    }

    func testParentCancellationDuringMetadataReadReleasesPreparationWithoutExporting() async throws {
        let held = gate()
        let fixture = try fixture { _ in await held.value() }
        try fixture.enqueue()
        let preparation = Task { await fixture.prepare() }
        addTeardownBlock { preparation.cancel(); await held.close(); await preparation.value }
        await fulfillment(of: [held.started], timeout: 2)
        preparation.cancel()
        held.complete([fixture.photo.id: "Canceled Album"])
        await preparation.value

        let retained = try XCTUnwrap(fixture.queue.item(id: fixture.photo.id))
        XCTAssertEqual(retained.state, .queued)
        XCTAssertEqual(retained.intent, .manualUpload)
        XCTAssertNil(retained.sourceAlbumName)
        XCTAssertNil(retained.lastError)
        XCTAssertTrue(fixture.exports.records.isEmpty)
    }

    func testIndividualCancellationDuringMetadataReadCannotResumeIntoStaging() async throws {
        let held = gate()
        let fixture = try fixture { _ in await held.value() }
        try fixture.enqueue()
        let preparation = Task { await fixture.prepare() }
        addTeardownBlock { preparation.cancel(); await held.close(); await preparation.value }
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id)?.state, .preparing)
        fixture.service.cancelUpload(fixture.photo.id)
        held.complete([fixture.photo.id: "Canceled Album"])
        await preparation.value

        let canceled = try XCTUnwrap(fixture.queue.item(id: fixture.photo.id))
        XCTAssertEqual(canceled.state, .failed)
        XCTAssertEqual(canceled.intent, .manualUpload)
        XCTAssertNil(canceled.sourceAlbumName)
        XCTAssertNotNil(canceled.lastError)
        XCTAssertTrue(fixture.exports.records.isEmpty)
    }

    func testAccountReplacementDuringMetadataReadCannotChangeTheNewOwnersSameIDRequest() async throws {
        let held = gate()
        let fixture = try fixture { _ in await held.value() }
        try fixture.enqueue()
        let oldOwnership = try XCTUnwrap(fixture.service.uploadOwnership)
        let preparation = Task { await fixture.prepare(ownership: oldOwnership) }
        addTeardownBlock { preparation.cancel(); await held.close(); await preparation.value }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.replaceAccount()
        try fixture.enqueue()
        let newRequest = try XCTUnwrap(fixture.queue.item(id: fixture.photo.id))
        XCTAssertNotEqual(fixture.service.uploadOwnership, oldOwnership)
        held.complete([fixture.photo.id: "Previous Account Album"])
        await preparation.value

        XCTAssertEqual(fixture.queue.item(id: fixture.photo.id), newRequest)
        XCTAssertEqual(newRequest.state, .queued)
        XCTAssertNil(newRequest.sourceAlbumName)
        XCTAssertTrue(fixture.exports.records.isEmpty)
    }

    private func fixture(
        access: AlbumPreparationAccess? = nil,
        scan: @escaping (Set<String>) async -> LocalPhotoScan
    ) throws -> AlbumPreparationFixture {
        let fixture = try AlbumPreparationFixture(access: access ?? .init(.authorized), scan: scan)
        fixtures.append(fixture)
        return fixture
    }

    private func gate() -> AlbumPreparationReadGate {
        let gate = AlbumPreparationReadGate()
        closeReads.append { gate.close() }
        return gate
    }
}

@MainActor
private final class AlbumPreparationFixture {
    let directory: URL
    let suiteName: String
    let queue: BackupQueueStore
    let manager: SwiftDataManager
    let library: LocalPhotoLibrary
    let exports: AlbumPreparationExports
    let service: BackupService
    let photo: LocalPhoto
    private var sessions: [AlbumPreparationSession]

    init(access: AlbumPreparationAccess, scan: @escaping (Set<String>) async -> LocalPhotoScan) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-preparation-\(UUID())")
        suiteName = "BackupAlbumPreparationTests.\(UUID())"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queueURL = directory.appendingPathComponent("queue.json")
        let queue = BackupQueueStore(fileURL: queueURL)
        self.queue = queue
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        self.manager = manager
        let library = LocalPhotoLibrary(defaults: UserDefaults(suiteName: suiteName)!, reader: .init(
            authorizationStatus: { access.status },
            requestAuthorization: { XCTFail("These preparations must not prompt for Photos access"); return access.status },
            photosInAlbums: scan))
        self.library = library
        library.selectedAlbumIDs = ["selected"]
        let exports = AlbumPreparationExports(queue: queue, url: queueURL)
        self.exports = exports
        let session = AlbumPreparationSession(owner: .init(server: "https://album-preparation.example/api", userID: "first-owner"), manager: manager)
        sessions = [session]
        service = BackupService(dataManager: manager, queue: queue, localLibrary: library,
            readOriginalFile: { id, allowsNetwork in await exports.read(id, allowsNetwork: allowsNetwork) })
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        photo = LocalPhoto(id: "photo", createdAt: date, modifiedAt: date,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        service.configure(session: session)
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }

    func enqueue(sourceAlbumName: String? = nil) throws {
        try queue.enqueue([photo.id], intent: .manualUpload)
        if let sourceAlbumName {
            try queue.markPreparing(photo.id, phase: .primaryAsset, sourceAlbumName: sourceAlbumName)
            try queue.markQueued(photo.id)
        }
    }

    func prepare(ownership: BackupUploadOwnership? = nil) async {
        guard let ownership = ownership ?? service.uploadOwnership, let session = sessions.last else {
            XCTFail("Preparation requires a configured account")
            return
        }
        await service.prepareQueuePhoto(photo, repository: BackupRepository(api: APIClient(session: session)),
            mayReadFromICloud: false, ownership: ownership)
    }

    func replaceAccount() {
        let session = AlbumPreparationSession(owner: .init(server: "https://album-preparation.example/api", userID: "next-owner"), manager: manager)
        sessions.append(session)
        service.configure(session: session)
    }

    func cleanup() {
        service.resetForLogout()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class AlbumPreparationSession: SessionManager {
    private let owner: BackupQueueOwner
    override var backupQueueOwner: BackupQueueOwner? { owner }

    init(owner: BackupQueueOwner, manager: SwiftDataManager) {
        self.owner = owner
        super.init(dataManager: manager, restoresSession: false)
        isLoggedIn = true
    }
}

@MainActor
private final class AlbumPreparationAccess {
    var status: PHAuthorizationStatus
    init(_ status: PHAuthorizationStatus) { self.status = status }
}

@MainActor
private final class AlbumPreparationExports {
    struct Record {
        let id: String
        let allowsNetwork: Bool
        let item: BackupQueueItem?
        let persistedItem: BackupQueueItem?
    }

    private let queue: BackupQueueStore
    private let url: URL
    private(set) var records: [Record] = []

    init(queue: BackupQueueStore, url: URL) { self.queue = queue; self.url = url }

    func read(_ id: String, allowsNetwork: Bool) async -> (url: URL, filename: String)? {
        let localID = LocalPhotoLibrary.localIdentifier(from: id)
        records.append(.init(id: id, allowsNetwork: allowsNetwork, item: queue.item(id: localID),
            persistedItem: BackupQueueStore(fileURL: url).item(id: localID)))
        return nil
    }
}

@MainActor
private final class AlbumPreparationReadGate {
    let started = XCTestExpectation(description: "Source-album metadata is held before staging")
    private var continuation: CheckedContinuation<LocalPhotoScan, Never>?
    private var result: LocalPhotoScan?

    func value() async -> LocalPhotoScan {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func complete(_ titles: [String: String]) {
        let result = LocalPhotoScan(photos: [], albumTitles: titles)
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func close() { complete([:]) }
}
