import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class TrashCacheConsistencyTests: XCTestCase {
    private var cleanup: [(directory: URL, snapshotKey: String)] = []
    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for item in cleanup {
            LocalSnapshot.remove(item.snapshotKey)
            try? FileManager.default.removeItem(at: item.directory)
        }
        cleanup.removeAll()
    }

    func testTrashIncludesSoftDeletedPhotosButExcludesUnavailablePhotos() async {
        let removed = RemovedAssets()
        let assets = [asset("trashed"), asset("unavailable"), asset("untouched")]
        removed.remove(["trashed"], reason: .trashed)
        removed.remove(["unavailable"])

        XCTAssertEqual(removed.filter(assets).map(\.id), ["untouched"])
        XCTAssertEqual(removed.filter(assets, scope: .trash).map(\.id), ["trashed", "untouched"])

        let changed = expectation(description: "Permanent removal updates the Trash filter even though IDs stay the same")
        withObservationTracking {
            _ = removed.filter(assets, scope: .trash)
        } onChange: { changed.fulfill() }
        removed.remove(["trashed"])

        XCTAssertEqual(removed.filter(assets, scope: .trash).map(\.id), ["untouched"])
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(removed.ids.contains("trashed"))
    }

    func testCollectionDeleteUpdatesCacheAndKeepsThePhotoEligibleForTrash() async throws {
        let fixture = try makeFixture()
        let photo = asset("deleted")
        try fixture.manager.restoreToTimeline([photo])
        let model = fixture.model([photo])
        await model.load()
        fixture.respond(204)

        await model.delete([photo.id])

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets")
        let body = try requestBody()
        XCTAssertEqual(body["ids"] as? [String], [photo.id])
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertTrue(RemovedAssets.shared.filter([photo]).isEmpty)
        XCTAssertEqual(RemovedAssets.shared.filter([photo], scope: .trash).map(\.id), [photo.id])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.count, 0)
    }

    func testPermanentDeleteAlsoRemovesThePhotoFromOtherTrashSnapshots() async throws {
        let fixture = try makeFixture()
        let photo = asset("permanent")
        RemovedAssets.shared.remove([photo.id], reason: .trashed)
        let model = fixture.model([photo])
        await model.load()
        fixture.respond(204)

        await model.delete([photo.id], permanently: true)

        XCTAssertEqual(try requestBody()["force"] as? Bool, true)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertTrue(RemovedAssets.shared.filter([photo], scope: .trash).isEmpty)
    }

    func testRestoreSelectionReturnsCommittedMetadataToTimelineAndReleasesLibraryFilters() async throws {
        let fixture = try makeFixture()
        let first = asset("restored"), second = asset("still-trashed")
        RemovedAssets.shared.remove([first.id, second.id], reason: .trashed)
        DeletedServerAssetRegistry.shared.record([first.id, second.id], permanently: false)
        let model = fixture.model([first, second])
        await model.load()
        fixture.respond(204)

        await model.restore([first.id], using: fixture.trash)

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/trash/restore/assets")
        XCTAssertEqual(try requestBody()["ids"] as? [String], [first.id])
        XCTAssertEqual(model.assets.map(\.id), [second.id])
        XCTAssertEqual(RemovedAssets.shared.filter([first, second]).map(\.id), [first.id])
        let stored = try XCTUnwrap(fixture.reopen().getCachedAsset(id: first.id))
        XCTAssertEqual(stored.createdAt, first.createdAt)
        XCTAssertEqual(stored.ratio, first.ratio)
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.livePhotoVideoId, first.livePhotoVideoID)
        XCTAssertFalse(stored.isArchived)
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(first.id))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.contains(second.id))
    }

    func testRestoreAllRepopulatesTimelineWithoutReleasingUnavailableAssets() async throws {
        let fixture = try makeFixture()
        let first = asset("first"), second = asset("second"), unavailable = asset("unavailable")
        RemovedAssets.shared.remove([first.id, second.id], reason: .trashed)
        RemovedAssets.shared.remove([unavailable.id])
        DeletedServerAssetRegistry.shared.record([unavailable.id], permanently: true)
        let model = fixture.model([first, second, unavailable])
        await model.load()
        fixture.respond(204)

        await model.restoreAll(using: fixture.trash)

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/trash/restore")
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertEqual(Set(fixture.reopen().timelineAssets().map(\.asset.id)), [first.id, second.id])
        XCTAssertEqual(RemovedAssets.shared.filter([first, second, unavailable]).map(\.id), [first.id, second.id])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.count, 0)
    }

    func testStaleSelectionCannotRestoreAnUnavailableOrPermanentlyDeletedPhoto() async throws {
        let fixture = try makeFixture()
        let unavailable = asset("unavailable-selection"), permanent = asset("permanent-selection")
        RemovedAssets.shared.remove([unavailable.id])
        DeletedServerAssetRegistry.shared.record([permanent.id], permanently: true)
        let model = fixture.model([unavailable, permanent])
        await model.load()
        MockURLProtocol.responseProvider = { request in
            XCTFail("A stale hidden selection must not issue a restore request: \(request)")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil), nil)
        }

        await model.restore([unavailable.id, permanent.id], using: fixture.trash)

        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty)
        XCTAssertTrue(RemovedAssets.shared.filter([unavailable]).isEmpty)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted(permanent.id))
    }

    func testEmptyTrashConvertsSoftRemovalToUnavailableAcrossSnapshots() async throws {
        let fixture = try makeFixture()
        let visible = asset("visible"), otherSnapshot = asset("other-snapshot")
        RemovedAssets.shared.remove([visible.id, otherSnapshot.id], reason: .trashed)
        let model = fixture.model([visible])
        await model.load()
        fixture.respond(204)

        await model.emptyTrash(using: fixture.trash)

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/trash/empty")
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertTrue(RemovedAssets.shared.filter([visible, otherSnapshot], scope: .trash).isEmpty)
        XCTAssertTrue(RemovedAssets.shared.filter([visible, otherSnapshot]).isEmpty)
    }

    func testPendingRestoreCannotReinsertAPhotoPermanentlyDeletedDuringTheRequest() async throws {
        for all in [false, true] {
            let fixture = try makeFixture()
            let photo = asset("deleted-during-restore-\(all)")
            RemovedAssets.shared.remove([photo.id], reason: .trashed)
            DeletedServerAssetRegistry.shared.record([photo.id], permanently: false)
            let model = fixture.model([photo])
            await model.load()
            let started = expectation(description: "Restore is waiting for its HTTP response")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            MockURLProtocol.responseProvider = { request in
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    XCTFail("The test must release its held HTTP response")
                    return (nil, nil, URLError(.timedOut))
                }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil), nil)
            }
            let pending = Task {
                if all { await model.restoreAll(using: fixture.trash) }
                else { await model.restore([photo.id], using: fixture.trash) }
            }
            await fulfillment(of: [started], timeout: 2)
            RemovedAssets.shared.remove([photo.id])
            DeletedServerAssetRegistry.shared.record([photo.id], permanently: true)
            release.signal()
            await pending.value

            XCTAssertTrue(model.assets.isEmpty)
            XCTAssertNil(fixture.reopen().getCachedAsset(id: photo.id))
            XCTAssertTrue(RemovedAssets.shared.filter([photo]).isEmpty)
            XCTAssertTrue(RemovedAssets.shared.filter([photo], scope: .trash).isEmpty)
            XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted(photo.id))
        }
    }

    func testFailedTrashActionsKeepSnapshotsFiltersAndPersistentCacheUnchanged() async throws {
        let fixture = try makeFixture()
        let photo = asset("failed")
        RemovedAssets.shared.remove([photo.id], reason: .trashed)
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: false)
        let model = fixture.model([photo])
        await model.load()
        let revision = fixture.manager.assetMutationRevision
        fixture.respond(500)

        await model.restore([photo.id], using: fixture.trash)
        await model.restoreAll(using: fixture.trash)
        await model.emptyTrash(using: fixture.trash)
        await model.delete([photo.id], permanently: true)

        XCTAssertEqual(model.assets.map(\.id), [photo.id])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.map(\.id), [photo.id])
        XCTAssertTrue(RemovedAssets.shared.filter([photo]).isEmpty)
        XCTAssertEqual(RemovedAssets.shared.filter([photo], scope: .trash).map(\.id), [photo.id])
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(photo.id))
        XCTAssertNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertEqual(fixture.manager.assetMutationRevision, revision)
        guard case .failed = model.phase else { return XCTFail("The failed action must still report its failure") }
    }

    func testSyncBatchesPublishRemovalReasonsAndReleaseRestoredAssetsAfterCommit() throws {
        let fixture = try makeFixture()
        let photo = asset("synced")
        try fixture.manager.restoreToTimeline([photo])
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: false)

        try fixture.manager.applySyncBatch(upserts: [], deletedIds: [photo.id])

        XCTAssertNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertTrue(RemovedAssets.shared.filter([photo]).isEmpty)
        XCTAssertEqual(RemovedAssets.shared.filter([photo], scope: .trash).map(\.id), [photo.id])
        DeletedServerAssetRegistry.shared.restore([photo.id])
        let restored = CachedAsset(id: photo.id, assetId: photo.id, type: "IMAGE", createdAt: photo.createdAt)
        try fixture.manager.applySyncBatch(upserts: [restored], deletedIds: [])

        XCTAssertNotNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertEqual(RemovedAssets.shared.filter([photo]).map(\.id), [photo.id])
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: true)
        try fixture.manager.applySyncBatch(upserts: [], deletedIds: [photo.id])
        XCTAssertTrue(RemovedAssets.shared.filter([photo], scope: .trash).isEmpty)
    }

    private func asset(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1.5, thumbhash: "hash", createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            isFavorite: true, livePhotoVideoID: "live-\(id)")
    }

    private func requestBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastRequest?.httpBody ?? MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        cleanup.append((fixture.directory, fixture.snapshotKey))
        return fixture
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let snapshotKey = "trash-cache-\(UUID())"
        let manager: SwiftDataManager
        let api: APIClient
        let assetRepo: AssetDetailRepository
        let trash: TrashRepository

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("trash-cache-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            self.manager = manager
            let session = MockSessionManager()
            try session.setServer("https://trash-cache.example")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
            assetRepo = AssetDetailRepository(api: api, dataManager: manager)
            trash = TrashRepository(api: api)
        }

        func model(_ assets: [AssetLite]) -> AssetGridViewModel {
            AssetGridViewModel(assetRepo: assetRepo, albumRepo: AlbumRepository(api: api),
                snapshotKey: snapshotKey, dataManager: manager, loader: { assets })
        }

        func respond(_ status: Int) {
            MockURLProtocol.responseProvider = { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
            }
        }

        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }

    }
}
