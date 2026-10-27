import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class AssetSnapshotPublicationTests: XCTestCase {
    private var snapshotKeys: Set<String> = []

    override func tearDown() async throws {
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        try await super.tearDown()
    }

    func testCollectionRefreshPublishesNewContentEvenIfAnotherInstanceSavedIt() async {
        let key = snapshotKey()
        let old = asset("A")
        var updated = old
        updated.isFavorite = true
        var response = [old]
        let first = grid(key: key) { response }
        await first.load()
        let second = grid(key: key) { [updated] }
        await second.load()
        XCTAssertFalse(LocalSnapshot.save([updated], for: key), "The response is already on disk")
        XCTAssertFalse(first.assets[0].isFavorite)
        let changed = observeAssets(first)

        response = [updated]
        await first.load()
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(first.assets.map(\.id), ["A"])
        XCTAssertTrue(first.assets[0].isFavorite)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.first?.isFavorite, true)
    }

    func testIdenticalCollectionResponseDoesNotPublishAssetsAgain() async {
        let item = asset("A")
        let model = grid(key: snapshotKey()) { [item] }
        await model.load()
        let changed = observeAssets(model)
        changed.isInverted = true

        await model.load()

        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertTrue(model.assets[0].hasSameContent(as: item))
    }

    func testCollectionFailureKeepsLoadedContentAndSnapshot() async {
        let key = snapshotKey()
        let item = asset("A")
        var shouldFail = false
        let model = grid(key: key) {
            if shouldFail { throw APIError.unknown }
            return [item]
        }
        await model.load()
        let changed = observeAssets(model)
        changed.isInverted = true
        shouldFail = true

        await model.load()

        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertTrue(model.assets[0].hasSameContent(as: item))
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["A"])
        assertLoaded(model.phase)
    }

    func testAlbumRefreshPublishesSameIDMetadataAfterAnotherInstanceSavedIt() async {
        let albumID = UUID().uuidString
        let key = LocalSnapshot.Key.album(albumID)
        snapshotKeys.insert(key)
        let old = asset("A")
        let updated = AssetLite(id: "A", isVideo: false, ratio: 2, thumbhash: "new-hash",
            createdAt: old.createdAt.addingTimeInterval(86_400), isFavorite: true)
        let firstRepo = PublicationTimelineRepository(api: makeStubAPIClient())
        firstRepo.items = [old]
        let first = album(repo: firstRepo)
        await first.loadAlbumDetail(albumID)
        let secondRepo = PublicationTimelineRepository(api: makeStubAPIClient())
        secondRepo.items = [updated]
        await album(repo: secondRepo).loadAlbumDetail(albumID)
        XCTAssertFalse(LocalSnapshot.save([updated], for: key))
        let changed = expectation(description: "Album metadata is observable")
        withObservationTracking { _ = first.assets } onChange: { changed.fulfill() }
        firstRepo.items = [updated]

        await first.loadAlbumDetail(albumID)
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(firstRepo.requestedIDs, [albumID, albumID])
        XCTAssertTrue(first.assets[0].hasSameContent(as: updated))
        XCTAssertEqual(first.assets[0].ratio, 2)
        XCTAssertEqual(first.assets[0].thumbhash, "new-hash")
    }

    func testAlbumRefreshToEmptyPublishesAndFailureKeepsThatEmptyAnswer() async {
        let albumID = UUID().uuidString
        let key = LocalSnapshot.Key.album(albumID)
        snapshotKeys.insert(key)
        let repo = PublicationTimelineRepository(api: makeStubAPIClient())
        repo.items = [asset("A")]
        let model = album(repo: repo)
        await model.loadAlbumDetail(albumID)
        let cleared = expectation(description: "An authoritative empty album is observable")
        withObservationTracking { _ = model.assets } onChange: { cleared.fulfill() }
        repo.items = []

        await model.loadAlbumDetail(albumID)
        await fulfillment(of: [cleared], timeout: 1)
        repo.shouldFail = true
        await model.loadAlbumDetail(albumID)

        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.count, 0)
        assertLoaded(model.phase)
    }

    func testIdenticalAlbumResponseDoesNotPublishAgain() async {
        let albumID = UUID().uuidString
        snapshotKeys.insert(LocalSnapshot.Key.album(albumID))
        let repo = PublicationTimelineRepository(api: makeStubAPIClient())
        repo.items = [asset("A")]
        let model = album(repo: repo)
        await model.loadAlbumDetail(albumID)
        let changed = expectation(description: "Identical album response")
        changed.isInverted = true
        withObservationTracking { _ = model.assets } onChange: { changed.fulfill() }

        await model.loadAlbumDetail(albumID)

        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertEqual(repo.requestedIDs.count, 2)
    }

    func testLibraryFavoritesPublishSameIDContentAfterAnotherInstanceSavedIt() async {
        let key = LocalSnapshot.Key.libraryFavorites
        snapshotKeys.insert(key)
        LocalSnapshot.remove(key)
        let old = favorite(hash: "old")
        let updated = favorite(hash: "new")
        let firstRepo = PublicationSearchRepository(api: makeStubAPIClient())
        firstRepo.items = [old]
        let first = library(repo: firstRepo)
        await first.load()
        let secondRepo = PublicationSearchRepository(api: makeStubAPIClient())
        secondRepo.items = [updated]
        await library(repo: secondRepo).load()
        XCTAssertFalse(LocalSnapshot.save([AssetLite(updated)], for: key))
        XCTAssertEqual(first.favorites.first?.thumbhash, "old")
        let changed = expectation(description: "Library favorite metadata is observable")
        withObservationTracking { _ = first.favorites } onChange: { changed.fulfill() }
        firstRepo.items = [updated]

        await first.load()
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(first.favorites.map(\.id), [old.id])
        XCTAssertEqual(first.favorites[0].thumbhash, "new")
        XCTAssertEqual(firstRepo.requests.map(\.isFavorite), [true, true])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.first?.thumbhash, "new")
    }

    func testLibraryFavoriteFailureRetainsLoadedContent() async {
        let key = LocalSnapshot.Key.libraryFavorites
        snapshotKeys.insert(key)
        LocalSnapshot.remove(key)
        let repo = PublicationSearchRepository(api: makeStubAPIClient())
        repo.items = [favorite(hash: "retained")]
        let model = library(repo: repo)
        await model.load()
        let changed = expectation(description: "Failed favorites request must not publish empty data")
        changed.isInverted = true
        withObservationTracking { _ = model.favorites } onChange: { changed.fulfill() }
        repo.shouldFail = true

        await model.load()

        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertEqual(model.favorites.first?.thumbhash, "retained")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.first?.thumbhash, "retained")
        XCTAssertTrue(model.hasLoaded)
    }

    func testCommittedDetailMutationRefreshesLibraryFavoriteMembership() async throws {
        let key = LocalSnapshot.Key.libraryFavorites
        snapshotKeys.insert(key)
        LocalSnapshot.remove(key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let item = favorite(hash: "before")
        try manager.insertOrUpdateCachedAsset(CachedAsset(id: item.id, assetId: item.id,
            type: "IMAGE", isFavorite: true, createdAt: item.fileCreatedAt))
        let favoritesRepo = PublicationSearchRepository(api: makeStubAPIClient())
        favoritesRepo.items = [item]
        let model = library(repo: favoritesRepo)
        await model.load()
        XCTAssertEqual(model.favorites.map(\.id), [item.id])

        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let session = MockSessionManager()
        try session.setServer("https://favorite-refresh.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let repository = AssetDetailRepository(api: APIClient(session: session,
            urlSession: URLSession(configuration: configuration)), dataManager: manager)
        MockURLProtocol.mockResponse = HTTPURLResponse(url: URL(string: "https://favorite-refresh.example/api")!,
            statusCode: 204, httpVersion: nil, headerFields: nil)
        MockURLProtocol.mockData = Data()
        favoritesRepo.items = []
        let refreshed = expectation(description: "Committed mutation refreshes the favorite row")
        withObservationTracking { _ = manager.assetMutationRevision } onChange: {
            Task { @MainActor in
                await model.refreshFavorites()
                refreshed.fulfill()
            }
        }

        try await repository.toggleFavorite(item.id, to: false)
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(manager.getCachedAsset(id: item.id)?.isFavorite, false)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.count, 0)
        XCTAssertEqual(favoritesRepo.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/assets/\(item.id)")
    }

    func testOlderFullLoadCannotOverwriteNewerFavoriteRefresh() async {
        let key = LocalSnapshot.Key.libraryFavorites
        snapshotKeys.insert(key)
        LocalSnapshot.remove(key)
        let repo = PublicationSearchRepository(api: makeStubAPIClient())
        repo.items = [favorite(hash: "initial")]
        let model = library(repo: repo)
        await model.load()
        let held = HeldFavoriteResponse()
        let oldPage = page([favorite(hash: "obsolete")])
        let newPage = page([favorite(hash: "latest")])
        var requests = 0
        repo.response = { _ in
            requests += 1
            return requests == 1 ? await held.value() : newPage
        }
        let oldLoad = Task { await model.load() }
        await fulfillment(of: [held.started], timeout: 2)

        await model.refreshFavorites()
        XCTAssertEqual(model.favorites.first?.thumbhash, "latest")
        held.resolve(oldPage)
        await oldLoad.value

        XCTAssertEqual(model.favorites.first?.thumbhash, "latest")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.first?.thumbhash, "latest")
        XCTAssertEqual(requests, 2)
    }

    func testAcceptedUnfavoriteCannotBeUndoneByAnOlderFavoriteRead() async {
        let key = LocalSnapshot.Key.libraryFavorites
        snapshotKeys.insert(key)
        LocalSnapshot.remove(key)
        let item = favorite(hash: "initial")
        let repo = PublicationSearchRepository(api: makeStubAPIClient())
        repo.items = [item]
        let mutations = PublicationAssetRepository(api: makeStubAPIClient())
        let model = library(repo: repo, assetRepo: mutations)
        await model.load()
        let held = HeldFavoriteResponse()
        repo.response = { _ in await held.value() }
        let oldRead = Task { await model.refreshFavorites() }
        await fulfillment(of: [held.started], timeout: 2)

        await model.toggleFavorite(AssetLite(item))
        XCTAssertTrue(model.favorites.isEmpty)
        held.resolve(page([item]))
        await oldRead.value

        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.count, 0)
        XCTAssertEqual(mutations.favorites.map(\.id), [item.id])
        XCTAssertEqual(mutations.favorites.map(\.value), [false])
        repo.response = nil
        repo.items = [favorite(hash: "later-server-change")]
        await model.refreshFavorites()
        XCTAssertEqual(model.favorites.first?.thumbhash, "later-server-change",
            "A new read still admits a later server change after the local action")
    }

    private func snapshotKey() -> String {
        let key = "publication-\(UUID())"
        snapshotKeys.insert(key)
        return key
    }

    private func asset(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func favorite(hash: String) -> AssetResponseDTO {
        AssetResponseDTO(id: "publication-favorite", type: "IMAGE", originalFileName: "photo.jpg",
            fileCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), isFavorite: true,
            isArchived: false, isTrashed: false, duration: nil, thumbhash: hash,
            localDateTime: Date(timeIntervalSince1970: 1_700_000_000), exifInfo: nil, people: nil)
    }

    private func grid(key: String, loader: @escaping () async throws -> [AssetLite]) -> AssetGridViewModel {
        AssetGridViewModel(assetRepo: AssetDetailRepository(api: makeStubAPIClient()),
            albumRepo: AlbumRepository(api: makeStubAPIClient()), snapshotKey: key, loader: loader)
    }

    private func album(repo: TimelineRepository) -> AlbumDetailViewModel {
        AlbumDetailViewModel(timelineRepo: repo, albumRepo: AlbumRepository(api: makeStubAPIClient()),
            assetRepo: AssetDetailRepository(api: makeStubAPIClient()))
    }

    private func library(repo: SearchRepository, assetRepo: AssetDetailRepository? = nil) -> LibraryViewModel {
        LibraryViewModel(memoriesRepo: PublicationMemoriesRepository(api: makeStubAPIClient()),
            albumRepo: PublicationAlbumRepository(api: makeStubAPIClient()),
            peopleRepo: PublicationPeopleRepository(api: makeStubAPIClient()), searchRepo: repo,
            assetRepo: assetRepo ?? AssetDetailRepository(api: makeStubAPIClient()))
    }

    private func page(_ items: [AssetResponseDTO]) -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: items, total: items.count, nextPage: nil))
    }

    private func observeAssets(_ model: AssetGridViewModel) -> XCTestExpectation {
        let changed = expectation(description: "Collection assets are observable")
        withObservationTracking { _ = model.assets } onChange: { changed.fulfill() }
        return changed
    }

    private func assertLoaded(_ phase: LoadingPhase<Void>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = phase else { return XCTFail("Expected loaded phase", file: file, line: line) }
    }
}

