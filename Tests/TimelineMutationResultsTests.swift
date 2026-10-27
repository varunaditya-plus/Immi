import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class TimelineMutationResultsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testArchiveFailureAppliesOnlyTheConfirmedPrefixToTheGridAndStore() async throws {
        try await assertVisibilityFailure(action: .archive)
    }

    func testLockFailureAppliesOnlyTheConfirmedPrefixToTheGridAndStore() async throws {
        try await assertVisibilityFailure(action: .lock)
    }

    func testFavoriteFailureKeepsTheConfirmedPrefixFavoriteInTheGridAndStore() async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture()
            let ids = fixture.ids
            fixture.repository.failureID = ids[failureIndex]

            let succeeded = await fixture.model.favoriteSelected(ids)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(fixture.repository.requests, Array(ids.prefix(failureIndex + 1)))
            XCTAssertEqual(fixture.repository.favoriteValues, Array(repeating: true, count: failureIndex + 1))
            XCTAssertEqual(fixture.model.allAssets.map(\.id), ids)
            XCTAssertEqual(fixture.model.allAssets.filter(\.isFavorite).map(\.id), Array(ids.prefix(failureIndex)))
            XCTAssertEqual(fixture.model.sections.flatMap(\.assets).filter(\.isFavorite).map(\.id), Array(ids.prefix(failureIndex)))
            for (index, id) in ids.enumerated() {
                XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, index < failureIndex)
            }
            let reopened = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
            XCTAssertEqual(reopened.timelineAssets().filter { $0.asset.isFavorite }.map { $0.asset.id }, Array(ids.prefix(failureIndex)))
            XCTAssertEqual(fixture.model.actionError, "Failed for \(ids[failureIndex])")
            assertLoaded(fixture.model)
        }
    }

    func testSuccessfulVisibilityActionsRemoveEveryAcceptedItemAndClearAnOlderError() async throws {
        for action in VisibilityAction.allCases {
            let fixture = try await fixture()
            fixture.model.actionError = "An earlier error"

            let succeeded = await perform(action, ids: fixture.ids, model: fixture.model)

            XCTAssertTrue(succeeded)
            XCTAssertEqual(fixture.repository.requests, fixture.ids)
            XCTAssertTrue(fixture.model.allAssets.isEmpty)
            XCTAssertTrue(fixture.model.sections.isEmpty)
            XCTAssertTrue(fixture.manager.timelineAssets().isEmpty)
            XCTAssertNil(fixture.model.actionError)
            for id in fixture.ids { XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isArchived, true) }
            assertLoaded(fixture.model)
        }
    }

    func testRetryAfterPartialArchiveProcessesTheRemainingItemsAndClearsTheError() async throws {
        let fixture = try await fixture()
        fixture.repository.failureID = fixture.ids[1]
        let firstSucceeded = await fixture.model.archiveSelected(fixture.ids)
        XCTAssertFalse(firstSucceeded)
        XCTAssertEqual(fixture.model.allAssets.map(\.id), Array(fixture.ids.suffix(2)))
        XCTAssertNotNil(fixture.model.actionError)
        fixture.repository.failureID = nil

        let retried = await fixture.model.archiveSelected(fixture.model.allAssets.map(\.id))

        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.repository.requests, [fixture.ids[0], fixture.ids[1], fixture.ids[1], fixture.ids[2]])
        XCTAssertTrue(fixture.model.allAssets.isEmpty)
        XCTAssertNil(fixture.model.actionError)
        let reopened = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
        XCTAssertTrue(reopened.timelineAssets().isEmpty)
    }

    func testSuccessfulFavoriteAndToggleClearErrorsAndPersistTheirAcceptedValues() async throws {
        let fixture = try await fixture()
        fixture.model.actionError = "An earlier error"

        let favored = await fixture.model.favoriteSelected(fixture.ids)

        XCTAssertTrue(favored)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.allAssets.filter(\.isFavorite).count, 3)
        let favorite = try XCTUnwrap(fixture.model.allAssets.first)
        fixture.model.actionError = "Another error"
        let toggled = await fixture.model.toggleFavorite(favorite)

        XCTAssertTrue(toggled)
        XCTAssertEqual(fixture.repository.favoriteValues, [true, true, true, false])
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.asset(for: favorite.id)?.isFavorite, false)
        XCTAssertEqual(fixture.manager.getCachedAsset(id: favorite.id)?.isFavorite, false)
        for id in fixture.ids.dropFirst() { XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isFavorite, true) }
    }

    func testSingleArchiveFailureKeepsThePhotoAndASuccessfulRetryClearsTheError() async throws {
        let fixture = try await fixture()
        let asset = try XCTUnwrap(fixture.model.allAssets.first)
        fixture.repository.failureID = asset.id

        await fixture.model.archive(asset)

        XCTAssertEqual(fixture.model.allAssets.map(\.id), fixture.ids)
        XCTAssertEqual(fixture.manager.getCachedAsset(id: asset.id)?.isArchived, false)
        XCTAssertEqual(fixture.model.actionError, "Failed for \(asset.id)")
        fixture.repository.failureID = nil
        await fixture.model.archive(asset)
        XCTAssertEqual(fixture.model.allAssets.map(\.id), Array(fixture.ids.dropFirst()))
        XCTAssertEqual(fixture.manager.getCachedAsset(id: asset.id)?.isArchived, true)
        XCTAssertNil(fixture.model.actionError)
    }

    func testAddingToAlbumReturnsFailureWithoutChangingTheTimelineThenSucceedsOnRetry() async throws {
        let fixture = try await fixture()
        fixture.albumRepository.shouldFail = true

        let first = await fixture.model.addToAlbum(fixture.ids, album: fixture.album)

        XCTAssertFalse(first)
        XCTAssertEqual(fixture.model.actionError, "Album rejected the photos")
        XCTAssertEqual(fixture.model.allAssets.map(\.id), fixture.ids)
        fixture.albumRepository.shouldFail = false
        let retry = await fixture.model.addToAlbum(fixture.ids, album: fixture.album)
        XCTAssertTrue(retry)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.albumRepository.requests, [fixture.ids, fixture.ids])
    }

    func testAlreadyPresentAlbumPhotosRemainASuccessfulActionWithFeedback() async throws {
        let fixture = try await fixture()
        fixture.albumRepository.duplicates = [fixture.ids[0]]

        let succeeded = await fixture.model.addToAlbum(fixture.ids, album: fixture.album)

        XCTAssertTrue(succeeded)
        XCTAssertNotNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.allAssets.map(\.id), fixture.ids)
    }

    private func assertVisibilityFailure(action: VisibilityAction) async throws {
        for failureIndex in 0..<3 {
            let fixture = try await fixture()
            let ids = fixture.ids
            fixture.repository.failureID = ids[failureIndex]

            let succeeded = await perform(action, ids: ids, model: fixture.model)

            XCTAssertFalse(succeeded)
            XCTAssertEqual(fixture.repository.requests, Array(ids.prefix(failureIndex + 1)))
            XCTAssertEqual(fixture.repository.visibilities, Array(repeating: action == .archive ? "archive" : "locked", count: failureIndex + 1))
            let remaining = Array(ids.suffix(from: failureIndex))
            XCTAssertEqual(fixture.model.allAssets.map(\.id), remaining)
            XCTAssertEqual(fixture.model.sections.flatMap(\.assets).map(\.id), remaining)
            XCTAssertEqual(fixture.model.sections.first?.count, remaining.count)
            XCTAssertEqual(fixture.model.sections.first?.startIndex, 0)
            for (index, id) in ids.enumerated() {
                XCTAssertEqual(fixture.manager.getCachedAsset(id: id)?.isArchived, index < failureIndex)
            }
            let reopened = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
            XCTAssertEqual(reopened.timelineAssets().map { $0.asset.id }, remaining)
            XCTAssertEqual(fixture.model.actionError, "Failed for \(ids[failureIndex])")
            await fixture.model.loadTimeline()
            XCTAssertEqual(fixture.model.allAssets.map(\.id), remaining, "Rebuilding must not restore an accepted archive or lock")
            assertLoaded(fixture.model)
        }
    }

    private enum VisibilityAction: CaseIterable { case archive, lock }

    private func perform(_ action: VisibilityAction, ids: [String], model: TimelineViewModel) async -> Bool {
        switch action {
        case .archive: await model.archiveSelected(ids)
        case .lock: await model.lockSelected(ids)
        }
    }

    private func fixture() async throws -> TimelineMutationFixture {
        let fixture = try TimelineMutationFixture()
        directories.append(fixture.directory)
        await fixture.model.loadTimeline()
        XCTAssertEqual(fixture.model.allAssets.map(\.id), fixture.ids)
        return fixture
    }

    private func assertLoaded(_ model: TimelineViewModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .loaded = model.phase {} else { XCTFail("An action must not replace the timeline loading phase", file: file, line: line) }
    }
}

