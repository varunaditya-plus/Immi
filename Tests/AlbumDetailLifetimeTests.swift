import XCTest
@testable import ImmichApp

@MainActor
final class AlbumDetailLifetimeTests: XCTestCase {
    private var fixtures: [AlbumLifetimeFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.close() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    func testAcceptedDeletionRetiresItsModelAndPreventsNewRequests() async throws {
        let fixture = try fixture()
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        let loaded = await fixture.model.loadAlbumDetail(fixture.id)
        XCTAssertTrue(loaded)
        XCTAssertEqual(reports, [fixture.photos.map(\.id)])

        let deleted = await fixture.model.deleteAlbum(fixture.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertTrue(fixture.model.phase.isIdle)
        XCTAssertNil(fixture.snapshot())
        let calls = fixture.driver.calls
        let reloaded = await fixture.model.loadAlbumDetail(fixture.id)
        XCTAssertFalse(reloaded)
        await fixture.model.retry(fixture.id)
        await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id)
        await fixture.model.addAssets(["new"], to: fixture.id)
        await fixture.model.toggleFavorite(fixture.photos[0])
        await fixture.model.setFavorite([fixture.photos[0].id], to: true)
        await fixture.model.setArchived([fixture.photos[0].id], to: true)
        await fixture.model.setLocked([fixture.photos[0].id])
        await fixture.model.deleteAssets([fixture.photos[0].id])
        let shared = await fixture.model.addUsers(["friend"], to: fixture.id)
        let link = await fixture.model.createSharedLink(albumId: fixture.id)
        let shareFiles = await fixture.model.shareURLs(for: [fixture.photos[0].id])
        _ = await fixture.model.addToOtherAlbum([fixture.photos[0].id], album: fixture.album)
        let deletedAgain = await fixture.model.deleteAlbum(fixture.id)

        XCTAssertFalse(shared)
        XCTAssertNil(link)
        XCTAssertTrue(shareFiles.isEmpty)
        XCTAssertFalse(deletedAgain)
        XCTAssertEqual(fixture.driver.calls, calls, "A retired screen cannot begin another server operation")
        XCTAssertEqual(reports, [fixture.photos.map(\.id)], "Deletion cannot emit an empty-membership update")
        XCTAssertNil(fixture.snapshot())
        XCTAssertNil(fixture.model.actionError)
    }

    func testLateMutationsCannotRecreateADeletedAlbumsSnapshotOrNotifyItsParent() async throws {
        for action in ["remove", "favorite", "lock", "deleteAssets", "add"] {
            let fixture = try fixture()
            var reports: [[String]] = []
            fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
            _ = await fixture.model.loadAlbumDetail(fixture.id)
            let gate = AlbumLifetimeGate()
            fixture.driver.mutation = { operation in
                if operation == action { try await gate.wait() }
            }
            let task = Task {
                switch action {
                case "remove": await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id)
                case "favorite": await fixture.model.toggleFavorite(fixture.photos[0])
                case "lock": await fixture.model.setLocked([fixture.photos[0].id])
                case "deleteAssets": await fixture.model.deleteAssets([fixture.photos[0].id])
                default: await fixture.model.addAssets(["new"], to: fixture.id)
                }
            }
            addTeardownBlock { await gate.complete(.failure(CancellationError())); await task.value }
            await fulfillment(of: [gate.started], timeout: 2)
            let deleted = await fixture.model.deleteAlbum(fixture.id)
            XCTAssertTrue(deleted, action)
            XCTAssertNil(fixture.snapshot(), action)
            gate.complete(.success(()))
            await task.value

            XCTAssertNil(fixture.snapshot(), "Late \(action) must not restore the deleted key")
            XCTAssertTrue(fixture.model.assets.isEmpty, action)
            XCTAssertTrue(fixture.model.phase.isIdle, action)
            XCTAssertNil(fixture.model.actionError, action)
            XCTAssertEqual(fixture.driver.calls["read"], 1, "Late add must not start reconciliation")
            XCTAssertEqual(reports, [fixture.photos.map(\.id)], action)
        }
    }

