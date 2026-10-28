import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadStatusReportingTests: XCTestCase {
    private var fixtures: [SharedStatusFixture] = []
    private var gates: [SharedStatusGate] = []
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["backup.enabled", "backup.syncAlbums", "backup.cellularPhotos", "backup.cellularVideos"]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() async throws {
        for gate in gates { gate.release() }
        gates.removeAll()
        for fixture in fixtures { fixture.close() }
        fixtures.removeAll()
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testRealSharedUploadPublishesUploadingWhileItsNetworkRequestIsHeld() async throws {
        let gate = gate()
        let fixture = try fixture(upload: { credential, item, file, _ in
            XCTAssertEqual(credential.owner.userID, "first-owner")
            XCTAssertEqual(item.filename, "shared-0.jpg")
            XCTAssertEqual(try Data(contentsOf: file), Data("original media".utf8))
            await gate.wait()
        })
        let batch = try await fixture.seed()
        await fixture.shared.refreshPending(session: fixture.session)
        XCTAssertEqual(fixture.shared.items.map(\.item.state), [.queued])
        XCTAssertEqual(fixture.status, .waiting)

        let work = try XCTUnwrap(fixture.shared.processPending(session: fixture.session))
        addTeardownBlock { await gate.release(); await work.value }
        await fulfillment(of: [gate.started], timeout: 2)

        XCTAssertEqual(fixture.shared.items.map(\.item.state), [.uploading])
        XCTAssertEqual(fixture.shared.items.map(\.item.id), batch.items.map(\.id))
        let stored = try await fixture.store.batch(id: batch.id, owner: batch.owner)
        XCTAssertEqual(stored?.items.first?.state, .uploading)
        XCTAssertEqual(fixture.status, .uploading)
        XCTAssertFalse(fixture.backup.isEnabled)
        XCTAssertFalse(fixture.backup.isUploading, "The status must come from the real shared transfer")
        gate.release()
        await work.value

        XCTAssertTrue(fixture.shared.items.isEmpty)
        XCTAssertEqual(fixture.status, .off)
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCompletingSharedUploadRestoresVerifiedNativeBackupStatus() async throws {
        let gate = gate()
        let fixture = try fixture(enabled: true, upload: { _, _, _, _ in await gate.wait() })
        try fixture.manager.upsertBackupRecord(assetID: "server-local", checksum: "sha", localIdentifier: "local")
        await fixture.library.load()
        fixture.backup.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)
        _ = try await fixture.seed()
        let work = try XCTUnwrap(fixture.shared.processPending(session: fixture.session))
        addTeardownBlock { await gate.release(); await work.value }
        await fulfillment(of: [gate.started], timeout: 2)

        XCTAssertEqual(fixture.backup.selectionStatus, .backedUp)
        XCTAssertEqual(fixture.status, .uploading)
        gate.release()
        await work.value

        XCTAssertTrue(fixture.shared.items.isEmpty)
        XCTAssertEqual(fixture.status, .synced)
    }

    func testEverySharedItemPublishesItsOwnStartAndRemovesCompletedNeighbors() async throws {
        let first = gate()
        let second = gate()
        var uploaded: [UUID] = []
        let fixture = try fixture(upload: { _, item, _, _ in
            uploaded.append(item.id)
            await (uploaded.count == 1 ? first : second).wait()
        })
        let batch = try await fixture.seed(count: 2)
        let work = try XCTUnwrap(fixture.shared.processPending(session: fixture.session))
        addTeardownBlock { await first.release(); await second.release(); await work.value }
        await fulfillment(of: [first.started], timeout: 2)

        XCTAssertEqual(fixture.shared.items.map(\.item.state), [.uploading, .queued])
        XCTAssertEqual(fixture.status, .uploading)
        first.release()
        await fulfillment(of: [second.started], timeout: 2)

        XCTAssertEqual(uploaded, batch.items.map(\.id))
        XCTAssertEqual(fixture.shared.items.map(\.item.id), [batch.items[1].id])
        XCTAssertEqual(fixture.shared.items.map(\.item.state), [.uploading])
        XCTAssertEqual(fixture.status, .uploading)
        second.release()
        await work.value

        XCTAssertTrue(fixture.shared.items.isEmpty)
        XCTAssertEqual(fixture.status, .off)
    }

    func testRejectedSharedUploadPublishesFailureAfterTheHeldRequestReturns() async throws {
        let gate = gate()
        let fixture = try fixture(upload: { _, _, _, _ in
            await gate.wait()
            throw SharedUploadClientError.server(status: 413, message: "Original is too large")
        })
        let batch = try await fixture.seed()
        let work = try XCTUnwrap(fixture.shared.processPending(session: fixture.session))
        addTeardownBlock { await gate.release(); await work.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(fixture.status, .uploading)

        gate.release()
        await work.value

        XCTAssertEqual(fixture.shared.items.map(\.item.state), [.failed])
        XCTAssertTrue(fixture.shared.items.first?.item.lastError?.contains("413") == true)
        XCTAssertEqual(fixture.status, .failed)
        let stored = try await fixture.store.batch(id: batch.id, owner: batch.owner)
        XCTAssertEqual(stored?.items.first?.state, .failed)
    }

    func testLateAcceptedResponseCannotPublishOldProgressIntoAReplacementAccount() async throws {
        let gate = gate()
        let fixture = try fixture(upload: { _, _, _, _ in await gate.wait() })
        let old = try await fixture.seed()
        let work = try XCTUnwrap(fixture.shared.processPending(session: fixture.session))
        addTeardownBlock { await gate.release(); await work.value }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(fixture.status, .uploading)
        XCTAssertEqual(fixture.shared.items.first?.owner, old.owner)

        fixture.shared.cancel()
        fixture.session.isLoggedIn = false
        fixture.session.cancelAuthentication()
        fixture.session.owner = .init(server: old.owner.server, userID: "replacement-owner")
        fixture.session.isLoggedIn = true
        let replacementOwner = SharedUploadOwner(server: old.owner.server, userID: "replacement-owner")
        let replacement = try await fixture.seed(owner: replacementOwner, state: .failed)
        await fixture.shared.refreshPending(session: fixture.session)
        XCTAssertEqual(fixture.status, .failed)
        gate.release()
        await work.value

        XCTAssertEqual(fixture.shared.items.map(\.item), replacement.items)
        XCTAssertEqual(fixture.shared.items.first?.owner, replacementOwner)
        XCTAssertEqual(fixture.status, .failed)
        let completed = try await fixture.store.batch(id: old.id, owner: old.owner)
        XCTAssertNil(completed, "Accepted old-account uploads still save success and clean their own source")
        let retained = try await fixture.store.batch(id: replacement.id, owner: replacementOwner)
        XCTAssertEqual(retained, replacement)
    }

    private func fixture(
        enabled: Bool = false,
        upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void
    ) throws -> SharedStatusFixture {
        UserDefaults.standard.set(enabled, forKey: "backup.enabled")
        let fixture = try SharedStatusFixture(upload: upload)
        fixtures.append(fixture)
        return fixture
    }

    private func gate() -> SharedStatusGate {
        let gate = SharedStatusGate()
        gates.append(gate)
        return gate
    }
}

@MainActor
private final class SharedStatusFixture {
    let root: URL
    let suite: String
    let store: SharedUploadStore
    let shared: SharedUploadService
    let library: LocalPhotoLibrary
    private var retainedSession: SharedStatusSession?
    private var retainedManager: SwiftDataManager?
    private var retainedBackup: BackupService?
    var manager: SwiftDataManager { retainedManager! }
    var backup: BackupService { retainedBackup! }
    var session: SharedStatusSession { retainedSession! }
    var status: BackupStatus { BackupStatus(backup: backup, sharedUploads: shared) }

    init(upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-status-\(UUID())")
        suite = "SharedUploadStatusReportingTests.\(UUID())"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: root.appendingPathComponent("test.store"),
            backupJournalURL: root.appendingPathComponent("backup.json"))
        retainedManager = manager
        let queue = BackupQueueStore(fileURL: root.appendingPathComponent("queue.json"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        library = LocalPhotoLibrary(defaults: UserDefaults(suiteName: suite)!, reader: .init(
            authorizationStatus: { .authorized }, requestAuthorization: {
                XCTFail("Status reporting must not request Photos access"); return .authorized
            }, photosInAlbums: { _ in
                .init(photos: [.init(id: "local", createdAt: date, modifiedAt: date,
                    isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)],
                    albumTitles: ["local": "Selected Album"])
            }))
        library.selectedAlbumIDs = ["selected"]
        retainedBackup = BackupService(dataManager: manager, queue: queue, localLibrary: library)
        store = SharedUploadStore(rootURL: root.appendingPathComponent("shared", isDirectory: true))
        shared = SharedUploadService(store: store, upload: upload)
        retainedSession = try SharedStatusSession(manager: manager)
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }

    func seed(count: Int = 1, owner: SharedUploadOwner? = nil, state: SharedUploadItemState = .queued) async throws -> SharedUploadBatch {
        let id = UUID()
        let directory = try await store.makeBatchDirectory(id: id)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = try (0..<count).map { index in
            let name = "shared-\(index).jpg"
            let bytes = Data("original media".utf8)
            try bytes.write(to: directory.appendingPathComponent(name))
            return SharedUploadItem(id: UUID(), filename: name, relativePath: name,
                contentType: "image/jpeg", byteCount: Int64(bytes.count), createdAt: date, modifiedAt: date,
                state: state, lastError: state == .failed ? "HTTP 413: Too large" : nil)
        }
        let batch = SharedUploadBatch(id: id,
            owner: owner ?? .init(server: "https://shared-status.example/api", userID: "first-owner"),
            createdAt: date, items: items)
        try await store.save(batch)
        return batch
    }

    func close() {
        shared.cancel()
        retainedBackup?.stop()
        retainedBackup = nil
        retainedSession = nil
        retainedManager = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class SharedStatusSession: SessionManager {
    var owner = BackupQueueOwner(server: "https://shared-status.example/api", userID: "first-owner")
    override var backupQueueOwner: BackupQueueOwner? { owner }
    override var authHeaders: [String: String] { ["x-api-key": "shared-status-test"] }

    init(manager: SwiftDataManager) throws {
        super.init(dataManager: manager, restoresSession: false)
        try setServer("https://shared-status.example")
        isLoggedIn = true
    }
}

@MainActor
private final class SharedStatusGate {
    let started = XCTestExpectation(description: "A real shared upload reached its held network request")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

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
