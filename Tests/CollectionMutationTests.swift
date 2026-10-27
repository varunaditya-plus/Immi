import Foundation
import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionMutationTests: XCTestCase {
    private var directories: [URL] = []
    private var snapshotKeys: [String] = []

    override func tearDown() async throws {
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        snapshotKeys.removeAll()
        directories.removeAll()
        try await super.tearDown()
    }

    func testUnfavoriteRetainsOnlyRejectedPhotosAndAttemptsTheRemainingRequests() async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture(favorite: true)
            let failedID = fixture.ids[failureIndex]
            fixture.repository.failedIDs = [failedID]

            await fixture.model.unfavorite(fixture.ids)

            XCTAssertEqual(fixture.repository.requests, fixture.ids)
            XCTAssertEqual(fixture.repository.favoriteValues, [false, false, false])
            XCTAssertEqual(fixture.model.assets.map(\.id), [failedID])
            XCTAssertEqual(fixture.model.assets.map(\.isFavorite), [true])
            let snapshot = try snapshot(fixture)
            XCTAssertEqual(snapshot.map(\.id), [failedID])
            XCTAssertEqual(snapshot.map(\.isFavorite), [true])
            for id in fixture.ids {
                XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, id == failedID)
            }
            XCTAssertEqual(fixture.model.actionError, "Rejected \(failedID)")
            assertLoaded(fixture.model)
        }
    }

    func testUnfavoriteAllFailuresKeepEveryPhotoAndTheFirstError() async throws {
        let fixture = try await fixture(favorite: true)
        fixture.repository.failedIDs = Set(fixture.ids)

        await fixture.model.unfavorite(fixture.ids)

        XCTAssertEqual(fixture.repository.requests, fixture.ids)
        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.ids)
        XCTAssertEqual(try snapshot(fixture).map(\.id), fixture.ids)
        XCTAssertEqual(fixture.model.actionError, "Rejected \(fixture.ids[0])")
        for id in fixture.ids { XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, true) }
        assertLoaded(fixture.model)
    }

    func testUnfavoritePublishesFailureOnlyAfterTheRemainingRequestsFinish() async throws {
        let fixture = try await fixture(favorite: true)
        fixture.repository.failedIDs = [fixture.ids[0]]
        var laterRequests = 0
        fixture.repository.onRequest = { id in
            guard id != fixture.ids[0] else { return }
            laterRequests += 1
            XCTAssertNil(fixture.model.actionError, "The error alert must wait until the entire action finishes")
        }
        defer { fixture.repository.onRequest = nil }

        await fixture.model.unfavorite(fixture.ids)

        XCTAssertEqual(laterRequests, 2)
        XCTAssertEqual(fixture.model.actionError, "Rejected \(fixture.ids[0])")
        XCTAssertEqual(fixture.model.assets.map(\.id), [fixture.ids[0]])
    }

    func testUnfavoriteRetryRemovesTheRemainingPhotoAndClearsTheError() async throws {
        let fixture = try await fixture(favorite: true)
        fixture.repository.failedIDs = [fixture.ids[1]]
        await fixture.model.unfavorite(fixture.ids)
        XCTAssertEqual(fixture.model.assets.map(\.id), [fixture.ids[1]])
        fixture.repository.failedIDs = []

        await fixture.model.unfavorite(fixture.model.assets.map(\.id))

        XCTAssertEqual(fixture.repository.requests, fixture.ids + [fixture.ids[1]])
        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertTrue(try snapshot(fixture).isEmpty)
        XCTAssertNil(fixture.model.actionError)
        for id in fixture.ids { XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, false) }
    }

    func testFavoritePartialFailurePersistsOnlyTheConfirmedPrefix() async throws {
        for value in [false, true] {
            for failureIndex in 0..<3 {
                let fixture = try await fixture(favorite: !value)
                fixture.repository.failedIDs = [fixture.ids[failureIndex]]

                let succeeded = await fixture.model.setFavorite(fixture.ids, to: value)

                XCTAssertFalse(succeeded)
                XCTAssertEqual(fixture.repository.requests, Array(fixture.ids.prefix(failureIndex + 1)))
                XCTAssertEqual(fixture.model.assets.map(\.id), fixture.ids)
                let expected = fixture.ids.indices.map { $0 < failureIndex ? value : !value }
                XCTAssertEqual(fixture.model.assets.map(\.isFavorite), expected)
                XCTAssertEqual(try snapshot(fixture).map(\.isFavorite), expected)
                for (index, id) in fixture.ids.enumerated() {
                    XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, expected[index])
                }
                XCTAssertEqual(fixture.model.actionError, "Rejected \(fixture.ids[failureIndex])")
                assertLoaded(fixture.model)
            }
        }
    }

    func testSuccessfulFavoritesAndSingleTogglePersistTheAcceptedValuesAndClearErrors() async throws {
        let fixture = try await fixture()
        fixture.model.actionError = "Older failure"
        let succeeded = await fixture.model.setFavorite(fixture.ids, to: true)
        XCTAssertTrue(succeeded)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(try snapshot(fixture).map(\.isFavorite), [true, true, true])
        let favorite = try XCTUnwrap(fixture.model.assets.first)
        fixture.repository.failedIDs = [favorite.id]

        await fixture.model.toggleFavorite(favorite)

        XCTAssertEqual(fixture.model.assets.map(\.isFavorite), [true, true, true])
        XCTAssertEqual(fixture.manager.getCachedAsset(id: favorite.id)?.isFavorite, true)
        XCTAssertEqual(fixture.model.actionError, "Rejected \(favorite.id)")
        fixture.repository.failedIDs = []
        await fixture.model.toggleFavorite(favorite)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.assets.map(\.isFavorite), [false, true, true])
        XCTAssertEqual(try snapshot(fixture).map(\.isFavorite), [false, true, true])
        XCTAssertEqual(fixture.manager.getCachedAsset(id: favorite.id)?.isFavorite, false)
        assertLoaded(fixture.model)
    }

    func testArchivePartialFailureRemovesOnlyTheConfirmedPrefix() async throws {
        try await assertVisibilityFailures(.archive)
    }

    func testUnlockPartialFailureRemovesOnlyTheConfirmedPrefix() async throws {
        try await assertVisibilityFailures(.unlock)
    }

    func testLockPartialFailureRemovesOnlyTheConfirmedPrefix() async throws {
        try await assertVisibilityFailures(.lock)
    }

    func testSuccessfulVisibilityActionsPersistEveryAcceptedChangeAndClearErrors() async throws {
        for action in CollectionVisibilityAction.allCases {
            let fixture = try await fixture(archived: action == .unlock)
            fixture.model.actionError = "Older failure"

            let succeeded = await perform(action, ids: fixture.ids, model: fixture.model)

            XCTAssertTrue(succeeded)
            XCTAssertEqual(fixture.repository.requests, fixture.ids)
            XCTAssertEqual(fixture.repository.visibilities, Array(repeating: action.visibility, count: 3))
            XCTAssertTrue(fixture.model.assets.isEmpty)
            XCTAssertTrue(try snapshot(fixture).isEmpty)
            XCTAssertNil(fixture.model.actionError)
            let reopened = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
            for id in fixture.ids { XCTAssertEqual(reopened.getCachedAsset(id: id)?.isArchived, action != .unlock) }
            assertLoaded(fixture.model)
        }
    }

    func testRejectedDeletePreservesTheLoadedCollectionAndRetryRemovesIt() async throws {
        let fixture = try await fixture()
        fixture.repository.deleteError = APIError.server(status: 403, message: "Cannot delete")

        await fixture.model.delete(fixture.ids, permanently: true)

        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.ids)
        XCTAssertEqual(try snapshot(fixture).map(\.id), fixture.ids)
        XCTAssertEqual(fixture.model.actionError, "Cannot delete")
        assertLoaded(fixture.model)
        fixture.repository.deleteError = nil
        await fixture.model.delete(fixture.ids, permanently: true)
        XCTAssertEqual(fixture.repository.deleteRequests.map(\.ids), [fixture.ids, fixture.ids])
        XCTAssertEqual(fixture.repository.deleteRequests.map(\.force), [true, true])
        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertTrue(try snapshot(fixture).isEmpty)
        XCTAssertNil(fixture.model.actionError)
    }

    func testTrashFailuresPreserveLoadedRowsAndExposeTheServerError() async throws {
        for action in CollectionTrashAction.allCases {
            let fixture = try await fixture()
            let client = CollectionTrashClient(session: MockSessionManager())
            let repo = TrashRepository(api: client)

            switch action {
            case .restore: await fixture.model.restore([fixture.ids[0]], using: repo)
            case .restoreAll: await fixture.model.restoreAll(using: repo)
            case .empty: await fixture.model.emptyTrash(using: repo)
            }

            XCTAssertEqual(client.requestPaths, [action.path])
            XCTAssertEqual(fixture.model.assets.map(\.id), fixture.ids)
            XCTAssertEqual(try snapshot(fixture).map(\.id), fixture.ids)
            XCTAssertEqual(fixture.model.actionError, "Trash request rejected")
            assertLoaded(fixture.model)
        }
    }

    func testActionFailureDoesNotReplaceTheEmptyCollectionsLoadedPhase() async throws {
        let fixture = try await fixture(empty: true)
        fixture.repository.deleteError = APIError.notConnected

        await fixture.model.delete(["unavailable-photo"])

        XCTAssertTrue(fixture.model.assets.isEmpty)
        XCTAssertEqual(fixture.model.actionError, APIError.notConnected.errorDescription)
        assertLoaded(fixture.model)
    }

    func testCollectionConvenienceInitializerForwardsTheLiveErrorBinding() async throws {
        let fixture = try await fixture()
        let screen = PhotoCollectionScreen(
            title: "Collection", assets: fixture.model.assets, phase: fixture.model.phase,
            actionError: Binding(get: { fixture.model.actionError }, set: { fixture.model.actionError = $0 }),
            onRetry: {}, onToggleFavorite: { _ in }, onDelete: { _ in }, shareURLs: { _ in [] })
        XCTAssertNil(screen.actionError.wrappedValue)
        fixture.repository.deleteError = APIError.server(status: 403, message: "Delete denied")

        await fixture.model.delete(fixture.ids)

        XCTAssertEqual(screen.actionError.wrappedValue, "Delete denied")
        screen.actionError.wrappedValue = nil
        XCTAssertNil(fixture.model.actionError)
    }

    func testEmptyBulkRequestsDoNotChangeRowsOrContactTheServer() async throws {
        let fixture = try await fixture()
        let favorite = await fixture.model.setFavorite([], to: true)
        let archived = await fixture.model.setArchived([], to: true)
        let locked = await fixture.model.setLocked([])
        await fixture.model.unfavorite([])
        await fixture.model.delete([])
        XCTAssertFalse(favorite)
        XCTAssertFalse(archived)
        XCTAssertFalse(locked)
        XCTAssertTrue(fixture.repository.requests.isEmpty)
        XCTAssertTrue(fixture.repository.deleteRequests.isEmpty)
        XCTAssertEqual(fixture.model.assets.map(\.id), fixture.ids)
        XCTAssertEqual(try snapshot(fixture).map(\.id), fixture.ids)
        XCTAssertNil(fixture.model.actionError)
    }

    private func assertVisibilityFailures(_ action: CollectionVisibilityAction) async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture(archived: action == .unlock)
            fixture.repository.failedIDs = [fixture.ids[failureIndex]]

            let succeeded = await perform(action, ids: fixture.ids, model: fixture.model)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(fixture.repository.requests, Array(fixture.ids.prefix(failureIndex + 1)))
            XCTAssertEqual(fixture.repository.visibilities, Array(repeating: action.visibility, count: failureIndex + 1))
            let remaining = Array(fixture.ids.suffix(from: failureIndex))
            XCTAssertEqual(fixture.model.assets.map(\.id), remaining)
            XCTAssertEqual(try snapshot(fixture).map(\.id), remaining)
            let reopened = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
            for (index, id) in fixture.ids.enumerated() {
                let expected = index < failureIndex ? action != .unlock : action == .unlock
                XCTAssertEqual(reopened.getCachedAsset(id: id)?.isArchived, expected)
            }
            XCTAssertEqual(fixture.model.actionError, "Rejected \(fixture.ids[failureIndex])")
            assertLoaded(fixture.model)
        }
    }

    private func perform(_ action: CollectionVisibilityAction, ids: [String], model: AssetGridViewModel) async -> Bool {
        switch action {
        case .archive: await model.setArchived(ids, to: true)
        case .unlock: await model.setArchived(ids, to: false)
        case .lock: await model.setLocked(ids)
        }
    }

    private func fixture(favorite: Bool = false, archived: Bool = false, empty: Bool = false) async throws -> CollectionMutationFixture {
        let fixture = try CollectionMutationFixture(favorite: favorite, archived: archived, empty: empty)
        directories.append(fixture.directory)
        snapshotKeys.append(fixture.snapshotKey)
        await fixture.model.load()
        XCTAssertEqual(fixture.model.assets.map(\.id), empty ? [] : fixture.ids)
        assertLoaded(fixture.model)
        return fixture
    }

    private func snapshot(_ fixture: CollectionMutationFixture) throws -> [AssetLite] {
        try XCTUnwrap(LocalSnapshot.load([AssetLite].self, for: fixture.snapshotKey))
    }

    private func assertLoaded(_ model: AssetGridViewModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .loaded = model.phase {} else { XCTFail("A mutation must not change the loading phase", file: file, line: line) }
    }
}