    func testLateReadAfterDeletionCannotRestoreRowsOrTheSnapshot() async throws {
        let fixture = try fixture()
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        let gate = AlbumLifetimeGate()
        fixture.driver.read = { try await gate.wait(); return fixture.photos }
        let loading = Task { await fixture.model.loadAlbumDetail(fixture.id) }
        addTeardownBlock { await gate.complete(.failure(CancellationError())); _ = await loading.value }
        await fulfillment(of: [gate.started], timeout: 2)
        let deleted = await fixture.model.deleteAlbum(fixture.id)
        XCTAssertTrue(deleted)
        gate.complete(.success(()))
        let loaded = await loading.value

        XCTAssertFalse(loaded)
        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertNil(fixture.snapshot())
        XCTAssertEqual(reports.count, 1)
    }

    func testFailedDeletionKeepsTheCurrentAlbumUsableAndRefreshable() async throws {
        let fixture = try fixture()
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        fixture.driver.mutation = { operation in
            if operation == "deleteAlbum" { throw APIError.server(status: 403, message: "Not allowed") }
        }
        let deleted = await fixture.model.deleteAlbum(fixture.id)
        XCTAssertFalse(deleted)
        XCTAssertEqual(fixture.model.actionError, "Not allowed")
        XCTAssertEqual(fixture.snapshot()?.map(\.id), fixture.photos.map(\.id))
        let fresh = fixture.photos[1]
        fixture.driver.read = { [fresh] }
        let refreshed = await fixture.model.loadAlbumDetail(fixture.id)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.model.assets.map(\.id), [fresh.id])
        XCTAssertEqual(reports, [fixture.photos.map(\.id), [fresh.id]])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), [fresh.id])
    }

    func testCacheOnlyMutationCannotPublishAnUnconfirmedWholeMembership() async throws {
        let fixture = try fixture()
        LocalSnapshot.save(fixture.photos, for: LocalSnapshot.Key.album(fixture.id))
        fixture.driver.read = { throw APIError.server(status: 503, message: "Refresh unavailable") }
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        let loaded = await fixture.model.loadAlbumDetail(fixture.id)
        XCTAssertFalse(loaded)
        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.photos.map(\.id))
        XCTAssertTrue(reports.isEmpty)
        await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id)

        XCTAssertEqual(fixture.driver.calls["read"], 2, "The accepted mutation reconciles its incomplete baseline")
        XCTAssertEqual(fixture.model.assets.map(\.id), [fixture.photos[1].id])
        XCTAssertTrue(reports.isEmpty)
        fixture.driver.read = { [fixture.photos[1]] }
        let refreshed = await fixture.model.loadAlbumDetail(fixture.id)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(reports, [[fixture.photos[1].id]])
    }

    func testAcceptedAddWithFailedReloadInvalidatesItsPreviousMembershipAuthority() async throws {
        let fixture = try fixture()
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        fixture.driver.read = { throw APIError.server(status: 503, message: "Refresh unavailable") }
        await fixture.model.addAssets(["not-yet-loaded"], to: fixture.id)
        XCTAssertNotNil(fixture.model.actionError)
        await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id)

        XCTAssertEqual(reports, [fixture.photos.map(\.id)], "The cached remainder is no longer the whole album")
        XCTAssertEqual(fixture.driver.calls["read"], 3)
        fixture.driver.read = { [fixture.photos[1]] }
        let refreshed = await fixture.model.loadAlbumDetail(fixture.id)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(reports.last, [fixture.photos[1].id])
    }

    func testMetadataOnlyActionsDoNotLoseACompleteSnapshotsAuthority() async throws {
        let fixture = try fixture()
        var reports: [[String]] = []
        fixture.model.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        await fixture.model.toggleFavorite(fixture.photos[0])
        await fixture.model.setArchived([fixture.photos[0].id], to: true)
        await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id)

        XCTAssertEqual(fixture.driver.calls["read"], 1, "A complete snapshot can publish the confirmed removal directly")
        XCTAssertEqual(reports, [fixture.photos.map(\.id), [fixture.photos[1].id]])
    }

    func testAnotherDetailDeletingTheAlbumRejectsHeldReadsInTheFirstWindow() async throws {
        let fixture = try fixture()
        let other = fixture.anotherModel()
        var reports: [[String]] = []
        other.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        _ = await other.loadAlbumDetail(fixture.id)
        let gate = AlbumLifetimeGate()
        fixture.driver.read = { try await gate.wait(); return fixture.photos }
        let loading = Task { await other.loadAlbumDetail(fixture.id) }
        addTeardownBlock { await gate.complete(.failure(CancellationError())); _ = await loading.value }
        await fulfillment(of: [gate.started], timeout: 2)
        let deleted = await fixture.model.deleteAlbum(fixture.id)
        XCTAssertTrue(deleted)
        gate.complete(.success(()))
        let loaded = await loading.value

        XCTAssertFalse(loaded)
        XCTAssertNil(fixture.snapshot())
        XCTAssertTrue(other.assets.isEmpty)
        XCTAssertEqual(reports, [fixture.photos.map(\.id)])
        let reads = fixture.driver.calls["read"]
        let reloaded = await other.loadAlbumDetail(fixture.id)
        XCTAssertFalse(reloaded, "An existing instance cannot rebind the invalidated album")
        XCTAssertEqual(fixture.driver.calls["read"], reads)
    }

    func testAnotherDetailOrContextDeletionRejectsHeldFavoriteAndRemovalWrites() async throws {
        for contextDelete in [false, true] {
            for operation in ["favorite", "remove"] {
                let fixture = try fixture()
                let other = fixture.anotherModel()
                _ = await fixture.model.loadAlbumDetail(fixture.id)
                var reports: [[String]] = []
                other.observeContents(for: fixture.id) { reports.append($0.map(\.id)) }
                _ = await other.loadAlbumDetail(fixture.id)
                let gate = AlbumLifetimeGate()
                fixture.driver.mutation = { current in if current == operation { try await gate.wait() } }
                let pending = Task {
                    if operation == "favorite" { await other.toggleFavorite(fixture.photos[0]) }
                    else { await other.removeAssets([fixture.photos[0].id], from: fixture.id) }
                }
                addTeardownBlock { await gate.complete(.failure(CancellationError())); await pending.value }
                await fulfillment(of: [gate.started], timeout: 2)
                let deleted: Bool
                if contextDelete {
                    let list = AlbumListViewModel(repo: fixture.albumRepository())
                    list.albums = [fixture.album]
                    deleted = await list.deleteAlbum(fixture.id)
                } else { deleted = await fixture.model.deleteAlbum(fixture.id) }
                XCTAssertTrue(deleted)
                gate.complete(.success(()))
                await pending.value

                XCTAssertNil(fixture.snapshot(), "Deletion must remain effective across open models")
                XCTAssertTrue(other.assets.isEmpty)
                XCTAssertNil(other.actionError)
                XCTAssertEqual(reports, [fixture.photos.map(\.id)])
            }
        }
    }

    func testAnOlderMutationCannotChangeTheModelAfterItLoadsAnotherAlbum() async throws {
        let fixture = try fixture()
        _ = await fixture.model.loadAlbumDetail(fixture.id)
        let gate = AlbumLifetimeGate()
        fixture.driver.mutation = { operation in if operation == "remove" { try await gate.wait() } }
        let removing = Task { await fixture.model.removeAssets([fixture.photos[0].id], from: fixture.id) }
        addTeardownBlock { await gate.complete(.failure(CancellationError())); await removing.value }
        await fulfillment(of: [gate.started], timeout: 2)
        let nextID = UUID().uuidString
        addTeardownBlock { await LocalSnapshot.remove(LocalSnapshot.Key.album(nextID)) }
        let nextPhoto = AssetLite(id: "next-\(UUID())", isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 40))
        let nextPhotos = [fixture.photos[0], nextPhoto]
        fixture.driver.read = { nextPhotos }
        let switched = await fixture.model.loadAlbumDetail(nextID)
        XCTAssertTrue(switched)
        gate.complete(.success(()))
        await removing.value

        XCTAssertEqual(fixture.model.assets.map(\.id), nextPhotos.map(\.id),
            "The same photo may belong to both albums; A's completion must not remove it from B")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(nextID))?.map(\.id), nextPhotos.map(\.id))
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.driver.calls["read"], 2)
    }

    private func fixture() throws -> AlbumLifetimeFixture {
        let fixture = try AlbumLifetimeFixture()
        fixtures.append(fixture)
        return fixture
    }
}