@MainActor
private final class TimelineMutationFixture {
    let directory: URL
    let storeURL: URL
    let journalURL: URL
    let manager: SwiftDataManager
    let repository: TimelineMutationRepository
    let albumRepository: TimelineMutationAlbumRepository
    let model: TimelineViewModel
    let ids = (0..<3).map { _ in UUID().uuidString }
    let album = AlbumResponseDTO(id: "album", albumName: "Album", description: nil,
        assetCount: 0, albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-mutations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("assets.store")
        journalURL = directory.appendingPathComponent("backup.json")
        manager = SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
        repository = TimelineMutationRepository(api: makeStubAPIClient())
        albumRepository = TimelineMutationAlbumRepository(api: makeStubAPIClient())
        model = TimelineViewModel(dataManager: manager, assetRepo: repository, albumRepo: albumRepository)
        for (index, id) in ids.enumerated() {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE",
                isFavorite: false, isArchived: false, createdAt: date, updatedAt: date, ratio: 1))
        }
    }
}

private final class TimelineMutationRepository: AssetDetailRepository {
    var failureID: String?
    private(set) var requests: [String] = []
    private(set) var favoriteValues: [Bool] = []
    private(set) var visibilities: [String] = []

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        favoriteValues.append(value)
        try record(id)
    }

    override func toggleArchive(_ id: String, to value: Bool) async throws {
        visibilities.append(value ? "archive" : "timeline")
        try record(id)
    }

    override func setVisibility(_ id: String, to value: Visibility) async throws {
        visibilities.append(value.rawValue)
        try record(id)
    }

    private func record(_ id: String) throws {
        requests.append(id)
        if id == failureID { throw APIError.server(status: 503, message: "Failed for \(id)") }
    }
}

private final class TimelineMutationAlbumRepository: AlbumRepository {
    var shouldFail = false
    var duplicates: [String] = []
    private(set) var requests: [[String]] = []

    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        requests.append(ids)
        if shouldFail { throw APIError.server(status: 403, message: "Album rejected the photos") }
        return duplicates
    }
}
