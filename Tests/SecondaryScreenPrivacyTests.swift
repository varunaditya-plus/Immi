import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SecondaryScreenPrivacyTests: XCTestCase {
    private var directories: [URL] = []
    private var cleanup: [() -> Void] = []
    private var savedFavorites: [AssetLite]?

    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        savedFavorites = LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.libraryFavorites)
    }

    override func tearDown() async throws {
        cleanup.forEach { $0() }
        cleanup.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        if let savedFavorites { LocalSnapshot.save(savedFavorites, for: LocalSnapshot.Key.libraryFavorites) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryFavorites) }
        savedFavorites = nil
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testRetainedStoriesAndOfflineFavoritesUseCurrentPrivacyAndRemovalState() async throws {
        let fixture = try fixture()
        let photos = fixture.ids.map { AssetLite(makeTestAsset(id: $0)) }
        let story = MemoryStory(id: "cached-story", title: "Saved title", subtitle: "Saved date", assets: photos)
        let memories = MemoriesViewModel(repo: MemoriesRepository(api: fixture.api),
            assetRepo: AssetDetailRepository(api: fixture.api), dataManager: fixture.manager)
        let library = library(fixture)
        memories.stories = [story]
        library.memories = [story]
        LocalSnapshot.save(photos, for: LocalSnapshot.Key.libraryFavorites)
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        try fixture.manager.setAssetVisibility([fixture.ids[1]], to: "archive")
        DeletedServerAssetRegistry.shared.record([fixture.ids[2]], permanently: false)

        await library.load()
        await memories.loadMemories() // Offline failure keeps the raw story.

        for stories in [memories.stories, library.memories] {
            XCTAssertEqual(stories.first?.assets.map(\.id), [fixture.ids[3]])
            XCTAssertEqual(stories.first?.title, story.title)
            XCTAssertEqual(stories.first?.subtitle, story.subtitle)
        }
        XCTAssertEqual(library.favorites.map(\.id), [fixture.ids[3]])
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "timeline")
        DeletedServerAssetRegistry.shared.restore([fixture.ids[2]])
        XCTAssertEqual(memories.stories.first?.assets.map(\.id), [fixture.ids[0], fixture.ids[2], fixture.ids[3]])
        XCTAssertEqual(library.favorites.map(\.id), [fixture.ids[0], fixture.ids[2], fixture.ids[3]])
        try fixture.manager.purgeAssets([fixture.ids[0], fixture.ids[2], fixture.ids[3]], reason: .trashed)
        XCTAssertTrue(memories.stories.isEmpty)
        XCTAssertTrue(library.memories.isEmpty)
        XCTAssertTrue(library.favorites.isEmpty)
    }

    func testHeldMemoryPayloadCannotBringBackALockedCoverAndRetryKeepsVisiblePhotos() async throws {
        let fixture = try fixture()
        let gate = SecondaryResponseGate<[MemoryDTO]>()
        cleanup.append { gate.close() }
        fixture.api.memories = { try await gate.value() }
        let model = MemoriesViewModel(repo: MemoriesRepository(api: fixture.api),
            assetRepo: AssetDetailRepository(api: fixture.api), dataManager: fixture.manager)
        let load = Task { await model.loadMemories() }
        await fulfillment(of: [gate.started], timeout: 2)
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        gate.complete([try memory(ids: Array(fixture.ids.prefix(2)))])
        await load.value

        XCTAssertEqual(model.stories.first?.assets.map(\.id), [fixture.ids[1]])
        XCTAssertEqual(model.stories.first?.cover?.id, fixture.ids[1])
        fixture.api.memories = { throw APIError.notConnected }
        await model.retry()
        XCTAssertEqual(model.stories.first?.assets.map(\.id), [fixture.ids[1]])
    }

    func testFreshEmptyFavoritesReplaceHiddenRowsAndRemovingAVisibleFavoritePreservesOtherHiddenRows() async throws {
        let emptyFixture = try fixture()
        let hidden = AssetLite(makeTestAsset(id: emptyFixture.ids[0], isFavorite: true))
        let emptyLibrary = library(emptyFixture)
        emptyLibrary.favorites = [hidden]
        try emptyFixture.manager.setAssetVisibility([hidden.id], to: "locked")
        emptyFixture.api.favorites = { SearchResponseDTO(assets: .init(items: [], total: 0, nextPage: nil)) }

        await emptyLibrary.refreshFavorites()
        try emptyFixture.manager.setAssetVisibility([hidden.id], to: "timeline")

        XCTAssertTrue(emptyLibrary.favorites.isEmpty,
            "Unlocking must not restore a row rejected by a successful empty response")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.libraryFavorites)?.count, 0)

        let removalFixture = try fixture()
        let photos = removalFixture.ids.prefix(2).map { AssetLite(makeTestAsset(id: $0, isFavorite: true)) }
        let removalLibrary = library(removalFixture,
            assetRepository: AssetDetailRepository(api: removalFixture.api, dataManager: removalFixture.manager))
        removalLibrary.favorites = photos
        try removalFixture.manager.setAssetVisibility([photos[0].id], to: "locked")
        var mutations = 0
        removalFixture.api.mutate = { endpoint in
            XCTAssertEqual(endpoint.path, "/assets/\(photos[1].id)")
            XCTAssertEqual(endpoint.method, .put)
            mutations += 1
        }

        await removalLibrary.toggleFavorite(photos[1])

        XCTAssertEqual(mutations, 1)
        XCTAssertNil(removalLibrary.actionError)
        XCTAssertTrue(removalLibrary.favorites.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.libraryFavorites)?.map(\.id),
                       [photos[0].id])
        try removalFixture.manager.setAssetVisibility([photos[0].id], to: "timeline")
        XCTAssertEqual(removalLibrary.favorites.map(\.id), [photos[0].id])
        XCTAssertTrue(removalLibrary.favorites.allSatisfy(\.isFavorite))
    }

    func testMapFiltersPrivateAndDeletedMarkersBeforeCoordinateDeduplication() throws {
        let fixture = try fixture()
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        try fixture.manager.setAssetVisibility([fixture.ids[2]], to: "archive")
        let markers = [marker(fixture.ids[0], latitude: 12), marker(fixture.ids[1], latitude: 12),
                       marker(fixture.ids[2], latitude: 25), marker(fixture.ids[3], latitude: 38)]
        DeletedServerAssetRegistry.shared.record([fixture.ids[3]], permanently: true)

        let visible = MapMarkerDTO.visible(in: markers,
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: fixture.manager))

        XCTAssertEqual(visible.map(\.id), [fixture.ids[1]],
                       "A private marker at the same coordinate must not consume the public marker's slot")
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "timeline")
        XCTAssertEqual(MapMarkerDTO.visible(in: markers,
            policy: AssetVisibilityPolicy(scope: .timeline, dataManager: fixture.manager)).map(\.id), [fixture.ids[0]])
    }

    func testExplicitAndFallbackCoversHideLocksAndDeletionsButAllowArchives() async throws {
        let fixture = try fixture()
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        let album = album(cover: fixture.ids[0])
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "archive")
        XCTAssertEqual(store.coverID(for: album), fixture.ids[0])
        await store.resolveCover(for: album, repository: repository)
        XCTAssertEqual(repository.requests, 0)

        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        XCTAssertNil(store.coverID(for: album))
        repository.fetch = { [fixture] in [fixture.ids[1]] }
        await store.resolveCover(for: album, repository: repository)
        XCTAssertEqual(store.coverID(for: album), fixture.ids[1])
        try fixture.manager.purgeAssets([fixture.ids[1]], reason: .trashed)
        XCTAssertNil(store.coverID(for: album))
        XCTAssertEqual(repository.requests, 1)
    }

    func testHeldCoverCannotPublishAfterLockAndUnlockAllowsAFreshResolution() async throws {
        let fixture = try fixture()
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        let gate = SecondaryResponseGate<[String]>()
        cleanup.append { gate.close() }
        repository.fetch = { try await gate.value() }
        let album = album()
        let load = Task { await store.resolveCover(for: album, repository: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        gate.complete([fixture.ids[0]])
        await load.value
        XCTAssertNil(store.coverID(for: album))

        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "timeline")
        repository.fetch = { [fixture] in [fixture.ids[1]] }
        await store.resolveCover(for: album, repository: repository)

        XCTAssertEqual(repository.requests, 2, "A discarded completed request must not block retry")
        XCTAssertEqual(store.coverID(for: album), fixture.ids[1])
    }

    func testHeldCoverDoesNotCacheARejectedPhotoAsAnEmptyAlbum() async throws {
        let fixture = try fixture()
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        let gate = SecondaryResponseGate<[String]>()
        cleanup.append { gate.close() }
        repository.fetch = { try await gate.value() }
        let album = album()
        let load = Task { await store.resolveCover(for: album, repository: repository) }
        await fulfillment(of: [gate.started], timeout: 2)

        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        gate.complete([fixture.ids[0]])
        await load.value
        XCTAssertNil(store.coverID(for: album))

        repository.fetch = { [fixture] in [fixture.ids[1]] }
        await store.resolveCover(for: album, repository: repository)

        XCTAssertTrue(fixture.manager.privateAssetIDs.contains(fixture.ids[0]))
        XCTAssertEqual(repository.requests, 2)
        XCTAssertEqual(store.coverID(for: album), fixture.ids[1])
    }

    func testHeldEmptyCoverDoesNotCacheAnObsoleteVisibilityContext() async throws {
        let fixture = try fixture()
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        let gate = SecondaryResponseGate<[String]>()
        cleanup.append { gate.close() }
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "locked")
        repository.fetch = { try await gate.value() }
        let album = album()
        let load = Task { await store.resolveCover(for: album, repository: repository) }
        await fulfillment(of: [gate.started], timeout: 2)

        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "timeline")
        gate.complete([])
        await load.value

        repository.fetch = { [fixture] in [fixture.ids[0]] }
        await store.resolveCover(for: album, repository: repository)

        XCTAssertEqual(repository.requests, 2)
        XCTAssertEqual(store.coverID(for: album), fixture.ids[0])
    }

    func testEmptyCoverIsCachedUntilCountChangesAndVisibleArchiveCanBeFetched() async throws {
        let fixture = try fixture()
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        var album = album()
        await store.resolveCover(for: album, repository: repository)
        await store.resolveCover(for: album, repository: repository)
        XCTAssertNil(store.coverID(for: album))
        XCTAssertEqual(repository.requests, 1)

        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "archive")
        album.assetCount += 1
        repository.fetch = { [fixture] in [fixture.ids[0]] }
        await store.resolveCover(for: album, repository: repository)
        XCTAssertEqual(store.coverID(for: album), fixture.ids[0])
        await store.resolveCover(for: album, repository: repository)
        XCTAssertEqual(repository.requests, 2)
    }

    func testCoverCanPublishItsOwnFreshArchiveAdmissionWithoutAnotherRequest() async throws {
        let fixture = try fixture()
        let id = fixture.ids[0]
        try fixture.manager.setTimelineVisibility([id], inTimeline: false)
        XCTAssertTrue(fixture.manager.privateAssetIDs.contains(id))
        let store = AlbumCoverStore(dataManager: fixture.manager)
        let repository = SecondaryCoverRepository(api: fixture.api)
        repository.fetch = {
            var archive = makeTestAsset(id: id, isArchived: true)
            archive.visibility = "archive"
            try fixture.manager.recordServerVisibility([archive])
            return [id]
        }
        let album = album()

        await store.resolveCover(for: album, repository: repository)

        XCTAssertEqual(repository.requests, 1)
        XCTAssertTrue(fixture.manager.archivedAssetIDs.contains(id))
        XCTAssertFalse(fixture.manager.privateAssetIDs.contains(id))
        XCTAssertEqual(store.coverID(for: album), id,
            "A cover response must not reject the visibility evidence it admitted itself")
    }

    func testMemoryLibraryAndSearchDiscardPreparedFilesAfterAPhotoBecomesPrivate() async throws {
        for screen in SharingScreen.allCases {
            let fixture = try fixture()
            let firstInput = fixture.directory.appendingPathComponent("allowed.jpg")
            let rejectedInput = fixture.directory.appendingPathComponent("rejected.jpg")
            let bytes = Data([0, 1, 2, 255])
            try bytes.write(to: firstInput)
            try bytes.write(to: rejectedInput)
            let first = try TemporaryMediaStore.adoptShareFile(at: firstInput, suggestedFilename: "allowed.jpg")
            defer { TemporaryMediaStore.remove(first) }
            let rejected = try TemporaryMediaStore.adoptShareFile(at: rejectedInput, suggestedFilename: "rejected.jpg")
            defer { TemporaryMediaStore.remove(rejected) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstInput.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedInput.path))
            let repository = SecondaryPreparedShareRepository(api: fixture.api, file: first)
            let share = share(screen, fixture: fixture, repository: repository)
            let asset = AssetLite(makeTestAsset(id: fixture.ids[0]))
            let accepted = await share(asset)
            XCTAssertEqual(accepted, first)
            XCTAssertEqual(try Data(contentsOf: first), bytes)
            repository.file = rejected
            repository.onPrepared = {
                XCTAssertTrue(FileManager.default.fileExists(atPath: rejected.path))
                try fixture.manager.setAssetVisibility([asset.id], to: "locked")
            }

            let result = await share(asset)

            XCTAssertNil(result, "Screen: \(screen)")
            XCTAssertEqual(repository.requests, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
            XCTAssertEqual(try Data(contentsOf: first), bytes, "Cleanup must leave the earlier accepted share intact")
            let blocked = await share(asset)
            XCTAssertNil(blocked)
            XCTAssertEqual(repository.requests, 2, "Already private photos cannot start another download")
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("secondary-privacy-\(UUID())")
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE")) }
        return Fixture(directory: directory, manager: manager, api: SecondaryScreenAPI(), ids: ids)
    }

    private func library(_ fixture: Fixture, assetRepository: AssetDetailRepository? = nil) -> LibraryViewModel {
        LibraryViewModel(memoriesRepo: MemoriesRepository(api: fixture.api), albumRepo: AlbumRepository(api: fixture.api),
            peopleRepo: PeopleRepository(api: fixture.api), searchRepo: SearchRepository(api: fixture.api),
            assetRepo: assetRepository ?? AssetDetailRepository(api: fixture.api), dataManager: fixture.manager)
    }

    private func share(_ screen: SharingScreen, fixture: Fixture,
                       repository: AssetDetailRepository) -> (AssetLite) async -> URL? {
        switch screen {
        case .memories:
            let model = MemoriesViewModel(repo: MemoriesRepository(api: fixture.api),
                assetRepo: repository, dataManager: fixture.manager)
            return { await model.shareURL(for: $0) }
        case .library:
            let model = library(fixture, assetRepository: repository)
            return { await model.shareURL(for: $0) }
        case .search:
            let model = SearchViewModel(repo: SearchRepository(api: fixture.api), assetRepo: repository,
                albumRepo: AlbumRepository(api: fixture.api), dataManager: fixture.manager)
            return { await model.shareURLs(for: [$0.id]).first }
        }
    }

    private func album(cover: String? = nil) -> AlbumResponseDTO {
        AlbumResponseDTO(id: UUID().uuidString, albumName: "Album", description: nil, assetCount: 2,
            albumThumbnailAssetId: cover, shared: false, createdAt: .now, assets: nil)
    }

    private func marker(_ id: String, latitude: Double) -> MapMarkerDTO {
        MapMarkerDTO(id: id, lat: latitude, lon: 45, city: nil, state: nil, country: nil)
    }

    private func memory(ids: [String]) throws -> MemoryDTO {
        var components = Calendar.current.dateComponents([.month, .day], from: Date())
        components.year = 2020
        components.timeZone = .gmt
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        return MemoryDTO(id: UUID().uuidString, type: "on_this_day", memoryAt: date,
            assets: ids.map { makeTestAsset(id: $0) }, data: nil)
    }

    private enum SharingScreen: CaseIterable { case memories, library, search }
    private struct Fixture {
        let directory: URL
        let manager: SwiftDataManager
        let api: SecondaryScreenAPI
        let ids: [String]
    }
}

