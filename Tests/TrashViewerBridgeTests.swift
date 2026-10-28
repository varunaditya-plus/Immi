import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class TrashViewerBridgeTests: XCTestCase {
    private var fixtures: [Fixture] = []

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for fixture in fixtures {
            LocalSnapshot.remove(fixture.snapshotKey)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
    }

    func testTrashDestinationRestoresThroughTheGridAndCommitsBothSnapshots() async throws {
        let fixture = try makeFixture()
        let photos = [photo(), photo()]
        fixture.markTrashed(photos)
        let model = fixture.model(photos)
        await model.load()
        let actions = try actions(from: fixture.screen(model), for: photos[0].id)
        let viewer = AssetViewerState(currentAsset: photos[0], assets: photos)
        fixture.respond(204)
        var presentations: [Bool] = []

        let task = try XCTUnwrap(actions.perform(.restore,
            target: viewer.target(serverID: photos[0].id, detail: nil), in: viewer,
            onError: { XCTFail($0) }, completion: { presentations.append($0) }))
        await task.value

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/trash/restore/assets")
        XCTAssertEqual(try requestBody()["ids"] as? [String], [photos[0].id])
        XCTAssertEqual(model.assets.map(\.id), [photos[1].id])
        XCTAssertEqual(viewer.pages.map(\.id), [photos[1].id])
        XCTAssertEqual(presentations, [true])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.map(\.id), [photos[1].id])
        XCTAssertNotNil(fixture.reopen().getCachedAsset(id: photos[0].id))
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(photos[0].id))
        XCTAssertTrue(RemovedAssets.shared.contains(photos[0].id, scope: .trash),
            "A second retained Trash grid must stop offering permanent deletion of the restored photo")
        XCTAssertNil(fixture.screen(model).detailView(for: photos[0].id))
    }

    func testTrashDestinationPermanentlyDeletesAndRemovesItsLastPage() async throws {
        let fixture = try makeFixture()
        let asset = photo()
        fixture.markTrashed([asset])
        let model = fixture.model([asset])
        await model.load()
        let actions = try actions(from: fixture.screen(model), for: asset.id)
        let viewer = AssetViewerState(currentAsset: asset, assets: [asset])
        fixture.respond(204)
        var presentations: [Bool] = []

        let task = try XCTUnwrap(actions.perform(.deletePermanently,
            target: viewer.target(serverID: asset.id, detail: nil), in: viewer,
            onError: { XCTFail($0) }, completion: { presentations.append($0) }))
        await task.value

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets")
        XCTAssertEqual(try requestBody()["ids"] as? [String], [asset.id])
        XCTAssertEqual(try requestBody()["force"] as? Bool, true)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertTrue(viewer.isEmpty)
        XCTAssertEqual(presentations, [true])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.count, 0)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted(asset.id))
        XCTAssertTrue(RemovedAssets.shared.filter([asset], scope: .trash).isEmpty)
        XCTAssertNil(fixture.reopen().getCachedAsset(id: asset.id))
    }

    func testFailedViewerActionsKeepThePhotoAndShowOneModalErrorBeforeRetry() async throws {
        for mutation in [TrashViewerActions.Mutation.restore, .deletePermanently] {
            let fixture = try makeFixture()
            let asset = photo()
            fixture.markTrashed([asset])
            let model = fixture.model([asset])
            await model.load()
            let actions = try actions(from: fixture.screen(model), for: asset.id)
            let viewer = AssetViewerState(currentAsset: asset, assets: [asset])
            var errors: [String] = []
            var presentations: [Bool] = []
            fixture.respond(500)
            let failed = try XCTUnwrap(actions.perform(mutation,
                target: viewer.target(serverID: asset.id, detail: nil), in: viewer,
                onError: { errors.append($0) }, completion: { presentations.append($0) }))
            await failed.value

            XCTAssertEqual(errors, ["Viewer mutation rejected"])
            XCTAssertNil(model.actionError, "The covered collection must not also present an alert")
            XCTAssertEqual(model.assets.map(\.id), [asset.id])
            XCTAssertEqual(viewer.pages.map(\.id), [asset.id])
            XCTAssertTrue(presentations.isEmpty)
            XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.map(\.id), [asset.id])
            XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(asset.id))
            XCTAssertNil(fixture.reopen().getCachedAsset(id: asset.id))

            fixture.respond(204)
            let retry = try XCTUnwrap(actions.perform(mutation,
                target: viewer.target(serverID: asset.id, detail: nil), in: viewer,
                onError: { errors.append($0) }, completion: { presentations.append($0) }))
            await retry.value
            XCTAssertTrue(model.assets.isEmpty)
            XCTAssertTrue(viewer.isEmpty)
            XCTAssertEqual(presentations, [true])
            XCTAssertEqual(errors, ["Viewer mutation rejected"])
            XCTAssertNil(model.actionError)
        }
    }

    func testOrdinaryCollectionsKeepTheirViewerAndUnavailableTrashRowsHaveNoDestination() async throws {
        let fixture = try makeFixture()
        let assets = [photo(), photo()]
        let model = fixture.model(assets)
        await model.load()
        let ordinary = PhotoCollectionScreen(title: "Favorites", assets: assets, phase: .loaded(()),
            onRetry: {}, onToggleFavorite: { _ in }, onDelete: { _ in }, shareURLs: { _ in [] })
        XCTAssertNil(try XCTUnwrap(ordinary.detailView(for: assets[0].id)).trashActions)

        RemovedAssets.shared.remove([assets[0].id], reason: .unavailable)
        let trash = fixture.screen(model)
        XCTAssertNil(trash.detailView(for: assets[0].id))
        XCTAssertNotNil(trash.detailView(for: assets[1].id)?.trashActions)
        XCTAssertNil(trash.detailView(for: "missing"))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    private func actions<Options: View>(from screen: PhotoCollectionScreen<Options>, for id: String) throws -> TrashViewerActions {
        try XCTUnwrap(try XCTUnwrap(screen.detailView(for: id)).trashActions)
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1.5, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000), isFavorite: true)
    }

    private func requestBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastRequest?.httpBody ?? MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        fixtures.append(fixture)
        return fixture
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let snapshotKey = "trash-viewer-bridge-\(UUID())"
        let manager: SwiftDataManager
        let api: APIClient
        let trash: TrashRepository

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("trash-viewer-bridge-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            let session = MockSessionManager()
            try session.setServer("https://trash-viewer-bridge.example")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
            trash = TrashRepository(api: api, dataManager: manager)
        }

        func markTrashed(_ assets: [AssetLite]) {
            let ids = assets.map(\.id)
            RemovedAssets.shared.remove(ids, reason: .trashed)
            DeletedServerAssetRegistry.shared.record(ids, permanently: false)
        }

        func model(_ assets: [AssetLite]) -> AssetGridViewModel {
            AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: manager),
                albumRepo: AlbumRepository(api: api), snapshotKey: snapshotKey, dataManager: manager,
                loader: { assets })
        }

        func screen(_ model: AssetGridViewModel) -> PhotoCollectionScreen<some View> {
            TrashView().collectionScreen(using: model, repository: trash)
        }

        func respond(_ status: Int) {
            MockURLProtocol.responseProvider = { request in
                let data = status >= 400 ? Data(#"{"message":"Viewer mutation rejected"}"#.utf8) : Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
            }
        }

        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }
    }
}