private enum CollectionVisibilityAction: CaseIterable {
    case archive, unlock, lock
    var visibility: String {
        switch self { case .archive: "archive"; case .unlock: "timeline"; case .lock: "locked" }
    }
}

private enum CollectionTrashAction: CaseIterable {
    case restore, restoreAll, empty
    var path: String {
        switch self { case .restore: "/trash/restore/assets"; case .restoreAll: "/trash/restore"; case .empty: "/trash/empty" }
    }
}

@MainActor
private final class CollectionMutationFixture {
    let directory: URL
    let storeURL: URL
    let journalURL: URL
    let snapshotKey = "test.collection.mutations.\(UUID())"
    let ids = (0..<3).map { _ in UUID().uuidString }
    let manager: SwiftDataManager
    let repository: CollectionMutationRepository
    let model: AssetGridViewModel

    init(favorite: Bool, archived: Bool, empty: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-mutations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("assets.store")
        journalURL = directory.appendingPathComponent("backup.json")
        manager = SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
        repository = CollectionMutationRepository(api: makeStubAPIClient())
        let assets = empty ? [] : ids.map { AssetLite(id: $0, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: .distantPast, isFavorite: favorite) }
        model = AssetGridViewModel(assetRepo: repository, albumRepo: AlbumRepository(api: makeStubAPIClient()),
            snapshotKey: snapshotKey, dataManager: manager, loader: { assets })
        for id in ids {
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE",
                isFavorite: favorite, isArchived: archived, createdAt: .distantPast, updatedAt: .distantPast, ratio: 1))
        }
    }
}

private final class CollectionMutationRepository: AssetDetailRepository {
    var failedIDs: Set<String> = []
    var deleteError: Error?
    var onRequest: ((String) -> Void)?
    private(set) var requests: [String] = []
    private(set) var favoriteValues: [Bool] = []
    private(set) var visibilities: [String] = []
    private(set) var deleteRequests: [(ids: [String], force: Bool)] = []

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        favoriteValues.append(value)
        try record(id)
    }

    override func setVisibility(_ id: String, to value: Visibility) async throws {
        visibilities.append(value.rawValue)
        try record(id)
    }

    override func delete(_ ids: [String], force: Bool = false) async throws {
        deleteRequests.append((ids, force))
        if let deleteError { throw deleteError }
    }

    private func record(_ id: String) throws {
        requests.append(id)
        onRequest?(id)
        if failedIDs.contains(id) { throw APIError.server(status: 403, message: "Rejected \(id)") }
    }
}

private final class CollectionTrashClient: APIClient {
    private(set) var requestPaths: [String] = []

    override func sendVoid(_ endpoint: Endpoint) async throws {
        requestPaths.append(endpoint.path)
        throw APIError.server(status: 403, message: "Trash request rejected")
    }
}