private final class PublicationTimelineRepository: TimelineRepository {
    var items: [AssetLite] = []
    var shouldFail = false
    private(set) var requestedIDs: [String] = []

    override func albumAssets(_ albumId: String, expectedCount: Int? = nil) async throws -> [AssetLite] {
        requestedIDs.append(albumId)
        if shouldFail { throw APIError.unknown }
        return items
    }
}

private final class PublicationSearchRepository: SearchRepository {
    var items: [AssetResponseDTO] = []
    var shouldFail = false
    private(set) var requests: [SearchRequestDTO] = []
    var response: (@MainActor (SearchRequestDTO) async throws -> SearchResponseDTO)?

    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        requests.append(request)
        if let response { return try await response(request) }
        if shouldFail { throw APIError.unknown }
        return SearchResponseDTO(assets: .init(items: items, total: items.count, nextPage: nil))
    }
}

private final class PublicationAssetRepository: AssetDetailRepository {
    private(set) var favorites: [(id: String, value: Bool)] = []
    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        favorites.append((id, value))
    }
}

@MainActor
private final class HeldFavoriteResponse {
    let started = XCTestExpectation(description: "Favorite response is held")
    private var continuation: CheckedContinuation<SearchResponseDTO, Never>?

    func value() async -> SearchResponseDTO {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resolve(_ response: SearchResponseDTO) {
        precondition(continuation != nil)
        continuation?.resume(returning: response)
        continuation = nil
    }
}

private final class PublicationMemoriesRepository: MemoriesRepository {
    override func getMemories() async throws -> [MemoryDTO] { throw APIError.unknown }
}

private final class PublicationAlbumRepository: AlbumRepository {
    override func all() async throws -> [AlbumResponseDTO] { throw APIError.unknown }
}

private final class PublicationPeopleRepository: PeopleRepository {
    override func all(size: Int? = nil) async throws -> [PersonDTO] { throw APIError.unknown }
}
