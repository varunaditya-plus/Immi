import Photos
import XCTest
@testable import ImmichApp

@MainActor
final class BackupStatusReportingTests: XCTestCase {
    private var fixtures: [BackupStatusFixture] = []
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
        for fixture in fixtures { fixture.close() }
        fixtures.removeAll()
        for key in defaultKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testColdZeroTotalsNeverClaimTheLibraryIsSynced() throws {
        let off = try fixture(enabled: false, selection: [])
        XCTAssertEqual(off.service.total, 0)
        XCTAssertEqual(off.service.remainder, 0)
        XCTAssertEqual(off.service.selectionStatus, .noSelection)
        XCTAssertEqual(off.status, .off)

        let enabled = try fixture(selection: [])
        XCTAssertEqual(enabled.service.total, 0)
        XCTAssertEqual(enabled.service.remainder, 0)
        XCTAssertEqual(enabled.service.selectionStatus, .noSelection)
        XCTAssertEqual(enabled.status, .needsSelection)
    }

    func testSelectedAlbumsRemainUncheckedBeforeACompletedScan() throws {
        let fixture = try fixture()

        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.total, 0)
        XCTAssertEqual(fixture.service.remainder, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        XCTAssertEqual(fixture.access.reads, 0)
    }

    func testHeldAndCanceledInitialScansCannotProduceSyncedStatus() async throws {
        let gate = BackupStatusScanGate()
        let fixture = try fixture(scan: { _ in await gate.value() })
        let scan = Task { await fixture.library.load() }
        addTeardownBlock { scan.cancel(); await gate.release(); await scan.value }
        await fulfillment(of: [gate.started], timeout: 2)
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        scan.cancel()
        gate.release()
        await scan.value
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        XCTAssertEqual(fixture.service.total, 0)
    }

    func testPrepareReadsTheInjectedLibraryAndPublishesItsVerifiedCounts() async throws {
        let fixture = try fixture(enabled: false, photos: ["mapped", "remaining"])
        try fixture.map("mapped")

        await fixture.service.prepare()

        XCTAssertEqual(fixture.access.reads, 1)
        XCTAssertEqual(fixture.service.total, 2)
        XCTAssertEqual(fixture.service.backedUp, 1)
        XCTAssertEqual(fixture.service.remainder, 1)
        XCTAssertEqual(fixture.service.selectionStatus, .remaining)
        XCTAssertEqual(fixture.status, .off)
        XCTAssertEqual(fixture.access.permissionRequests, 0)
    }

