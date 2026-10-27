import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionLoadIsolationTests: XCTestCase {
    private var directories: [URL] = []
    private var snapshotKeys: [String] = []

    override func tearDown() async throws {
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        snapshotKeys.removeAll()
        directories.removeAll()
        try await super.tearDown()
    }

    func testOldCollectionLoadCannotUndoAcceptedFavoriteAndCurrentRetryStillPublishes() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let oldLoad = Task { await fixture.grid.load() }
        defer { oldLoad.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)

        await fixture.grid.toggleFavorite(fixture.asset)
        held.finishIfWaiting([fixture.asset])
        await oldLoad.value

        XCTAssertEqual(fixture.grid.assets.first?.isFavorite, true)
        XCTAssertEqual(snapshot(fixture.gridKey)?.first?.isFavorite, true)
        let current = asset(fixture.asset.id, hash: "current", favorite: true)
        fixture.source.read = { [current] }
        await fixture.grid.load()
        XCTAssertEqual(fixture.grid.assets.first?.thumbhash, "current")
        XCTAssertEqual(snapshot(fixture.gridKey)?.first?.thumbhash, "current")
    }

    func testOldCollectionLoadCannotRestoreAcceptedDeletionWithoutACacheRevisionChange() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let oldLoad = Task { await fixture.grid.load() }
        defer { oldLoad.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)
        let cacheRevision = fixture.manager.assetMutationRevision

        await fixture.grid.delete([fixture.asset.id])
        XCTAssertEqual(fixture.manager.assetMutationRevision, cacheRevision,
            "The fake repository accepts deletion without updating the shared cache")
        held.finishIfWaiting([fixture.asset])
        await oldLoad.value

        XCTAssertTrue(fixture.grid.assets.isEmpty)
        XCTAssertEqual(snapshot(fixture.gridKey)?.count, 0)
    }

    func testOldAlbumLoadCannotRestoreAcceptedRemovalAndCurrentRetryStillPublishes() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let oldLoad = Task { await fixture.album.loadAlbumDetail(fixture.albumID) }
        defer { oldLoad.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)

        await fixture.album.removeAssets([fixture.asset.id], from: fixture.albumID)
        held.finishIfWaiting([fixture.asset])
        let acceptedOldLoad = await oldLoad.value

        XCTAssertFalse(acceptedOldLoad)
        XCTAssertTrue(fixture.album.assets.isEmpty)
        XCTAssertEqual(snapshot(fixture.albumKey)?.count, 0)
        let added = asset(UUID().uuidString, hash: "added")
        fixture.source.read = { [added] }
        let refreshed = await fixture.album.loadAlbumDetail(fixture.albumID)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.album.assets.map(\.id), [added.id])
        XCTAssertEqual(snapshot(fixture.albumKey)?.map(\.id), [added.id])
    }

    func testNewerCollectionLoadWinsWhenAnOlderRequestFinishesLast() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let oldLoad = Task { await fixture.grid.load() }
        defer { oldLoad.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)
        let current = asset(fixture.asset.id, hash: "newer")
        fixture.source.read = { [current] }

        await fixture.grid.load()
        held.finishIfWaiting([asset(fixture.asset.id, hash: "older")])
        await oldLoad.value

        XCTAssertEqual(fixture.grid.assets.first?.thumbhash, "newer")
        XCTAssertEqual(snapshot(fixture.gridKey)?.first?.thumbhash, "newer")
    }

    func testNewerAlbumLoadWinsWhenAnOlderRequestFinishesLast() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let oldLoad = Task { await fixture.album.loadAlbumDetail(fixture.albumID) }
        defer { oldLoad.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)
        let current = asset(fixture.asset.id, hash: "newer")
        fixture.source.read = { [current] }

        let refreshed = await fixture.album.loadAlbumDetail(fixture.albumID)
        held.finishIfWaiting([asset(fixture.asset.id, hash: "older")])
        let acceptedOldLoad = await oldLoad.value

        XCTAssertTrue(refreshed)
        XCTAssertFalse(acceptedOldLoad)
        XCTAssertEqual(fixture.album.assets.first?.thumbhash, "newer")
        XCTAssertEqual(snapshot(fixture.albumKey)?.first?.thumbhash, "newer")
    }

    func testRejectedFavoriteDoesNotDiscardTheCurrentCollectionLoad() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let pending = Task { await fixture.grid.load() }
        defer { pending.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.mutations.rejectFavorite = true

        await fixture.grid.toggleFavorite(fixture.asset)
        held.finishIfWaiting([asset(fixture.asset.id, hash: "refreshed")])
        await pending.value

        XCTAssertEqual(fixture.grid.assets.first?.thumbhash, "refreshed")
        XCTAssertEqual(snapshot(fixture.gridKey)?.first?.thumbhash, "refreshed")
        XCTAssertNotNil(fixture.grid.actionError)
    }

    func testRejectedFavoriteDoesNotDiscardTheCurrentAlbumLoad() async throws {
        let fixture = try await fixture()
        let held = HeldCollectionLoad()
        fixture.source.read = { await held.value() }
        let pending = Task { await fixture.album.loadAlbumDetail(fixture.albumID) }
        defer { pending.cancel(); held.finishIfWaiting([]) }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.mutations.rejectFavorite = true

        await fixture.album.toggleFavorite(fixture.asset)
        held.finishIfWaiting([asset(fixture.asset.id, hash: "refreshed")])
        let accepted = await pending.value

        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.album.assets.first?.thumbhash, "refreshed")
        XCTAssertEqual(snapshot(fixture.albumKey)?.first?.thumbhash, "refreshed")
        XCTAssertNotNil(fixture.album.actionError)
    }

    func testExternalCacheMutationInvalidatesPendingAlbumAndCollectionReads() async throws {
        for isAlbum in [false, true] {
            let fixture = try await fixture()
            let held = HeldCollectionLoad()
            fixture.source.read = { await held.value() }
            let pending = Task {
                if isAlbum { _ = await fixture.album.loadAlbumDetail(fixture.albumID) }
                else { await fixture.grid.load() }
            }
            defer { pending.cancel(); held.finishIfWaiting([]) }
            await fulfillment(of: [held.started], timeout: 2)

            try fixture.manager.patchCachedAsset(fixture.asset.id, isFavorite: true)
            held.finishIfWaiting([asset(fixture.asset.id, hash: "obsolete")])
            await pending.value

            let displayed = isAlbum ? fixture.album.assets : fixture.grid.assets
            let key = isAlbum ? fixture.albumKey : fixture.gridKey
            XCTAssertEqual(displayed.first?.thumbhash, "initial")
            XCTAssertEqual(snapshot(key)?.first?.thumbhash, "initial")
            XCTAssertEqual(fixture.manager.getCachedAsset(id: fixture.asset.id)?.isFavorite, true)
        }
    }

    func testCacheObserverRetryCompletesTheInitialAlbumAndCollectionLoads() async throws {
        for isAlbum in [false, true] {
            let fixture = try await fixture(load: false)
            let held = HeldCollectionLoad()
            let current = asset(fixture.asset.id, hash: "current", favorite: true)
            var requests = 0
            fixture.source.read = {
                requests += 1
                return requests == 1 ? await held.value() : [current]
            }
            let initial = Task {
                if isAlbum { _ = await fixture.album.loadAlbumDetail(fixture.albumID) }
                else { await fixture.grid.load() }
            }
            defer { initial.cancel(); held.finishIfWaiting([]) }
            await fulfillment(of: [held.started], timeout: 2)
            let refreshed = expectation(description: "The collection screen's cache observer retries its initial load")
            withObservationTracking { _ = fixture.manager.assetMutationRevision } onChange: {
                Task { @MainActor in
                    if isAlbum { _ = await fixture.album.loadAlbumDetail(fixture.albumID) }
                    else { await fixture.grid.load() }
                    refreshed.fulfill()
                }
            }

            try fixture.manager.patchCachedAsset(fixture.asset.id, isFavorite: true)
            await fulfillment(of: [refreshed], timeout: 2)
            held.finishIfWaiting([fixture.asset])
            await initial.value

            let displayed = isAlbum ? fixture.album.assets : fixture.grid.assets
            let phase = isAlbum ? fixture.album.phase : fixture.grid.phase
            let key = isAlbum ? fixture.albumKey : fixture.gridKey
            XCTAssertEqual(displayed.first?.thumbhash, "current")
            XCTAssertEqual(displayed.first?.isFavorite, true)
            XCTAssertEqual(snapshot(key)?.first?.thumbhash, "current")
            XCTAssertEqual(requests, 2)
            if case .loaded = phase {} else { XCTFail("The observer retry must complete the first load") }
        }
    }

    private func fixture(load: Bool = true) async throws -> CollectionLoadFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-load-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let fixture = try CollectionLoadFixture(directory: directory)
        snapshotKeys.append(contentsOf: [fixture.gridKey, fixture.albumKey])
        if load {
            await fixture.grid.load()
            let loadedAlbum = await fixture.album.loadAlbumDetail(fixture.albumID)
            XCTAssertTrue(loadedAlbum)
        }
        return fixture
    }

    private func asset(_ id: String, hash: String, favorite: Bool = false) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: hash,
            createdAt: .distantPast, isFavorite: favorite)
    }

    private func snapshot(_ key: String) -> [AssetLite]? {
        LocalSnapshot.load([AssetLite].self, for: key)
    }
}

