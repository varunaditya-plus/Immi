import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class SearchExternalRemovalTests: XCTestCase {
    private var directories: [URL] = []
    private var repositories: [ControlledSearchRepository] = []

    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        for repository in repositories { await repository.probe.cancelAll() }
        repositories.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testLoadedResultsObserveExternalRemovalAndRestoreWithoutAnotherSearch() async throws {
        let fixture = try fixture()
        let removed = fixture.ids[0], kept = fixture.ids[1]
        try await load(fixture, ids: [removed, kept], total: 2)
        let changed = expectation(description: "Search observes a deletion from another screen")
        withObservationTracking {
            _ = fixture.model.results
            _ = fixture.model.totalResults
        } onChange: { changed.fulfill() }

        try fixture.manager.purgeAssets([removed], reason: .trashed)

        XCTAssertEqual(fixture.model.results.map(\.id), [kept])
        XCTAssertEqual(fixture.model.totalResults, 1)
        await fulfillment(of: [changed], timeout: 2)
        RemovedAssets.shared.restore([removed])
        XCTAssertEqual(fixture.model.results.map(\.id), [removed, kept])
        XCTAssertEqual(fixture.model.totalResults, 2)

        // A later detail callback must not count the same external removal twice.
        try fixture.manager.purgeAssets([removed], reason: .trashed)
        fixture.model.removeLocally([removed])
        XCTAssertEqual(fixture.model.results.map(\.id), [kept])
        XCTAssertEqual(fixture.model.totalResults, 1)
        let requests = await fixture.repository.probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPendingInitialResponseCannotDisplayAnExternallyRemovedPhoto() async throws {
        for durableOnly in [false, true] {
            let fixture = try fixture()
            let removed = fixture.ids[0], kept = fixture.ids[1]
            let search = Task { await fixture.model.search() }
            _ = try await fixture.repository.probe.waitForRequest(0, testCase: self)

            if durableOnly {
                DeletedServerAssetRegistry.shared.record([removed], permanently: false)
                RemovedAssets.shared.clear()
            } else {
                try fixture.manager.purgeAssets([removed], reason: .trashed)
            }
            try await fixture.repository.probe.succeed(0, ids: [removed, kept], total: 2)
            await search.value

            XCTAssertEqual(fixture.model.results.map(\.id), [kept])
            XCTAssertEqual(fixture.model.totalResults, 1)
            XCTAssertNil(fixture.model.nextPage)
            if case .loaded = fixture.model.phase {} else { XCTFail("Current search must still finish") }
        }
    }

    func testPendingPageKeepsValidRowsButCannotRestoreExternalDeletions() async throws {
        let fixture = try fixture()
        let removed = fixture.ids[0], kept = fixture.ids[1]
        let notLoaded = fixture.ids[2], added = fixture.ids[3]
        try await load(fixture, ids: [removed, kept], total: 4, nextPage: "2")
        let page = Task { await fixture.model.loadMore() }
        _ = try await fixture.repository.probe.waitForRequest(1, testCase: self)
        fixture.model.patchFavorite(kept, to: true)

        try fixture.manager.purgeAssets([removed, notLoaded], reason: .trashed)
        XCTAssertEqual(fixture.model.results.map(\.id), [kept])
        XCTAssertEqual(fixture.model.totalResults, 3,
                       "Only already loaded rows can adjust an unfinished server total")
        try await fixture.repository.probe.succeed(1, ids: [removed, kept, notLoaded, added], total: 4)
        await page.value

        XCTAssertEqual(fixture.model.results.map(\.id), [kept, added])
        XCTAssertEqual(fixture.model.results.first?.isFavorite, true)
        XCTAssertEqual(fixture.model.totalResults, 2)
        XCTAssertEqual(fixture.model.currentPage, 2)
        XCTAssertNil(fixture.model.nextPage)
        XCTAssertNil(fixture.model.paginationError)
        XCTAssertFalse(fixture.model.isLoadingMore)
        let requests = await fixture.repository.probe.requests
        XCTAssertEqual(requests.count, 2)
    }

    private func load(_ fixture: Fixture, ids: [String], total: Int, nextPage: String? = nil) async throws {
        let search = Task { await fixture.model.search() }
        _ = try await fixture.repository.probe.waitForRequest(0, testCase: self)
        try await fixture.repository.probe.succeed(0, ids: ids, total: total, nextPage: nextPage)
        await search.value
        XCTAssertEqual(fixture.model.results.map(\.id), ids)
        XCTAssertEqual(fixture.model.totalResults, total)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-removal-\(UUID())")
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids {
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE"))
        }
        let api = APIClient(session: MockSessionManager())
        let repository = ControlledSearchRepository(api: api)
        repositories.append(repository)
        let model = SearchViewModel(repo: repository, assetRepo: AssetDetailRepository(api: api),
                                    albumRepo: AlbumRepository(api: api), dataManager: manager)
        model.searchText = "mountains"
        return Fixture(manager: manager, repository: repository, model: model, ids: ids)
    }

    private struct Fixture {
        let manager: SwiftDataManager
        let repository: ControlledSearchRepository
        let model: SearchViewModel
        let ids: [String]
    }
}
