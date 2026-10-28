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

    func testCachedHydrationAndFailedRefreshCannotOverwriteNewerParentContents() async throws {
        let fixture = try await cachedDetail()
        await settlePresentation()
        assertNewerParent(fixture)
        XCTAssertTrue(fixture.reports.rows.isEmpty, "Hydrating an offline cache is not a server-confirmed update")

        fixture.driver.complete(.failure(APIError.server(status: 503, message: "Unavailable")))
        await settlePresentation()
        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.cached.map(\.id))
        XCTAssertNotNil(fixture.model.phase.value)
        assertNewerParent(fixture)
        window?.isHidden = true
        window?.rootViewController = nil
        await settlePresentation()
        assertNewerParent(fixture)
        XCTAssertTrue(fixture.reports.rows.isEmpty, "Leaving an offline detail must not publish the stale cache")
    }

    func testFreshResponseIdenticalToCacheStillPublishesItsFirstConfirmedContents() async throws {
        let fixture = try await cachedDetail()
        await settlePresentation()
        assertNewerParent(fixture)
        XCTAssertTrue(fixture.reports.rows.isEmpty)

        fixture.driver.complete(.success(fixture.cached))
        await settlePresentation()
        XCTAssertEqual(fixture.reports.rows, [fixture.cached.map(\.id)])
        XCTAssertEqual(fixture.parent.albums.first?.assetCount, 2)
        XCTAssertEqual(fixture.parent.albums.first?.albumThumbnailAssetId, fixture.cached.last?.id)
        XCTAssertEqual(LocalSnapshot.load([AlbumResponseDTO].self,
            for: LocalSnapshot.Key.albumsList)?.first?.assetCount, 2)
        window?.isHidden = true
        window?.rootViewController = nil
        await settlePresentation()
        XCTAssertEqual(fixture.reports.rows.count, 1, "Disappearance must not replay an already delivered update")
    }

    func testCacheOnlyRemovalCannotPublishAnIncompleteListWhenReconciliationFails() async throws {
        let fixture = try await cachedDetail()
        fixture.driver.complete(.failure(APIError.server(status: 503, message: "Unavailable")))
        await settlePresentation()
        await fixture.model.removeAssets([fixture.cached[0].id], from: fixture.albumID)
        await settlePresentation()
        XCTAssertEqual(fixture.model.assets.map(\.id), [fixture.cached[1].id])
        XCTAssertEqual(fixture.driver.removals, [fixture.cached[0].id], "The server accepted the removal")
        assertNewerParent(fixture)
        XCTAssertTrue(fixture.reports.rows.isEmpty, "The cached remainder cannot establish the server's complete membership")
    }

    private func cachedDetail() async throws -> CachedAlbumFixture {
        let id = UUID().uuidString
        previousParentSnapshot = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)
        albumKey = LocalSnapshot.Key.album(id)
        let cached = [photo(UUID().uuidString, date: 10), photo(UUID().uuidString, date: 20)]
        LocalSnapshot.save(cached, for: LocalSnapshot.Key.album(id))
        let album = AlbumResponseDTO(id: id, albumName: "Newer parent", description: nil, assetCount: 3,
            albumThumbnailAssetId: "newer-cover", shared: false, createdAt: .distantPast, assets: nil)
        let api = APIClient(session: MockSessionManager())
        let driver = CachedAlbumDriver()
        addTeardownBlock { await driver.complete(.failure(CancellationError())) }
        let model = AlbumDetailViewModel(timelineRepo: CachedAlbumTimeline(api: api, driver: driver),
            albumRepo: CachedAlbumRepository(api: api, driver: driver), assetRepo: AssetDetailRepository(api: api))
        let parent = AlbumListViewModel(repo: AlbumRepository(api: api))
        parent.albums = [album]
        LocalSnapshot.save([album], for: LocalSnapshot.Key.albumsList)
        let reports = CachedAlbumReports()
        reportsEnabled = true
        let detail = AlbumDetailView(album: album, onContentsChanged: { [weak self] assets in
            guard self?.reportsEnabled == true else { return }
            reports.rows.append(assets.map(\.id))
            parent.applyContents(assets, to: id)
        }, viewModel: model)
        let host = UIHostingController(rootView: NavigationStack { detail }
            .environment(MockSessionManager() as SessionManager))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let presentedWindow = UIWindow(windowScene: scene)
        presentedWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        presentedWindow.rootViewController = host
        presentedWindow.makeKeyAndVisible()
        window = presentedWindow
        await fulfillment(of: [driver.started], timeout: 3)
        return CachedAlbumFixture(albumID: id, cached: cached, model: model, parent: parent,
            driver: driver, reports: reports)
    }

    private func assertNewerParent(_ fixture: CachedAlbumFixture,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.parent.albums.first?.assetCount, 3, file: file, line: line)
        XCTAssertEqual(fixture.parent.albums.first?.albumThumbnailAssetId, "newer-cover", file: file, line: line)
        let saved = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)?.first
        XCTAssertEqual(saved?.assetCount, 3, file: file, line: line)
        XCTAssertEqual(saved?.albumThumbnailAssetId, "newer-cover", file: file, line: line)
    }

    private func settlePresentation() async {
        try? await Task.sleep(for: .milliseconds(150))
        window?.rootViewController?.view.setNeedsLayout()
        window?.rootViewController?.view.layoutIfNeeded()
        await nextMainQueueTurn()
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

@MainActor
private struct CachedAlbumFixture {
    let albumID: String
    let cached: [AssetLite]
    let model: AlbumDetailViewModel
    let parent: AlbumListViewModel
    let driver: CachedAlbumDriver
    let reports: CachedAlbumReports
}

@MainActor
private final class CachedAlbumReports { var rows: [[String]] = [] }

@MainActor
private final class CachedAlbumDriver {
    let started = XCTestExpectation(description: "The cached album is waiting for its server response")
    var removals: [String] = []
    func remove(_ ids: [String]) { removals.append(contentsOf: ids) }
    private var didStart = false
    private var result: Result<[AssetLite], Error>?
    private var waiters: [CheckedContinuation<[AssetLite], Error>] = []
    func load() async throws -> [AssetLite] {
        if !didStart { didStart = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func complete(_ result: Result<[AssetLite], Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }
}

private final class CachedAlbumTimeline: TimelineRepository {
    let driver: CachedAlbumDriver
    init(api: APIClient, driver: CachedAlbumDriver) { self.driver = driver; super.init(api: api) }
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { try await driver.load() }
}

private final class CachedAlbumRepository: AlbumRepository {
    let driver: CachedAlbumDriver
    init(api: APIClient, driver: CachedAlbumDriver) { self.driver = driver; super.init(api: api) }
    override func removeAssets(_ ids: [String], from albumId: String) async throws { await driver.remove(ids) }
}