    func testOnlyACurrentScanWithEveryPhotoMappedReportsSynced() async throws {
        let fixture = try fixture(photos: ["first", "second"])
        try fixture.map("first")
        try fixture.map("second")

        await fixture.library.load()
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.total, 2)
        XCTAssertEqual(fixture.service.backedUp, 2)
        XCTAssertEqual(fixture.service.remainder, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .backedUp)
        XCTAssertEqual(fixture.status, .synced)
    }

    func testAnUnmappedPhotoMakesTheVerifiedSelectionWaitForBackup() async throws {
        let fixture = try fixture(photos: ["mapped", "not-uploaded"])
        try fixture.map("mapped")

        await fixture.library.load()
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.total, 2)
        XCTAssertEqual(fixture.service.backedUp, 1)
        XCTAssertEqual(fixture.service.remainder, 1)
        XCTAssertEqual(fixture.service.selectionStatus, .remaining)
        XCTAssertEqual(fixture.status, .waiting)
    }

    func testACompletedEmptySelectionIsDifferentFromAnUnscannedSelection() async throws {
        let fixture = try fixture(photos: [])
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)

        await fixture.library.load()
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.total, 0)
        XCTAssertEqual(fixture.service.backedUp, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .empty)
        XCTAssertEqual(fixture.status, .empty)
    }

    func testChangingTheSelectedAlbumsImmediatelyInvalidatesOldAssurance() async throws {
        let fixture = try fixture(photos: ["old-photo"])
        try fixture.map("old-photo")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)

        fixture.library.selectedAlbumIDs = ["different-selection"]

        XCTAssertEqual(fixture.service.total, 1, "Old counts may remain, but must no longer establish backup status")
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        fixture.library.selectedAlbumIDs = []
        XCTAssertEqual(fixture.service.selectionStatus, .noSelection)
        XCTAssertEqual(fixture.status, .needsSelection)
    }

    func testNewTimelineScanMustHaveMatchingCountsBeforeItCanReportSynced() async throws {
        let fixture = try fixture(photos: ["mapped"])
        try fixture.map("mapped")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)
        fixture.access.photoIDs = ["mapped", "new-photo"]

        await fixture.library.load()

        XCTAssertEqual(fixture.service.total, 1)
        XCTAssertEqual(fixture.service.remainder, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.service.total, 2)
        XCTAssertEqual(fixture.service.remainder, 1)
        XCTAssertEqual(fixture.service.selectionStatus, .remaining)
        XCTAssertEqual(fixture.status, .waiting)
    }

    func testUnlinkingAConfirmedMappingInvalidatesCountsUntilTheyAreRefreshed() async throws {
        let fixture = try fixture(photos: ["photo"])
        try fixture.map("photo")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)

        try fixture.manager.unlinkDeviceAsset(localIdentifier: "photo")

        XCTAssertEqual(fixture.service.backedUp, 1)
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.service.backedUp, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .remaining)
        XCTAssertEqual(fixture.status, .waiting)
    }

    func testAlbumMetadataLookupAloneDoesNotProveThePhotoSelectionWasScanned() async throws {
        let fixture = try fixture(photos: ["photo"])
        try fixture.map("photo")

        let title = try await fixture.library.sourceAlbumTitle(for: "photo")
        fixture.service.refreshCounts()

        XCTAssertEqual(title, "Selected Album")
        XCTAssertEqual(fixture.access.reads, 1)
        XCTAssertTrue(fixture.library.photos.isEmpty)
        XCTAssertEqual(fixture.service.total, 0)
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
    }

    func testLibraryChangesAccessRevocationAndLogoutInvalidateVerifiedStatus() async throws {
        let fixture = try fixture(photos: ["photo"])
        try fixture.map("photo")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)

        fixture.library.libraryDidChange()
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        XCTAssertEqual(fixture.status, .unchecked)
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)
        fixture.access.authorization = .denied
        fixture.library.refreshAuthorizationStatus()
        XCTAssertEqual(fixture.service.selectionStatus, .accessRequired)
        XCTAssertEqual(fixture.status, .photosAccess)
        fixture.access.authorization = .authorized
        fixture.library.refreshAuthorizationStatus()
        XCTAssertEqual(fixture.service.selectionStatus, .unchecked)
        fixture.library.resetForLogout()
        XCTAssertEqual(fixture.service.selectionStatus, .noSelection)
        XCTAssertEqual(fixture.status, .needsSelection)
    }

    func testManualQueueWorkRemainsVisibleWhenAutomaticBackupIsOff() throws {
        for state in [BackupQueueItemState.queued, .preparing, .uploading, .waitingForNetwork,
                      .waitingForICloud, .waitingForAuthentication, .retryScheduled, .failed] {
            let fixture = try fixture(enabled: false, queueState: state)

            XCTAssertFalse(fixture.service.uploadItems.isEmpty)
            XCTAssertNotEqual(fixture.status, .off, "A manual \(state) request must remain visible")
            XCTAssertNotEqual(fixture.status, .synced, "A manual \(state) request is not completed backup")
            if state == .preparing || state == .uploading { XCTAssertEqual(fixture.status, .uploading) }
            if state == .failed { XCTAssertEqual(fixture.status, .failed) }
            if state == .queued || state.isWaiting { XCTAssertEqual(fixture.status, .waiting) }
        }
    }

    func testQueuedWorkPreventsSyncedEvenWhenAllSelectedPhotosAreMapped() async throws {
        for state in [BackupQueueItemState.queued, .preparing, .waitingForICloud,
                      .waitingForAuthentication, .retryScheduled, .failed] {
            let fixture = try fixture(photos: ["mapped"], queueState: state)
            try fixture.map("mapped")
            await fixture.library.load()
            fixture.service.refreshCounts()

            XCTAssertEqual(fixture.service.selectionStatus, .backedUp)
            XCTAssertEqual(fixture.service.remainder, 0)
            XCTAssertNotEqual(fixture.status, .synced, "Outstanding \(state) work prevents completion assurance")
        }
    }

    func testPendingAlbumPlacementPreventsCompletionAssurance() async throws {
        let fixture = try fixture(photos: ["mapped"], pendingAlbum: true)
        try fixture.map("mapped")
        await fixture.library.load()
        fixture.service.refreshCounts()

        XCTAssertEqual(fixture.service.selectionStatus, .backedUp)
        XCTAssertTrue(fixture.service.hasPendingAlbumPlacements)
        XCTAssertEqual(fixture.status, .waiting)
    }

    func testWaitingQueueErrorsExplainTheConditionWithoutBecomingPermanentFailures() throws {
        for (state, online, expectedCause) in [
            (BackupQueueItemState.waitingForAuthentication, false, "sign in"),
            (.waitingForNetwork, false, "network"),
            (.waitingForICloud, true, "icloud"),
            (.retryScheduled, true, "retry"),
        ] {
            let fixture = try fixture(queueState: state)
            XCTAssertNotNil(fixture.service.lastError, "Real waiting rows carry the last attempt's error")

            let message = fixture.status.explanation(backup: fixture.service,
                backgroundRefreshAvailable: true, isOnline: online, isExpensive: false).lowercased()

            XCTAssertEqual(fixture.status, .waiting)
            XCTAssertTrue(message.contains(expectedCause), "\(state) must explain its actual blocking condition")
            XCTAssertFalse(message.contains("remove them"), "A recoverable wait should not be presented as a permanent failure")
        }
    }

    func testSharedUploadsAffectStatusEvenWithAutomaticBackupOff() async throws {
        for (state, expected) in [(SharedUploadItemState.queued, BackupStatus.waiting),
                                  (.uploading, .uploading), (.failed, .failed)] {
            let fixture = try fixture(enabled: false)
            try await fixture.seedSharedUpload(state: state)

            await fixture.sharedUploads.refreshPending(session: fixture.session)

            XCTAssertEqual(fixture.sharedUploads.items.count, 1)
            XCTAssertEqual(fixture.sharedUploads.items.first?.item.state, state)
            XCTAssertEqual(fixture.status, expected)
        }
    }

    func testSharedOnlyWaitDoesNotClaimNativeCellularOrBackgroundRestrictions() async throws {
        let fixture = try fixture(photos: ["mapped"])
        try fixture.map("mapped")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)
        try await fixture.seedSharedUpload(state: .queued)
        await fixture.sharedUploads.refreshPending(session: fixture.session)

        let message = fixture.status.explanation(backup: fixture.service,
            backgroundRefreshAvailable: false, isOnline: true, isExpensive: true).lowercased()

        XCTAssertEqual(fixture.service.selectionStatus, .backedUp)
        XCTAssertTrue(fixture.service.uploadItems.isEmpty)
        XCTAssertEqual(fixture.status, .waiting)
        XCTAssertTrue(message.contains("shared uploads"))
        XCTAssertFalse(message.contains("wi-fi"))
        XCTAssertFalse(message.contains("background app refresh"))
    }

    func testAlbumOnlyWaitExplainsOrganizationRatherThanNativeUploadRestrictions() async throws {
        let fixture = try fixture(photos: ["mapped"], pendingAlbum: true)
        try fixture.map("mapped")
        await fixture.library.load()
        fixture.service.refreshCounts()

        let message = fixture.status.explanation(backup: fixture.service,
            backgroundRefreshAvailable: false, isOnline: true, isExpensive: true).lowercased()

        XCTAssertEqual(fixture.service.selectionStatus, .backedUp)
        XCTAssertTrue(fixture.service.uploadItems.isEmpty)
        XCTAssertEqual(fixture.status, .waiting)
        XCTAssertTrue(message.contains("album organization"))
        XCTAssertFalse(message.contains("wi-fi"))
        XCTAssertFalse(message.contains("background app refresh"))
    }

    func testNativeWaitingUploadsUseTheActualCellularPolicyForTheSuppliedNetwork() throws {
        let automatic = try fixture(queueState: .queued, queueIntent: nil)
        XCTAssertEqual(automatic.status, .waiting)
        XCTAssertFalse(automatic.service.allowsCellularUploads)
        let cheap = automatic.status.explanation(backup: automatic.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: false).lowercased()
        let expensive = automatic.status.explanation(backup: automatic.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: true).lowercased()

        XCTAssertTrue(cheap.contains("ready"))
        XCTAssertFalse(cheap.contains("wi-fi"))
        XCTAssertTrue(expensive.contains("wi-fi"))

        let manual = try fixture(queueState: .queued)
        XCTAssertEqual(manual.status, .waiting)
        XCTAssertTrue(manual.service.allowsCellularUploads)
        let manualExpensive = manual.status.explanation(backup: manual.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: true).lowercased()
        XCTAssertTrue(manualExpensive.contains("ready"))
        XCTAssertFalse(manualExpensive.contains("wi-fi"), "An explicitly requested upload allows cellular override")
    }

    func testStandaloneBackupErrorDoesNotAdvertiseAnAbsentUploadDetailsAction() async throws {
        let fixture = try fixture(photos: ["mapped"])
        try fixture.map("mapped")
        await fixture.library.load()
        fixture.service.refreshCounts()
        XCTAssertEqual(fixture.status, .synced)
        fixture.service.reportStorageCleanupFailure(CocoaError(.fileWriteOutOfSpace))

        let message = fixture.status.explanation(backup: fixture.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: false).lowercased()

        XCTAssertEqual(fixture.service.remainder, 0)
        XCTAssertTrue(fixture.service.uploadItems.isEmpty)
        XCTAssertEqual(fixture.status, .error)
        XCTAssertNotNil(fixture.service.lastError)
        XCTAssertTrue(message.contains("attention"))
        XCTAssertFalse(message.contains("view details"))
        XCTAssertFalse(message.contains("retry or remove"))
    }

    func testRemainingVideosWaitForWiFiUntilVideoCellularUploadsAreAllowed() async throws {
        for allowVideos in [false, true] {
            let fixture = try fixture(photos: ["video"], videoIDs: ["video"],
                cellularPhotos: true, cellularVideos: allowVideos)
            await fixture.library.load()
            fixture.service.refreshCounts()

            let message = fixture.status.explanation(backup: fixture.service,
                backgroundRefreshAvailable: true, isOnline: true, isExpensive: true).lowercased()

            XCTAssertEqual(fixture.service.selectionStatus, .remaining)
            XCTAssertEqual(fixture.service.remainder, 1)
            XCTAssertEqual(fixture.status, .waiting)
            XCTAssertEqual(fixture.service.allowsCellularUploads, allowVideos,
                "The photo preference cannot authorize the remaining video")
            XCTAssertEqual(message.contains("wi-fi"), !allowVideos)
            XCTAssertEqual(message.contains("ready"), allowVideos)
        }
    }

    func testRemainingPhotosWaitForWiFiUntilPhotoCellularUploadsAreAllowed() async throws {
        for allowPhotos in [false, true] {
            let fixture = try fixture(photos: ["photo"],
                cellularPhotos: allowPhotos, cellularVideos: true)
            await fixture.library.load()
            fixture.service.refreshCounts()

            let message = fixture.status.explanation(backup: fixture.service,
                backgroundRefreshAvailable: true, isOnline: true, isExpensive: true).lowercased()

            XCTAssertEqual(fixture.service.selectionStatus, .remaining)
            XCTAssertEqual(fixture.service.remainder, 1)
            XCTAssertEqual(fixture.status, .waiting)
            XCTAssertEqual(fixture.service.allowsCellularUploads, allowPhotos,
                "The video preference cannot authorize the remaining photo")
            XCTAssertEqual(message.contains("wi-fi"), !allowPhotos)
            XCTAssertEqual(message.contains("ready"), allowPhotos)
        }
    }

    func testDisabledExplanationDoesNotPromiseAutomaticUploadsForQueuedOrIdleStates() throws {
        for state in [BackupQueueItemState?.none, .some(.queued), .some(.preparing), .some(.failed)] {
            let fixture = try fixture(enabled: false, queueState: state)
            let message = fixture.status.explanation(backup: fixture.service,
                backgroundRefreshAvailable: false, isOnline: false, isExpensive: true).lowercased()

            XCTAssertTrue(message.contains("off"), "Disabled backup must be stated even when iOS or network limits also apply")
            XCTAssertTrue(message.contains("manual"), "The explanation must distinguish user-requested uploads")
            XCTAssertFalse(message.contains("are uploaded when you open the app"))
        }
    }

    func testEnabledExplanationsReflectVerifiedAndBlockedStates() async throws {
        let synced = try fixture(photos: ["mapped"])
        try synced.map("mapped")
        await synced.library.load()
        synced.service.refreshCounts()
        let complete = synced.status.explanation(backup: synced.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: false).lowercased()
        XCTAssertTrue(complete.contains("selected"))
        XCTAssertTrue(complete.contains("backed up"))
        XCTAssertEqual(synced.status.explanation(backup: synced.service,
            backgroundRefreshAvailable: false, isOnline: false, isExpensive: true).lowercased(), complete,
            "Completed backup does not need a connection or a future background wake")

        let unchecked = try fixture()
        let notScanned = unchecked.status.explanation(backup: unchecked.service,
            backgroundRefreshAvailable: true, isOnline: true, isExpensive: false).lowercased()
        XCTAssertFalse(notScanned.contains("everything"))
        XCTAssertFalse(notScanned.contains("is backed up"))
        XCTAssertNotEqual(notScanned, complete)

        let waiting = try fixture(photos: ["not-uploaded"])
        await waiting.library.load()
        waiting.service.refreshCounts()
        XCTAssertEqual(waiting.status, .waiting)
        let blocked = waiting.status.explanation(backup: waiting.service,
            backgroundRefreshAvailable: false, isOnline: true, isExpensive: false).lowercased()
        XCTAssertTrue(blocked.contains("background app refresh"))
        let offline = waiting.status.explanation(backup: waiting.service,
            backgroundRefreshAvailable: true, isOnline: false, isExpensive: false).lowercased()
        XCTAssertTrue(offline.contains("network"))
    }

    private func fixture(
        enabled: Bool = true, selection: Set<String> = ["selected"], photos: [String] = [],
        videoIDs: Set<String> = [], cellularPhotos: Bool = false, cellularVideos: Bool = false,
        queueState: BackupQueueItemState? = nil, queueIntent: BackupQueueIntent? = .manualUpload,
        pendingAlbum: Bool = false,
        scan: ((Set<String>) async -> LocalPhotoScan)? = nil
    ) throws -> BackupStatusFixture {
        UserDefaults.standard.set(enabled, forKey: "backup.enabled")
        UserDefaults.standard.set(cellularPhotos, forKey: "backup.cellularPhotos")
        UserDefaults.standard.set(cellularVideos, forKey: "backup.cellularVideos")
        let fixture = try BackupStatusFixture(selection: selection, photoIDs: photos, videoIDs: videoIDs,
            queueState: queueState, queueIntent: queueIntent, pendingAlbum: pendingAlbum, scan: scan)
        fixtures.append(fixture)
        return fixture
    }
}

