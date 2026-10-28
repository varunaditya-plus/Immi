import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumContentsReportingTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var albumKey: String?
    private var previousParentSnapshot: [AlbumResponseDTO]?
    private var reportsEnabled = false

    override func tearDown() async throws {
        reportsEnabled = false
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        if let albumKey {
            LocalSnapshot.remove(albumKey)
            if let previousParentSnapshot {
                LocalSnapshot.save(previousParentSnapshot, for: LocalSnapshot.Key.albumsList)
            } else { LocalSnapshot.remove(LocalSnapshot.Key.albumsList) }
        }
        albumKey = nil
        previousParentSnapshot = nil
        try await super.tearDown()
    }

    func testSameCountReplacementUpdatesItsParentCoverBeforeTheDetailDisappears() async throws {
        let albumID = UUID().uuidString
        let parentKey = LocalSnapshot.Key.albumsList
        previousParentSnapshot = LocalSnapshot.load([AlbumResponseDTO].self, for: parentKey)
        albumKey = LocalSnapshot.Key.album(albumID)
        let removed = photo("removed-\(UUID())", date: 10)
        let kept = photo("kept-\(UUID())", date: 20)
        let replacement = photo("replacement-\(UUID())", date: 30)
        let driver = AlbumContentsDriver(albumID: albumID, response: [removed, kept])
        let api = APIClient(session: MockSessionManager())
        let model = AlbumDetailViewModel(
            timelineRepo: AlbumContentsTimeline(api: api, driver: driver),
            albumRepo: AlbumRepository(api: api), assetRepo: AssetDetailRepository(api: api))
        let preloaded = await model.loadAlbumDetail(albumID)
        XCTAssertTrue(preloaded)
        let album = AlbumResponseDTO(id: albumID, albumName: "Album", description: nil, assetCount: 2,
            albumThumbnailAssetId: removed.id, shared: false, createdAt: .distantPast, assets: nil)
        let parent = AlbumListViewModel(repo: AlbumRepository(api: api))
        parent.albums = [album]
        var reports: [[String]] = []
        let expected = [replacement.id, kept.id]
        let changed = expectation(description: "The still-visible album reports its replacement contents")
        var reportedReplacement = false
        reportsEnabled = true
        let detail = AlbumDetailView(album: album, onContentsChanged: { [weak self] assets in
            guard self?.reportsEnabled == true else { return }
            reports.append(assets.map(\.id))
            parent.applyContents(assets, to: albumID)
            if assets.map(\.id) == expected, !reportedReplacement {
                reportedReplacement = true
                changed.fulfill()
            }
        }, viewModel: model)
        let host = UIHostingController(rootView: NavigationStack { detail }
            .environment(MockSessionManager() as SessionManager))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let presentedWindow = UIWindow(windowScene: scene)
        presentedWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        presentedWindow.rootViewController = host
        presentedWindow.makeKeyAndVisible()
        window = presentedWindow
        try await waitUntil { driver.requests >= 2 && self.gridController(in: host) != nil }
        XCTAssertEqual(parent.albums.first?.albumThumbnailAssetId, removed.id)
        driver.response = [replacement, kept]
        let loaded = await model.loadAlbumDetail(albumID)
        XCTAssertTrue(loaded)
        await fulfillment(of: [changed], timeout: 3)

        XCTAssertTrue(reportedReplacement)
        XCTAssertEqual(model.assets.count, 2)
        XCTAssertTrue(reports.contains(expected))
        XCTAssertEqual(parent.albums.first?.assetCount, 2)
        XCTAssertEqual(parent.albums.first?.albumThumbnailAssetId, replacement.id)
        XCTAssertEqual(LocalSnapshot.load([AlbumResponseDTO].self, for: parentKey)?.first?.albumThumbnailAssetId,
            replacement.id)
        XCTAssertFalse(presentedWindow.isHidden, "The parent must update while the detail stays visible")
        XCTAssertTrue(presentedWindow.rootViewController === host)
        XCTAssertNotNil(gridController(in: host))

        let reportCount = reports.count
        var metadataOnly = replacement
        metadataOnly.isFavorite = true
        driver.response = [metadataOnly, kept]
        _ = await model.loadAlbumDetail(albumID)
        await nextMainQueueTurn()
        await nextMainQueueTurn()
        XCTAssertEqual(reports.count, reportCount, "Same members should not repeatedly notify the parent")
    }

    private func photo(_ id: String, date: TimeInterval) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: date))
    }

    private func gridController(in controller: UIViewController) -> PhotoGridController? {
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.gridController(in: $0) }.first
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "The actual album detail must appear and load before the replacement")
    }
}

@MainActor
private final class AlbumContentsDriver {
    let albumID: String
    var response: [AssetLite]
    private(set) var requests = 0
    init(albumID: String, response: [AssetLite]) { self.albumID = albumID; self.response = response }
    func load(_ id: String) -> [AssetLite] {
        XCTAssertEqual(id, albumID)
        requests += 1
        return response
    }
}

private final class AlbumContentsTimeline: TimelineRepository {
    private let driver: AlbumContentsDriver
    init(api: APIClient, driver: AlbumContentsDriver) { self.driver = driver; super.init(api: api) }
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { await driver.load(albumId) }
}