@MainActor
private final class AlbumLifetimeFixture {
    let id = UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-lifetime-\(UUID())")
    let driver = AlbumLifetimeDriver()
    let photos = (0..<2).map {
        AssetLite(id: "lifetime-\(UUID())-\($0)", isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: Double($0)))
    }
    private var storedModel: AlbumDetailViewModel?
    private var storedManager: SwiftDataManager?
    var model: AlbumDetailViewModel { storedModel! }
    var album: AlbumResponseDTO {
        .init(id: id, albumName: "Album", description: nil, assetCount: 2,
            albumThumbnailAssetId: photos[0].id, shared: false, createdAt: .distantPast, assets: nil)
    }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        storedManager = manager
        driver.read = { [photos] in photos }
        let api = APIClient(session: MockSessionManager())
        storedModel = AlbumDetailViewModel(timelineRepo: AlbumLifetimeTimeline(api: api, driver: driver),
            albumRepo: AlbumLifetimeAlbums(api: api, driver: driver),
            assetRepo: AlbumLifetimeAssets(api: api, driver: driver), dataManager: manager)
    }

    func snapshot() -> [AssetLite]? {
        LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(id))
    }

    func anotherModel() -> AlbumDetailViewModel {
        let api = APIClient(session: MockSessionManager())
        return AlbumDetailViewModel(timelineRepo: AlbumLifetimeTimeline(api: api, driver: driver),
            albumRepo: AlbumLifetimeAlbums(api: api, driver: driver),
            assetRepo: AlbumLifetimeAssets(api: api, driver: driver), dataManager: storedManager!)
    }

    func albumRepository() -> AlbumRepository {
        AlbumLifetimeAlbums(api: APIClient(session: MockSessionManager()), driver: driver)
    }

    func close() {
        LocalSnapshot.remove(LocalSnapshot.Key.album(id))
        storedModel = nil
        storedManager = nil
        driver.read = { [] }
        driver.mutation = { _ in }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class AlbumLifetimeDriver {
    var read: () async throws -> [AssetLite] = { [] }
    var mutation: (String) async throws -> Void = { _ in }
    private(set) var calls: [String: Int] = [:]
    func fetch() async throws -> [AssetLite] { calls["read", default: 0] += 1; return try await read() }
    func perform(_ operation: String) async throws {
        calls[operation, default: 0] += 1
        try await mutation(operation)
    }
}

private final class AlbumLifetimeTimeline: TimelineRepository {
    let driver: AlbumLifetimeDriver
    init(api: APIClient, driver: AlbumLifetimeDriver) { self.driver = driver; super.init(api: api) }
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { try await driver.fetch() }
}

private final class AlbumLifetimeAlbums: AlbumRepository {
    let driver: AlbumLifetimeDriver
    init(api: APIClient, driver: AlbumLifetimeDriver) { self.driver = driver; super.init(api: api) }
    override func delete(_ id: String) async throws { try await driver.perform("deleteAlbum") }
    override func removeAssets(_ ids: [String], from albumId: String) async throws { try await driver.perform("remove") }
    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        try await driver.perform("add"); return []
    }
    override func addUsers(_ userIds: [String], to albumId: String) async throws { try await driver.perform("addUsers") }
    override func createSharedLink(albumId: String) async throws -> SharedLinkDTO {
        try await driver.perform("link")
        return try JSONDecoder().decode(SharedLinkDTO.self,
            from: Data("{\"id\":\"link\",\"key\":\"key\",\"type\":\"ALBUM\"}".utf8))
    }
}

private final class AlbumLifetimeAssets: AssetDetailRepository {
    let driver: AlbumLifetimeDriver
    init(api: APIClient, driver: AlbumLifetimeDriver) { self.driver = driver; super.init(api: api) }
    override func toggleFavorite(_ id: String, to value: Bool) async throws { try await driver.perform("favorite") }
    override func setVisibility(_ id: String, to value: Visibility) async throws { try await driver.perform("lock") }
    override func delete(_ ids: [String], force: Bool = false) async throws { try await driver.perform("deleteAssets") }
    override func shareFiles(_ ids: [String]) async -> [URL] { try? await driver.perform("share"); return [] }
}

@MainActor
private final class AlbumLifetimeGate {
    let started = XCTestExpectation(description: "An album request is held")
    private var result: Result<Void, Error>?
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var didStart = false
    func wait() async throws {
        if !didStart { didStart = true; started.fulfill() }
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume(with: result) }
    }
}
