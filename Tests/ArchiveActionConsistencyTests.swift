import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class ArchiveActionConsistencyTests: XCTestCase {
    private var fixtures: [Fixture] = []
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    override func setUp() async throws {
        MockURLProtocol.reset()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        let cleanup = fixtures.map { ($0.directory, $0.snapshotKey) }
        fixtures.removeAll()
        for (directory, key) in cleanup {
            LocalSnapshot.remove(key)
            try? FileManager.default.removeItem(at: directory)
        }
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        MockURLProtocol.reset()
    }

    func testCollectionLabelsAndWireMutationAgreeForArchiveAndUnarchive() async throws {
        for archived in [true, false] {
            let fixture = try fixture(archived: archived)
            let model = fixture.model()
            await model.load()
            let screen = collection(archived: archived).collectionScreen(using: model)
            let expected = archived ? "Unarchive" : "Archive"

            XCTAssertTrue(screen.menuActions(for: fixture.photo.id).contains { $0.title == expected })
            XCTAssertFalse(screen.menuActions(for: fixture.photo.id).contains {
                $0.title == (archived ? "Archive" : "Unarchive")
            })
            XCTAssertEqual(screen.selectionActions(for: [fixture.photo.id]).archiveTitle, expected)
            let action = try XCTUnwrap(screen.onArchiveSelection)
            fixture.respond(204)

            await action([fixture.photo.id])

            XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
            XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(fixture.photo.id)")
            XCTAssertEqual(try requestBody()["visibility"] as? String, archived ? "timeline" : "archive")
            XCTAssertTrue(model.assets.isEmpty)
            XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.count, 0)
            XCTAssertEqual(fixture.reopen().getCachedAsset(id: fixture.photo.id)?.isArchived, !archived)
            XCTAssertEqual(fixture.reopen().archivedAssetIDs.contains(fixture.photo.id), !archived)
        }
    }

    func testFailedUnarchiveRetainsThePhotoAndItsPersistedVisibility() async throws {
        let fixture = try fixture(archived: true)
        let model = fixture.model()
        await model.load()
        let screen = collection(archived: true).collectionScreen(using: model)
        fixture.respond(500)

        await screen.onArchiveSelection?([fixture.photo.id])

        XCTAssertEqual(model.assets.map(\.id), [fixture.photo.id])
        XCTAssertEqual(model.actionError, "Visibility update rejected")
        XCTAssertEqual(fixture.reopen().getCachedAsset(id: fixture.photo.id)?.isArchived, true)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey)?.map(\.id), [fixture.photo.id])
        XCTAssertTrue(screen.menuActions(for: fixture.photo.id).contains { $0.title == "Unarchive" })
    }

    func testLockedFolderAndTrashDoNotOfferAnArchiveAction() async throws {
        let fixture = try fixture(archived: false)
        let model = fixture.model()
        await model.load()
        let locked = AssetCollectionView(title: "Locked Folder", request: SearchRequestDTO(visibility: "locked"))
            .collectionScreen(using: model)
        XCTAssertNil(locked.onArchiveSelection)
        XCTAssertNil(locked.selectionActions(for: [fixture.photo.id]).archive)
        XCTAssertFalse(locked.menuActions(for: fixture.photo.id).contains { ["Archive", "Unarchive"].contains($0.title) })
        let trash = TrashView().collectionScreen(using: model,
            repository: TrashRepository(api: fixture.api, dataManager: fixture.manager))
        XCTAssertNil(trash.onArchiveSelection)
        XCTAssertNil(trash.selectionActions(for: [fixture.photo.id]).archive)
        XCTAssertFalse(trash.menuActions(for: fixture.photo.id).contains { ["Archive", "Unarchive"].contains($0.title) })
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testViewerArchiveDestinationUsesMatchingMetadataAndCurrentClassification() throws {
        let fixture = try fixture(archived: true)
        var detail = makeTestAsset(id: fixture.photo.id, isArchived: true)
        detail.visibility = "archive"
        XCTAssertEqual(AssetDetailView.archiveDestination(for: fixture.photo.id, detail: detail,
            dataManager: fixture.manager), .timeline)
        detail.visibility = nil
        XCTAssertEqual(AssetDetailView.archiveDestination(for: fixture.photo.id, detail: detail,
            dataManager: fixture.manager), .timeline, "Legacy archived metadata must also offer Unarchive")
        XCTAssertEqual(AssetDetailView.archiveDestination(for: "other", detail: detail,
            dataManager: fixture.manager), .archive, "Another page's metadata cannot choose the current action")
        let uncachedID = UUID().uuidString
        var uncachedDetail = makeTestAsset(id: uncachedID, isArchived: true)
        uncachedDetail.visibility = "archive"
        XCTAssertEqual(AssetDetailView.archiveDestination(for: uncachedID, detail: uncachedDetail,
            dataManager: fixture.manager), .timeline, "Matching detail supplies archive state when no cache row exists")
        uncachedDetail.visibility = nil
        XCTAssertEqual(AssetDetailView.archiveDestination(for: uncachedID, detail: uncachedDetail,
            dataManager: fixture.manager), .timeline, "Uncached legacy metadata still supplies archive state")
        try fixture.manager.setAssetVisibility([fixture.photo.id], to: "archive")
        XCTAssertEqual(AssetDetailView.archiveDestination(for: fixture.photo.id, detail: nil,
            dataManager: fixture.manager), .timeline, "The offline viewer retains known archive state")
        try fixture.manager.setAssetVisibility([fixture.photo.id], to: "locked")
        XCTAssertEqual(AssetDetailView.archiveDestination(for: fixture.photo.id, detail: detail,
            dataManager: fixture.manager), .archive, "Old archived metadata cannot offer Unarchive for a now-private photo")
    }

    func testViewerOffersArchiveAfterAnotherWindowUnarchivesItsRetainedDetail() throws {
        for cached in [false, true] {
            for legacy in [false, true] {
                let fixture = try fixture(archived: true)
                let id = cached ? fixture.photo.id : UUID().uuidString
                if !cached { try fixture.manager.setAssetVisibility([id], to: "archive") }
                var retainedDetail = makeTestAsset(id: id, isArchived: true)
                retainedDetail.visibility = legacy ? nil : "archive"
                XCTAssertEqual(AssetDetailView.archiveDestination(for: id, detail: retainedDetail,
                    dataManager: fixture.manager), .timeline)

                try fixture.manager.setAssetVisibility([id], to: "timeline")

                if cached { XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isArchived, false) }
                else { XCTAssertNil(fixture.manager.getCachedAsset(id: id)) }
                XCTAssertFalse(fixture.manager.archivedAssetIDs.contains(id))
                XCTAssertTrue(fixture.manager.explicitTimelineAssetIDs.contains(id))
                XCTAssertEqual(AssetDetailView.archiveDestination(for: id, detail: retainedDetail,
                    dataManager: fixture.manager), .archive,
                    "The current timeline command must replace retained archive metadata even without a cached row")
            }
        }
    }

    func testExplicitTimelineEvidenceSurvivesCacheResetButNotNewCommandsOrAccountClear() throws {
        let fixture = try fixture(archived: false)
        let manager = fixture.manager
        let id = UUID().uuidString
        let networkID = UUID().uuidString
        let syncedID = UUID().uuidString
        var networkDetail = makeTestAsset(id: networkID)
        networkDetail.visibility = "timeline"
        try manager.recordServerVisibility([networkDetail])
        try manager.applySyncBatch(upserts: [CachedAsset(id: syncedID, assetId: syncedID, type: "IMAGE")],
            deletedIds: [], visibilityByID: [syncedID: "timeline"])
        XCTAssertTrue(manager.explicitTimelineAssetIDs.isEmpty,
            "Network metadata and sync must not grow the explicit-action evidence")

        try manager.setAssetVisibility([id], to: "timeline")
        XCTAssertEqual(manager.explicitTimelineAssetIDs, [id])
        try manager.resetSyncDatabase()
        XCTAssertEqual(manager.cachedAssetCount(), 0)
        XCTAssertEqual(manager.explicitTimelineAssetIDs, [id], "Clearing rebuildable data must retain the accepted command")
        XCTAssertTrue(fixture.reopen().explicitTimelineAssetIDs.isEmpty, "The evidence is transient rather than a new persisted index")

        try manager.setAssetVisibility([id], to: "archive")
        XCTAssertTrue(manager.explicitTimelineAssetIDs.isEmpty)
        try manager.setAssetVisibility([id], to: "timeline")
        try manager.setAssetVisibility([id], to: "locked")
        XCTAssertTrue(manager.explicitTimelineAssetIDs.isEmpty)
        try manager.setAssetVisibility([id], to: "timeline")

        var laterDetail = makeTestAsset(id: id, isArchived: true)
        laterDetail.visibility = "archive"
        try manager.recordServerVisibility([laterDetail])
        XCTAssertEqual(manager.explicitTimelineAssetIDs, [id])
        XCTAssertEqual(AssetDetailView.archiveDestination(for: id, detail: nil, dataManager: manager), .timeline,
            "Current canonical archive classification must precede older explicit timeline evidence")
        laterDetail.visibility = "locked"
        try manager.recordServerVisibility([laterDetail])
        XCTAssertEqual(AssetDetailView.archiveDestination(for: id, detail: laterDetail, dataManager: manager), .archive,
            "Current private classification must precede older explicit timeline evidence")

        try manager.clearAllAccountData()
        XCTAssertTrue(manager.explicitTimelineAssetIDs.isEmpty)
    }

    func testRenderedSelectionToolbarUsesTheUnarchiveAccessibilityLabel() async throws {
        let fixture = try fixture(archived: true)
        let model = fixture.model()
        await model.load()
        let actions = collection(archived: true).collectionScreen(using: model)
            .selectionActions(for: [fixture.photo.id])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack {
            Text("Archived").toolbar { SelectionToolbar(actions: actions) }
                .toolbar(.visible, for: .bottomBar)
        }.environment(\.locale, Locale(identifier: "en_US")))
        let testWindow = UIWindow(windowScene: scene)
        testWindow.rootViewController = host
        testWindow.makeKeyAndVisible()
        window = testWindow
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let containsLabel = {
                self.barButtonItems(in: host).contains {
                    $0.title == "Unarchive" || $0.accessibilityLabel == "Unarchive"
                } || self.accessibilityLabels(in: testWindow).contains("Unarchive")
            }
            if Thread.isMainThread { return MainActor.assumeIsolated { containsLabel() } }
            return DispatchQueue.main.sync { containsLabel() }
        }, object: nil)
        await fulfillment(of: [rendered], timeout: 3)

        let labels = accessibilityLabels(in: testWindow) + barButtonItems(in: host).flatMap {
            [$0.title, $0.accessibilityLabel].compactMap { $0 }
        }
        XCTAssertTrue(labels.contains("Unarchive"), "The rendered archive control must describe its inverse action: \(labels)")
    }

    private func accessibilityLabels(in view: UIView) -> [String] {
        if view.isAccessibilityElement, let label = view.accessibilityLabel { return [label] }
        return view.subviews.flatMap { accessibilityLabels(in: $0) }
    }

    private func barButtonItems(in controller: UIViewController) -> [UIBarButtonItem] {
        let item = controller.navigationItem
        let groups = item.leadingItemGroups + item.centerItemGroups + item.trailingItemGroups
        return (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? []) + groups.flatMap(\.barButtonItems)
            + controller.children.flatMap { barButtonItems(in: $0) }
    }

    private func collection(archived: Bool) -> AssetCollectionView {
        AssetCollectionView(title: archived ? "Archived" : "Favorites",
            request: SearchRequestDTO(visibility: archived ? "archive" : "timeline"))
    }

    private func fixture(archived: Bool) throws -> Fixture {
        let fixture = try Fixture(archived: archived)
        fixtures.append(fixture)
        return fixture
    }

    private func requestBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastRequest?.httpBody ?? MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let snapshotKey = "archive-action-\(UUID())"
        let photo = AssetLite(makeTestAsset(id: UUID().uuidString))
        let manager: SwiftDataManager
        let transport: URLSession
        let api: APIClient

        init(archived: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-action-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
            try manager.restoreToTimeline([photo])
            if archived { try manager.setAssetVisibility([photo.id], to: "archive") }
            let session = MockSessionManager()
            try session.setServer("https://archive-action.example")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            transport = URLSession(configuration: configuration)
            api = APIClient(session: session, urlSession: transport)
        }

        func model() -> AssetGridViewModel {
            let photo = photo
            return AssetGridViewModel(assetRepo: AssetDetailRepository(api: api, dataManager: manager),
                albumRepo: AlbumRepository(api: api), snapshotKey: snapshotKey, dataManager: manager,
                loader: { [photo] })
        }

        func respond(_ status: Int) {
            MockURLProtocol.responseProvider = { request in
                let data = status >= 400 ? Data(#"{"message":"Visibility update rejected"}"#.utf8) : Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
            }
        }

        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("backup.json"))
        }
    }
}