@MainActor
private final class CollectionLoadFixture {
    let asset: AssetLite
    let gridKey = "collection-load-\(UUID())"
    let albumID = UUID().uuidString
    var albumKey: String { LocalSnapshot.Key.album(albumID) }
    let manager: SwiftDataManager
    let source: CollectionLoadSource
    let mutations: CollectionLoadAssetRepository
    let grid: AssetGridViewModel
    let album: AlbumDetailViewModel

    init(directory: URL) throws {
        asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
            thumbhash: "initial", createdAt: .distantPast)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("cache.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        try manager.restoreToTimeline([asset])
        source = CollectionLoadSource(items: [asset])
        let api = makeStubAPIClient()
        mutations = CollectionLoadAssetRepository(api: api)
        let albums = CollectionLoadAlbumRepository(api: api)
        let source = source
        grid = AssetGridViewModel(assetRepo: mutations, albumRepo: albums, snapshotKey: gridKey,
            dataManager: manager, loader: { try await source.read() })
        album = AlbumDetailViewModel(timelineRepo: CollectionLoadTimelineRepository(api: api, source: source),
            albumRepo: albums, assetRepo: mutations, dataManager: manager)
    }
}

@MainActor
private final class CollectionLoadSource {
    var read: () async throws -> [AssetLite]
    init(items: [AssetLite]) { read = { items } }
}

@MainActor
private final class CollectionLoadTimelineRepository: TimelineRepository {
    private let source: CollectionLoadSource
    init(api: APIClient, source: CollectionLoadSource) {
        self.source = source
        super.init(api: api)
    }
    override func albumAssets(_ albumId: String, expectedCount: Int? = nil) async throws -> [AssetLite] {
        try await source.read()
    }
}

private final class CollectionLoadAlbumRepository: AlbumRepository {
    override func removeAssets(_ ids: [String], from albumId: String) async throws {}
}

private final class CollectionLoadAssetRepository: AssetDetailRepository {
    var rejectFavorite = false
    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        if rejectFavorite { throw APIError.server(status: 403, message: "Favorite rejected") }
    }
    override func delete(_ ids: [String], force: Bool = false) async throws {}
}

@MainActor
private final class HeldCollectionLoad {
    let started = XCTestExpectation(description: "The collection request reached its held response")
    private var continuation: CheckedContinuation<[AssetLite], Never>?
    func value() async -> [AssetLite] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finishIfWaiting(_ items: [AssetLite]) {
        continuation?.resume(returning: items)
        continuation = nil
    }
}
