import XCTest
@testable import ImmichApp

@MainActor
final class SearchMutationResultsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testArchiveFailureKeepsFailedAndUnattemptedResultsAndTheirCount() async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture()
            fixture.assets.failureID = fixture.ids[failureIndex]

            let succeeded = await fixture.model.archive(fixture.ids)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(fixture.assets.requests, Array(fixture.ids.prefix(failureIndex + 1)))
            XCTAssertEqual(fixture.model.results.map(\.id), Array(fixture.ids.dropFirst(failureIndex)))
            XCTAssertEqual(fixture.model.totalResults, 3 - failureIndex)
            XCTAssertEqual(fixture.model.actionError, "Rejected \(fixture.ids[failureIndex])")
            for (index, id) in fixture.ids.enumerated() {
                XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isArchived, index < failureIndex)
            }
            assertLoaded(fixture.model)
        }
    }

    func testFavoriteFailureKeepsOnlyConfirmedChangesInResultsAndStore() async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture()
            fixture.assets.failureID = fixture.ids[failureIndex]

            let succeeded = await fixture.model.setFavorite(fixture.ids, to: true)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(fixture.assets.requests, Array(fixture.ids.prefix(failureIndex + 1)))
            XCTAssertEqual(fixture.model.results.map(\.id), fixture.ids)
            XCTAssertEqual(fixture.model.results.filter(\.isFavorite).map(\.id), Array(fixture.ids.prefix(failureIndex)))
            XCTAssertEqual(fixture.model.totalResults, 3)
            for (index, id) in fixture.ids.enumerated() {
                XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, index < failureIndex)
            }
            XCTAssertNotNil(fixture.model.actionError)
            assertLoaded(fixture.model)
        }
    }

    func testArchiveRetryFinishesRemainingItemsAndClearsPreviousFailure() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = fixture.ids[1]
        let failed = await fixture.model.archive(fixture.ids)
        XCTAssertFalse(failed)
        XCTAssertNotNil(fixture.model.actionError)
        fixture.assets.failureID = nil

        let succeeded = await fixture.model.archive(fixture.model.results.map(\.id))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fixture.assets.requests, [fixture.ids[0], fixture.ids[1], fixture.ids[1], fixture.ids[2]])
        XCTAssertTrue(fixture.model.results.isEmpty)
        XCTAssertEqual(fixture.model.totalResults, 0)
        XCTAssertNil(fixture.model.actionError)
        let reopened = SwiftDataManager(storeURL: fixture.store, backupJournalURL: fixture.journal)
        XCTAssertTrue(reopened.timelineAssets().isEmpty)
        assertLoaded(fixture.model)
    }

    func testSuccessfulFavoriteCanBeReversedWithoutChangingResultCount() async throws {
        let fixture = try await fixture()
        fixture.model.actionError = "Old failure"
        let favorited = await fixture.model.setFavorite(fixture.ids, to: true)
        XCTAssertTrue(favorited)
        XCTAssertEqual(fixture.model.results.filter(\.isFavorite).map(\.id), fixture.ids)
        XCTAssertNil(fixture.model.actionError)

        let unfavorited = await fixture.model.setFavorite(fixture.ids, to: false)

        XCTAssertTrue(unfavorited)
        XCTAssertTrue(fixture.model.results.allSatisfy { !$0.isFavorite })
        XCTAssertEqual(fixture.model.totalResults, 3)
        let reopened = SwiftDataManager(storeURL: fixture.store, backupJournalURL: fixture.journal)
        XCTAssertTrue(reopened.timelineAssets().allSatisfy { !$0.asset.isFavorite })
        XCTAssertEqual(reopened.timelineAssets().count, 3)
    }

    func testDeleteFailureLeavesLoadedResultsAvailableAndRetryClearsError() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = fixture.ids[0]
        let failed = await fixture.model.delete(fixture.ids)
        XCTAssertFalse(failed)
        XCTAssertEqual(fixture.model.results.map(\.id), fixture.ids)
        XCTAssertEqual(fixture.model.totalResults, 3)
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
        fixture.assets.failureID = nil

        let succeeded = await fixture.model.delete(fixture.ids)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(fixture.model.results.isEmpty)
        XCTAssertEqual(fixture.model.totalResults, 0)
        XCTAssertNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testAlbumAddReportsFailureAndTreatsDuplicatesAsCompletedWithoutHidingSearch() async throws {
        let fixture = try await fixture()
        let album = AlbumResponseDTO(
            id: "album", albumName: "Album", description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: Date(), assets: nil)
        fixture.albums.failure = AlbumMutationError(succeededIDs: ["a"], duplicateIDs: [], failedIDs: ["b"])
        let rejected = await fixture.model.addToAlbum(["a", "b"], album: album)
        XCTAssertFalse(rejected)
        XCTAssertNotNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.results.map(\.id), fixture.ids)
        assertLoaded(fixture.model)

        fixture.albums.failure = nil
        fixture.albums.duplicates = ["a"]
        let duplicate = await fixture.model.addToAlbum(["a"], album: album)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(fixture.model.actionError, String(localized: "Already in this album"))
        fixture.albums.duplicates = []
        let accepted = await fixture.model.addToAlbum(["b"], album: album)
        XCTAssertTrue(accepted)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.albums.requests, [["a", "b"], ["a"], ["b"]])
    }

    private func assertLoaded(_ model: SearchViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = model.phase else {
            return XCTFail("Action failures must not replace loaded results", file: file, line: line)
        }
    }

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchMutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = directory.appendingPathComponent("cache.sqlite")
        let journal = directory.appendingPathComponent("backup.json")
        let manager = SwiftDataManager(storeURL: store, backupJournalURL: journal)
        let ids = ["a", "b", "c"]
        let values = ids.map { makeTestAsset(id: $0) }
        try manager.restoreToTimeline(values.map(AssetLite.init))
        let api = makeStubAPIClient()
        let assets = SearchMutationAssetRepository(api: api)
        let albums = SearchMutationAlbumRepository(api: api)
        let search = SearchMutationRepository(api: api, values: values)
        let model = SearchViewModel(
            repo: search, assetRepo: assets, albumRepo: albums, dataManager: manager)
        model.searchText = "photos"
        await model.search()
        XCTAssertEqual(model.results.map(\.id), ids)
        XCTAssertEqual(model.totalResults, 3)
        XCTAssertEqual(manager.timelineAssets().count, 3)
        return Fixture(model: model, assets: assets, albums: albums, manager: manager, ids: ids, store: store, journal: journal)
    }

    private struct Fixture {
        let model: SearchViewModel
        let assets: SearchMutationAssetRepository
        let albums: SearchMutationAlbumRepository
        let manager: SwiftDataManager
        let ids: [String]
        let store: URL
        let journal: URL
    }
}

private final class SearchMutationAlbumRepository: AlbumRepository {
    var failure: Error?
    var duplicates: [String] = []
    var requests: [[String]] = []

    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        requests.append(ids)
        if let failure { throw failure }
        return duplicates
    }
}

private final class SearchMutationRepository: SearchRepository {
    let values: [AssetResponseDTO]

    init(api: APIClient, values: [AssetResponseDTO]) {
        self.values = values
        super.init(api: api)
    }

    override func smartSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: values, total: values.count, nextPage: nil))
    }
}

private final class SearchMutationAssetRepository: AssetDetailRepository {
    var failureID: String?
    var requests: [String] = []

    override func setVisibility(_ id: String, to visibility: Visibility) async throws {
        try record(id)
    }

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        try record(id)
    }

    override func delete(_ ids: [String], force: Bool = false) async throws {
        requests.append(contentsOf: ids)
        if let failureID, ids.contains(failureID) {
            throw APIError.server(status: 403, message: "Rejected \(failureID)")
        }
    }

    private func record(_ id: String) throws {
        requests.append(id)
        if failureID == id { throw APIError.server(status: 403, message: "Rejected \(id)") }
    }
}