@MainActor
private final class SecondaryScreenAPI: APIClient {
    var memories: () async throws -> [MemoryDTO] = { throw APIError.notConnected }
    var favorites: () async throws -> SearchResponseDTO = { throw APIError.notConnected }
    var mutate: ((Endpoint) throws -> Void)?
    init() { super.init(session: MockSessionManager()) }
    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        if endpoint.path == "/search/metadata" {
            let result = try await favorites()
            return try XCTUnwrap(result as? T)
        }
        guard endpoint.path == "/memories" else { throw APIError.notConnected }
        let result = try await memories()
        return try XCTUnwrap(result as? T)
    }
    override func sendVoid(_ endpoint: Endpoint) async throws {
        guard let mutate else { throw APIError.notConnected }
        try mutate(endpoint)
    }
}

@MainActor
private final class SecondaryCoverRepository: AlbumRepository {
    var fetch: () async throws -> [String] = { [] }
    private(set) var requests = 0
    override func recentAssetIDs(in albumID: String, limit: Int, includeArchived: Bool = true) async throws -> [String] {
        requests += 1
        XCTAssertTrue(includeArchived)
        return try await fetch()
    }
}

@MainActor
private final class SecondaryResponseGate<Value> {
    let started = XCTestExpectation(description: "Response is held")
    private var continuation: CheckedContinuation<Value, Error>?
    private var closed = false
    func value() async throws -> Value {
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func complete(_ value: Value) {
        guard let continuation else { return XCTFail("Response did not reach the held boundary") }
        self.continuation = nil
        continuation.resume(returning: value)
    }
    func close() {
        closed = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private final class SecondaryPreparedShareRepository: AssetDetailRepository {
    var file: URL
    var onPrepared: (@MainActor () throws -> Void)?
    private(set) var requests = 0
    @MainActor
    init(api: APIClient, file: URL) {
        self.file = file
        super.init(api: api)
    }
    override func shareFile(_ id: String) async throws -> URL {
        try await MainActor.run {
            requests += 1
            try onPrepared?()
            return file
        }
    }
    @MainActor
    override func shareFiles(_ ids: [String]) async -> [URL] {
        guard let id = ids.first else { return [] }
        do { return [try await shareFile(id)] }
        catch { XCTFail("Prepared share fixture failed: \(error)"); return [] }
    }
}