@MainActor
private final class BackupStatusFixture {
    let directory: URL
    let suiteName: String
    let queue: BackupQueueStore
    let library: LocalPhotoLibrary
    let access: BackupStatusAccess
    let sharedStore: SharedUploadStore
    let sharedUploads: SharedUploadService
    private var retainedSession: BackupStatusSession?
    private var retainedManager: SwiftDataManager?
    private var retainedService: BackupService?
    var manager: SwiftDataManager { retainedManager! }
    var service: BackupService { retainedService! }
    var session: BackupStatusSession { retainedSession! }
    var status: BackupStatus { BackupStatus(backup: service, sharedUploads: sharedUploads) }

    init(selection: Set<String>, photoIDs: [String], videoIDs: Set<String>,
         queueState: BackupQueueItemState?, queueIntent: BackupQueueIntent?,
         pendingAlbum: Bool, scan: ((Set<String>) async -> LocalPhotoScan)?) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-status-\(UUID())")
        suiteName = "BackupStatusReportingTests.\(UUID())"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        retainedManager = manager
        let queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        self.queue = queue
        let owner = BackupQueueOwner(server: "https://backup-status.example/api", userID: "status-owner")
        try queue.bind(to: owner)
        if let queueState {
            try queue.enqueue(["manual-photo"], intent: queueIntent)
            switch queueState {
            case .queued: break
            case .preparing: try queue.markPreparing("manual-photo", phase: .primaryAsset)
            case .uploading:
                try queue.markPreparing("manual-photo", phase: .primaryAsset)
                try queue.markUploading("manual-photo", phase: .primaryAsset, checksum: "sha", taskIdentifier: 42)
            case .failed: try queue.markFailed("manual-photo", error: "Upload rejected")
            default:
                try queue.markRetry("manual-photo", state: queueState, error: "Waiting for \(queueState)", retryAt: .distantFuture)
            }
        }
        if pendingAlbum {
            try queue.recordAlbumPlacement(.init(localIdentifier: "mapped", assetID: "server-mapped", albumName: "Selected Album"))
        }
        let access = BackupStatusAccess(photoIDs: photoIDs)
        access.videoIDs = videoIDs
        self.access = access
        library = LocalPhotoLibrary(defaults: UserDefaults(suiteName: suiteName)!, reader: .init(
            authorizationStatus: { access.authorization },
            requestAuthorization: { access.permissionRequests += 1; return access.authorization },
            photosInAlbums: { ids in
                access.reads += 1
                if let scan { return await scan(ids) }
                return access.result()
            }))
        library.selectedAlbumIDs = selection
        sharedStore = SharedUploadStore(rootURL: directory.appendingPathComponent("shared", isDirectory: true))
        sharedUploads = SharedUploadService(store: sharedStore, upload: { _, _, _, _ in
            XCTFail("Status inspection must not initiate shared uploads")
        })
        retainedSession = try BackupStatusSession(manager: manager, owner: owner)
        retainedService = BackupService(dataManager: manager, queue: queue, localLibrary: library)
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }

    func map(_ id: String) throws {
        try manager.upsertBackupRecord(assetID: "server-\(id)", checksum: "sha-\(id)", localIdentifier: id)
    }

    func seedSharedUpload(state: SharedUploadItemState) async throws {
        let owner = SharedUploadOwner(server: "https://backup-status.example/api", userID: "status-owner")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let batch = SharedUploadBatch(id: UUID(), owner: owner, createdAt: date, items: [
            .init(id: UUID(), filename: "shared.jpg", relativePath: "shared.jpg", contentType: "image/jpeg",
                byteCount: 4, createdAt: date, modifiedAt: date, state: state,
                lastError: state == .failed ? "Shared upload rejected" : nil)
        ])
        let directory = try await sharedStore.makeBatchDirectory(id: batch.id)
        try Data("file".utf8).write(to: directory.appendingPathComponent("shared.jpg"))
        try await sharedStore.save(batch)
    }

    func close() {
        sharedUploads.cancel()
        retainedService?.resetForLogout()
        retainedService = nil
        retainedSession = nil
        retainedManager = nil
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class BackupStatusSession: SessionManager {
    private let owner: BackupQueueOwner
    override var backupQueueOwner: BackupQueueOwner? { owner }
    override var authHeaders: [String: String] { ["Authorization": "Bearer status-test"] }

    init(manager: SwiftDataManager, owner: BackupQueueOwner) throws {
        self.owner = owner
        super.init(dataManager: manager, restoresSession: false)
        try setServer("https://backup-status.example")
        isLoggedIn = true
    }
}

@MainActor
private final class BackupStatusAccess {
    var authorization = PHAuthorizationStatus.authorized
    var photoIDs: [String]
    var videoIDs: Set<String> = []
    var reads = 0
    var permissionRequests = 0

    init(photoIDs: [String]) { self.photoIDs = photoIDs }

    func result() -> LocalPhotoScan {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(photos: photoIDs.map {
            LocalPhoto(id: $0, createdAt: date, modifiedAt: date,
                isVideo: videoIDs.contains($0), isLivePhoto: false, duration: nil, ratio: 1)
        }, albumTitles: Dictionary(uniqueKeysWithValues: photoIDs.map { ($0, "Selected Album") }))
    }
}

@MainActor
private final class BackupStatusScanGate {
    let started = XCTestExpectation(description: "Selection scan is held before publishing")
    private var continuation: CheckedContinuation<LocalPhotoScan, Never>?
    private var released = false

    func value() async -> LocalPhotoScan {
        if released { return .init(photos: [], albumTitles: [:]) }
        return await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func release() {
        released = true
        continuation?.resume(returning: .init(photos: [], albumTitles: [:]))
        continuation = nil
    }
}
