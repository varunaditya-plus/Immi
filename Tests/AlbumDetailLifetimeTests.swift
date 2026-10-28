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
    override func update(_ id: String, name: String?, description: String??) async throws {
        try await driver.perform("update")
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
