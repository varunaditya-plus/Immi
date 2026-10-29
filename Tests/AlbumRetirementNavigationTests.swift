import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumRetirementNavigationTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var snapshotKeys: [String] = []
    private var previousParentSnapshot: [AlbumResponseDTO]?

    override func setUp() async throws {
        try await super.setUp()
        previousParentSnapshot = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        snapshotKeys.removeAll()
        if let previousParentSnapshot {
            LocalSnapshot.save(previousParentSnapshot, for: LocalSnapshot.Key.albumsList)
        } else { LocalSnapshot.remove(LocalSnapshot.Key.albumsList) }
        previousParentSnapshot = nil
        try await super.tearDown()
    }

    func testAnotherWindowsDeletionRetiresAndDismissesTheVisibleAlbumExactlyOnce() async throws {
        let fixture = try await showAlbum()
        XCTAssertTrue(fixture.route.shown)
        XCTAssertNotNil(gridController(in: fixture.host))
        XCTAssertNotNil(LocalSnapshot.load([AssetLite].self, for: fixture.key))

        LocalSnapshot.remove(fixture.key)
        await fixture.model.retry(fixture.album.id)
        await waitUntil("A retired detail must leave the navigation stack") {
            !fixture.route.shown && self.gridController(in: fixture.host) == nil
        }

        XCTAssertFalse(fixture.route.shown)
        XCTAssertEqual(fixture.route.deletions, 1)
        XCTAssertTrue(fixture.parent.albums.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)?.count, 0)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: fixture.key))
        XCTAssertNil(gridController(in: fixture.host), "The inactive album must not retain a loading grid")
        XCTAssertTrue(fixture.model.assets.isEmpty)
        let reads = fixture.driver.reads
        await fixture.model.retry(fixture.album.id)
        await nextMainQueueTurn()
        XCTAssertEqual(fixture.driver.reads, reads, "The retired screen cannot begin another load")
        XCTAssertEqual(fixture.route.deletions, 1, "Later callbacks must not repeat parent deletion")
    }

    func testRejectedDeletionKeepsTheVisibleAlbumAndItsParentUsable() async throws {
        let fixture = try await showAlbum()
        fixture.driver.rejectDeletion = true

        let deleted = await fixture.model.deleteAlbum(fixture.album.id)
        await nextMainQueueTurn()
        await nextMainQueueTurn()

        XCTAssertFalse(deleted)
        XCTAssertTrue(fixture.route.shown)
        XCTAssertEqual(fixture.route.deletions, 0)
        XCTAssertEqual(fixture.parent.albums.map(\.id), [fixture.album.id])
        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.driver.photos.map(\.id))
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.key)?.map(\.id), fixture.driver.photos.map(\.id))
        XCTAssertNotNil(gridController(in: fixture.host))
        XCTAssertEqual(fixture.model.actionError, "Deletion rejected")
        let reads = fixture.driver.reads
        await fixture.model.retry(fixture.album.id)
        XCTAssertEqual(fixture.driver.reads, reads + 1)
        XCTAssertTrue(fixture.route.shown)
        XCTAssertEqual(fixture.route.deletions, 0)
    }

    func testAnotherWindowsDeletionDismissesTheIdleVisibleAlbumWithoutRetry() async throws {
        let fixture = try await showAlbum()
        let reads = fixture.driver.reads

        LocalSnapshot.remove(fixture.key)
        await waitUntil("A confirmed deletion must retire an idle visible album without another action") {
            !fixture.route.shown && self.gridController(in: fixture.host) == nil
        }

        XCTAssertFalse(fixture.route.shown)
        XCTAssertEqual(fixture.route.deletions, 1)
        XCTAssertTrue(fixture.parent.albums.isEmpty)
        XCTAssertNil(LocalSnapshot.load([AssetLite].self, for: fixture.key))
        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertEqual(fixture.driver.reads, reads)
    }

    private func showAlbum() async throws -> RetirementFixture {
        let driver = RetirementDriver()
        let album = AlbumResponseDTO(id: UUID().uuidString, albumName: "Album", description: nil,
            assetCount: driver.photos.count, albumThumbnailAssetId: driver.photos[0].id,
            shared: false, createdAt: .distantPast, assets: nil)
        let key = LocalSnapshot.Key.album(album.id)
        snapshotKeys.append(key)
        let api = APIClient(session: MockSessionManager())
        let model = AlbumDetailViewModel(timelineRepo: RetirementTimeline(api: api, driver: driver),
            albumRepo: RetirementAlbums(api: api, driver: driver), assetRepo: AssetDetailRepository(api: api))
        let loaded = await model.loadAlbumDetail(album.id)
        XCTAssertTrue(loaded)
        let parent = AlbumListViewModel(repo: AlbumRepository(api: api))
        parent.albums = [album]
        LocalSnapshot.save([album], for: LocalSnapshot.Key.albumsList)
        let route = RetirementRoute()
        let host = UIHostingController(rootView: RetirementNavigationFixture(
            route: route, album: album, model: model, parent: parent)
            .environment(MockSessionManager() as SessionManager))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let presentedWindow = UIWindow(windowScene: scene)
        presentedWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        presentedWindow.rootViewController = host
        presentedWindow.makeKeyAndVisible()
        window = presentedWindow
        await waitUntil("The actual album detail must be pushed and finish its initial load") {
            driver.reads >= 2 && self.gridController(in: host) != nil
        }
        return RetirementFixture(album: album, key: key, driver: driver, model: model,
            parent: parent, route: route, host: host)
    }

    private func gridController(in controller: UIViewController) -> PhotoGridController? {
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.gridController(in: $0) }.first
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }
}

@MainActor @Observable
private final class RetirementRoute {
    var shown = true
    var deletions = 0
}

@MainActor
private struct RetirementNavigationFixture: View {
    let route: RetirementRoute
    let album: AlbumResponseDTO
    let model: AlbumDetailViewModel
    let parent: AlbumListViewModel

    var body: some View {
        NavigationStack {
            Text("Albums")
                .navigationDestination(isPresented: Bindable(route).shown) {
                    AlbumDetailView(album: album, onDeleted: {
                        route.deletions += 1
                        parent.removeDeletedAlbum(album.id)
                    }, viewModel: model)
                }
        }
    }
}

@MainActor
private struct RetirementFixture {
    let album: AlbumResponseDTO
    let key: String
    let driver: RetirementDriver
    let model: AlbumDetailViewModel
    let parent: AlbumListViewModel
    let route: RetirementRoute
    let host: UIViewController
}

@MainActor
private final class RetirementDriver {
    let photos = [AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
        thumbhash: nil, createdAt: Date(timeIntervalSince1970: 100))]
    private(set) var reads = 0
    var rejectDeletion = false
    func load() -> [AssetLite] { reads += 1; return photos }
    func delete() throws {
        if rejectDeletion { throw APIError.server(status: 403, message: "Deletion rejected") }
    }
}

private final class RetirementTimeline: TimelineRepository {
    let driver: RetirementDriver
    init(api: APIClient, driver: RetirementDriver) { self.driver = driver; super.init(api: api) }
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { await driver.load() }
}

private final class RetirementAlbums: AlbumRepository {
    let driver: RetirementDriver
    init(api: APIClient, driver: RetirementDriver) { self.driver = driver; super.init(api: api) }
    override func delete(_ id: String) async throws { try await driver.delete() }
}
