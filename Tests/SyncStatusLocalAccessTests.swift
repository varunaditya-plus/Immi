import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class SyncStatusLocalAccessTests: XCTestCase {
    private var directories: [URL] = []
    private var defaultsNames: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        for name in defaultsNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        directories.removeAll()
        defaultsNames.removeAll()
        try await super.tearDown()
    }

    func testRevokedCachedAccessFailsWithoutPreparingOrReportingSuccess() async throws {
        for status in [PHAuthorizationStatus.denied, .restricted] {
            let fixture = try fixture(status: .authorized)
            XCTAssertTrue(fixture.library.isAuthorized)
            fixture.access.status = status

            await fixture.model.run(.syncLocal, appSync: nil)

            assertFailed(fixture.model)
            XCTAssertFalse(fixture.library.isAuthorized)
            XCTAssertEqual(fixture.access.preparations, 0)
            XCTAssertEqual(fixture.access.countReads, 0)
            XCTAssertEqual(fixture.access.permissionRequests, 0)
        }
    }

    func testRejectingInitialPermissionFailsWithoutPreparing() async throws {
        let fixture = try fixture(status: .notDetermined)
        fixture.access.requestedStatus = .denied

        await fixture.model.run(.syncLocal, appSync: nil)

        assertFailed(fixture.model)
        XCTAssertEqual(fixture.access.permissionRequests, 1)
        XCTAssertEqual(fixture.access.preparations, 0)
        XCTAssertEqual(fixture.access.countReads, 0)
    }

    func testReadableEmptyLibrarySucceedsForFullAndLimitedAccess() async throws {
        for status in [PHAuthorizationStatus.authorized, .limited] {
            let fixture = try fixture(status: status)

            await fixture.model.run(.syncLocal, appSync: nil)

            guard case .succeeded(_, let message) = fixture.model.state(for: .syncLocal) else {
                XCTFail("A readable empty library must finish successfully")
                continue
            }
            XCTAssertEqual(message, "Scanned 0 local assets")
            XCTAssertEqual(fixture.model.completionFeedback, 1)
            XCTAssertNil(fixture.model.runningJob)
            XCTAssertEqual(fixture.model.localAssets, 0)
            XCTAssertEqual(fixture.model.localAlbums, 0)
            XCTAssertEqual(fixture.access.preparations, 1)
            XCTAssertEqual(fixture.access.countReads, 2, "The job and its refreshed counts read the library")
            XCTAssertEqual(fixture.access.permissionRequests, 0)
        }
    }

    func testCancelingThePermissionRequestLeavesTheJobIdle() async throws {
        let started = expectation(description: "Photos permission is suspended")
        let gate = SyncStatusOperationGate(started: started)
        let fixture = try fixture(status: .notDetermined)
        fixture.access.onPermissionRequest = { await gate.wait() }
        let task = Task { await fixture.model.run(.syncLocal, appSync: nil) }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        gate.resolve()
        await task.value

        XCTAssertEqual(fixture.model.state(for: .syncLocal), .idle)
        XCTAssertEqual(fixture.model.completionFeedback, 0)
        XCTAssertNil(fixture.model.runningJob)
        XCTAssertEqual(fixture.access.permissionRequests, 1)
        XCTAssertEqual(fixture.access.preparations, 0)
        XCTAssertEqual(fixture.access.countReads, 0)
    }

    func testSyncReportsCountsFromAfterPreparation() async throws {
        let fixture = try fixture(status: .authorized)
        fixture.access.counts = LocalLibraryStatusCounts(assets: 22, albums: 3)
        fixture.access.onPrepare = { [weak access = fixture.access] in
            access?.counts = LocalLibraryStatusCounts(assets: 1, albums: 1)
        }

        await fixture.model.run(.syncLocal, appSync: nil)

        guard case .succeeded(_, let message) = fixture.model.state(for: .syncLocal) else {
            return XCTFail("The current scan must succeed")
        }
        XCTAssertEqual(message, "Scanned 1 local asset")
        XCTAssertEqual(fixture.model.localAssets, 1)
        XCTAssertEqual(fixture.model.localAlbums, 1)
        XCTAssertEqual(fixture.model.completionFeedback, 1)
    }

    func testRevokingAccessDuringPreparationFailsWithoutSuccessFeedback() async throws {
        let started = expectation(description: "Preparation is suspended")
        let gate = SyncStatusOperationGate(started: started)
        let fixture = try fixture(status: .authorized)
        fixture.access.onPrepare = { await gate.wait() }
        let task = Task { await fixture.model.run(.syncLocal, appSync: nil) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.model.state(for: .syncLocal), .running)

        fixture.access.status = .denied
        gate.resolve()
        await task.value

        assertFailed(fixture.model)
        XCTAssertEqual(fixture.access.preparations, 1)
        XCTAssertEqual(fixture.access.countReads, 0)
    }

    func testCanceledPreparationCannotReportACompletedScan() async throws {
        let started = expectation(description: "Preparation is suspended")
        let gate = SyncStatusOperationGate(started: started)
        let fixture = try fixture(status: .authorized)
        fixture.access.onPrepare = { await gate.wait() }
        let task = Task { await fixture.model.run(.syncLocal, appSync: nil) }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        gate.resolve()
        await task.value

        XCTAssertEqual(fixture.model.state(for: .syncLocal), .idle)
        XCTAssertEqual(fixture.model.completionFeedback, 0)
        XCTAssertNil(fixture.model.runningJob)
        XCTAssertEqual(fixture.access.countReads, 0)
    }

    func testRefreshingDeniedCountsClearsOldValuesWithoutInventingZeros() async throws {
        let fixture = try fixture(status: .authorized)
        fixture.access.counts = LocalLibraryStatusCounts(assets: 22, albums: 3)
        await fixture.model.refreshCounts()
        XCTAssertEqual(fixture.model.localAssets, 22)
        XCTAssertEqual(fixture.model.localAlbums, 3)

        fixture.access.status = .denied
        await fixture.model.refreshCounts()

        XCTAssertNil(fixture.model.localAssets)
        XCTAssertNil(fixture.model.localAlbums)
        XCTAssertEqual(fixture.access.countReads, 1)
        XCTAssertEqual(fixture.model.completionFeedback, 0)
        XCTAssertFalse(fixture.model.isRefreshing)
    }

    func testAccessChangesWhileRemoteCountsAreHeldRejectTheEarlierLocalCounts() async throws {
        for status in [PHAuthorizationStatus.denied, .limited] {
            let remoteStarted = expectation(description: "All remote count requests are held")
            remoteStarted.expectedFulfillmentCount = 3
            let localRead = expectation(description: "Local counts were read before access changed")
            let gate = SyncStatusOperationGate(started: remoteStarted)
            let session = MockSessionManager()
            let api = HeldSyncStatusAPI(session: session, gate: gate)
            let fixture = try fixture(status: .authorized, api: api)
            fixture.access.counts = LocalLibraryStatusCounts(assets: 22, albums: 3)
            fixture.access.onCountRead = { localRead.fulfill() }
            let refresh = Task { await fixture.model.refreshCounts() }
            await fulfillment(of: [remoteStarted, localRead], timeout: 2)

            fixture.access.status = status
            gate.resolve()
            await refresh.value

            XCTAssertEqual(fixture.access.countReads, 1)
            XCTAssertNil(fixture.model.localAssets, "The earlier full-library count is no longer current")
            XCTAssertNil(fixture.model.localAlbums)
            XCTAssertEqual(fixture.library.authorizationStatus, status)
            XCTAssertFalse(fixture.model.isRefreshing)
        }
    }

    func testMaintenanceJobsRejectALibraryChangeDuringPhotoEnumeration() async throws {
        try await assertMaintenanceRejectsObsoletePhotos(status: .authorized)
    }

    func testMaintenanceJobsRejectALimitedSubsetChangeDuringPhotoEnumeration() async throws {
        try await assertMaintenanceRejectsObsoletePhotos(status: .limited)
    }

    func testCloudIDMatchingRejectsAPhotosChangeAfterEnumeration() async throws {
        try await assertCloudMatchingRejectsChangedAccess(revoked: false)
    }

    func testCloudIDMatchingRejectsPhotosRevocationAfterEnumeration() async throws {
        try await assertCloudMatchingRejectsChangedAccess(revoked: true)
    }

    func testCloudIDMatchingSucceedsWhilePhotosRemainCurrent() async throws {
        let started = expectation(description: "Cloud ID matching is waiting for the server")
        let gate = SyncStatusOperationGate(started: started)
        let api = HeldCloudIDsAPI(session: MockSessionManager(), gate: gate)
        let fixture = try fixture(status: .authorized, api: api)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = LocalPhoto(id: UUID().uuidString, createdAt: now, modifiedAt: now,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        fixture.access.onAllPhotosRead = { [photo] }
        try fixture.dataManager.storeChecksums([(localIdentifier: photo.id, checksum: "known-checksum")])
        let task = Task { await fixture.model.run(.syncCloudIDs, appSync: nil) }
        await fulfillment(of: [started], timeout: 2)

        gate.resolve()
        await task.value

        guard case .succeeded(_, let message) = fixture.model.state(for: .syncCloudIDs) else {
            return XCTFail("A current readable Photos scope must still complete matching")
        }
        XCTAssertEqual(message, "Cloud IDs are up to date")
        XCTAssertEqual(fixture.model.completionFeedback, 1)
        XCTAssertNil(fixture.model.runningJob)
        XCTAssertEqual(fixture.dataManager.storedChecksums()[photo.id], "known-checksum")
        XCTAssertTrue(fixture.dataManager.uploadedLocalIdentifiers().isEmpty)
    }

    private func assertCloudMatchingRejectsChangedAccess(revoked: Bool) async throws {
        let started = expectation(description: "Cloud ID matching is waiting for the server")
        let gate = SyncStatusOperationGate(started: started)
        let api = HeldCloudIDsAPI(session: MockSessionManager(), gate: gate)
        let fixture = try fixture(status: .authorized, api: api)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = LocalPhoto(id: UUID().uuidString, createdAt: now, modifiedAt: now,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
        fixture.access.onAllPhotosRead = { [photo] }
        try fixture.dataManager.storeChecksums([(localIdentifier: photo.id, checksum: "known-checksum")])
        let checksums = fixture.dataManager.storedChecksums()
        let mappings = fixture.dataManager.uploadedLocalIdentifiers()
        let task = Task { await fixture.model.run(.syncCloudIDs, appSync: nil) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.model.state(for: .syncCloudIDs), .running)

        if revoked { fixture.access.status = .denied }
        else { fixture.library.libraryDidChange() }
        gate.resolve()
        await task.value

        guard case .failed(let message) = fixture.model.state(for: .syncCloudIDs) else {
            return XCTFail("Matching must not report success after its Photos scope stopped being current")
        }
        if revoked { XCTAssertTrue(message.contains("Photos access")) }
        else { XCTAssertEqual(message, "Your photo library changed. Try again.") }
        XCTAssertEqual(fixture.model.completionFeedback, 0)
        XCTAssertNil(fixture.model.runningJob)
        XCTAssertEqual(fixture.dataManager.storedChecksums(), checksums)
        XCTAssertEqual(fixture.dataManager.uploadedLocalIdentifiers(), mappings)
    }

    private func assertMaintenanceRejectsObsoletePhotos(status: PHAuthorizationStatus) async throws {
        for job in [SyncStatusJob.hashAssets, .syncCloudIDs] {
            let fixture = try fixture(status: status)
            let started = expectation(description: "The \(job.rawValue) photo enumeration is suspended")
            let gate = SyncStatusOperationGate(started: started)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let photo = LocalPhoto(id: UUID().uuidString, createdAt: now, modifiedAt: now,
                isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
            fixture.access.onAllPhotosRead = {
                await gate.wait()
                return [photo]
            }
            let previousChecksums = fixture.dataManager.storedChecksums()
            let previousMappings = fixture.dataManager.uploadedLocalIdentifiers()
            let task = Task { await fixture.model.run(job, appSync: nil) }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(fixture.model.state(for: job), .running)

            fixture.library.libraryDidChange()
            gate.resolve()
            await task.value

            guard case .failed(let message) = fixture.model.state(for: job) else {
                XCTFail("An obsolete Photos read must fail \(job.rawValue), not report an empty successful scan")
                continue
            }
            XCTAssertEqual(message, "Your photo library changed. Try again.")
            XCTAssertEqual(fixture.model.completionFeedback, 0)
            XCTAssertNil(fixture.model.runningJob)
            XCTAssertEqual(fixture.dataManager.storedChecksums(), previousChecksums)
            XCTAssertEqual(fixture.dataManager.uploadedLocalIdentifiers(), previousMappings)
        }
    }

    private func assertFailed(
        _ model: SyncStatusViewModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failed(let message) = model.state(for: .syncLocal) else {
            return XCTFail("Denied Photos access must report a failure", file: file, line: line)
        }
        XCTAssertTrue(message.contains("Photos access"), file: file, line: line)
        XCTAssertEqual(model.completionFeedback, 0, file: file, line: line)
        XCTAssertNil(model.runningJob, file: file, line: line)
    }

    private func fixture(status: PHAuthorizationStatus, api: APIClient? = nil) throws -> (
        model: SyncStatusViewModel, library: LocalPhotoLibrary, access: SyncStatusPhotosAccess,
        dataManager: SwiftDataManager
    ) {
        let name = "sync-local-access-\(UUID())"
        defaultsNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let dataManager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let access = SyncStatusPhotosAccess(status: status)
        let library = LocalPhotoLibrary(defaults: defaults, reader: .init(
            authorizationStatus: { access.status },
            requestAuthorization: {
                access.permissionRequests += 1
                await access.onPermissionRequest?()
                access.status = access.requestedStatus
                return access.status
            },
            statusCounts: {
                access.countReads += 1
                access.onCountRead?()
                return access.counts
            },
            allPhotos: { await access.onAllPhotosRead?() ?? [] }))
        let model = SyncStatusViewModel(
            session: api?.session ?? MockSessionManager(), library: library,
            dataManager: dataManager, api: api,
            prepareLocal: {
                access.preparations += 1
                await access.onPrepare?()
            })
        return (model, library, access, dataManager)
    }
}

@MainActor
private final class SyncStatusPhotosAccess {
    var status: PHAuthorizationStatus
    var requestedStatus = PHAuthorizationStatus.authorized
    var counts = LocalLibraryStatusCounts(assets: 0, albums: 0)
    var permissionRequests = 0
    var countReads = 0
    var preparations = 0
    var onPrepare: (() async -> Void)?
    var onCountRead: (() -> Void)?
    var onPermissionRequest: (() async -> Void)?
    var onAllPhotosRead: (() async -> [LocalPhoto])?

    init(status: PHAuthorizationStatus) { self.status = status }
}

@MainActor
private final class SyncStatusOperationGate {
    let started: XCTestExpectation
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuations.append($0)
            started.fulfill()
        }
    }

    func resolve() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

@MainActor
private final class HeldSyncStatusAPI: APIClient {
    private let gate: SyncStatusOperationGate

    init(session: SessionManager, gate: SyncStatusOperationGate) {
        self.gate = gate
        super.init(session: session)
    }

    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        await gate.wait()
        throw APIError.notConnected
    }
}

@MainActor
private final class HeldCloudIDsAPI: APIClient {
    private let gate: SyncStatusOperationGate

    init(session: SessionManager, gate: SyncStatusOperationGate) {
        self.gate = gate
        super.init(session: session)
    }

    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        guard endpoint.path == "/assets/bulk-upload-check" else { throw APIError.notConnected }
        await gate.wait()
        return try JSONDecoder().decode(T.self, from: Data(#"{"results":[]}"#.utf8))
    }
}
