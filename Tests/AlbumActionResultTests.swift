import XCTest
@testable import ImmichApp

@MainActor
final class AlbumActionResultTests: XCTestCase {
    private var directories: [URL] = []
    private var snapshotKeys: [String] = []

    override func tearDown() async throws {
        for key in snapshotKeys { LocalSnapshot.remove(key) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        snapshotKeys.removeAll()
        directories.removeAll()
        LocalSnapshot.remove(LocalSnapshot.Key.albumsList)
        try await super.tearDown()
    }

    func testFailedFavoriteKeepsTheLoadedAlbumAndSavedValues() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = "a"

        await fixture.model.toggleFavorite(fixture.photos[0])

        XCTAssertEqual(fixture.assets.favoriteCalls, ["a"])
        XCTAssertEqual(fixture.model.assets.map(\.isFavorite), [false, false, false])
        XCTAssertEqual(fixture.snapshot()?.map(\.isFavorite), [false, false, false])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialFavoritePersistsOnlyTheConfirmedPrefix() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = "b"

        await fixture.model.setFavorite(["a", "b", "c"], to: true)

        XCTAssertEqual(fixture.assets.favoriteCalls, ["a", "b"])
        XCTAssertEqual(fixture.model.assets.map(\.isFavorite), [true, false, false])
        XCTAssertEqual(fixture.snapshot()?.map(\.isFavorite), [true, false, false])
        XCTAssertEqual(fixture.database.timelineAssets().map(\.asset.isFavorite), [true, false, false])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialArchiveUpdatesOnlyConfirmedTimelineRowsAndKeepsAlbumContents() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = "b"

        await fixture.model.setArchived(["a", "b", "c"], to: true)

        XCTAssertEqual(fixture.assets.visibilityCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(fixture.assets.visibilityCalls.map(\.value), ["archive", "archive"])
        XCTAssertEqual(fixture.database.timelineAssets().map(\.asset.id), ["b", "c"])
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialLockRemovesOnlyConfirmedPhotosFromAlbumSnapshotAndTimeline() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = "b"

        await fixture.model.setLocked(["a", "b", "c"])

        XCTAssertEqual(fixture.assets.visibilityCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(fixture.assets.visibilityCalls.map(\.value), ["locked", "locked"])
        XCTAssertEqual(fixture.model.assets.map(\.id), ["b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["b", "c"])
        XCTAssertEqual(fixture.database.timelineAssets().map(\.asset.id), ["b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testAnArchiveRejectedBeforeAnySuccessDoesNotHideLocalPhotos() async throws {
        let fixture = try await fixture()
        fixture.assets.failureID = "a"

        await fixture.model.setArchived(["a", "b", "c"], to: true)

        XCTAssertEqual(fixture.assets.visibilityCalls.map(\.id), ["a"])
        XCTAssertEqual(fixture.database.timelineAssets().map(\.asset.id), ["a", "b", "c"])
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testFailedDeleteRetainsTheLoadedPhotosAndTheirSnapshot() async throws {
        let fixture = try await fixture()
        fixture.assets.failDelete = true

        await fixture.model.deleteAssets(["a", "b"])

        XCTAssertEqual(fixture.assets.deleteCalls, [["a", "b"]])
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialAlbumRemovalKeepsFailedAndUnrequestedPhotos() async throws {
        let fixture = try await fixture()
        fixture.albums.removeFailure = AlbumMutationError(succeededIDs: ["a"], duplicateIDs: [], failedIDs: ["b"])

        await fixture.model.removeAssets(["a", "b"], from: fixture.albumID)

        XCTAssertEqual(fixture.albums.removeCalls, [["a", "b"]])
        XCTAssertEqual(fixture.model.assets.map(\.id), ["b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["b", "c"])
        XCTAssertEqual(fixture.database.timelineAssets().map(\.asset.id), ["a", "b", "c"],
            "Removing album membership must not remove the library photo")
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testSuccessfulRemovalClearsTheOldErrorAndKeepsOtherPhotos() async throws {
        let fixture = try await fixture()
        fixture.model.actionError = "Earlier failure"

        await fixture.model.removeAssets(["a", "b"], from: fixture.albumID)

        XCTAssertEqual(fixture.model.assets.map(\.id), ["c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["c"])
        XCTAssertNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testARejectedAddDoesNotReloadOrOverwriteTheLoadedAlbum() async throws {
        let fixture = try await fixture()
        fixture.albums.addFailure = AlbumMutationError(succeededIDs: [], duplicateIDs: [], failedIDs: ["new"])
        fixture.timeline.result = []

        await fixture.model.addAssets(["new"], to: fixture.albumID)

        XCTAssertEqual(fixture.timeline.calls, 1)
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialAddReloadsConfirmedChangesAndStillReportsTheFailure() async throws {
        let fixture = try await fixture()
        fixture.albums.addFailure = AlbumMutationError(succeededIDs: ["new"], duplicateIDs: [], failedIDs: ["rejected"])
        fixture.timeline.result = fixture.photos + [photo("new", time: 4)]

        await fixture.model.addAssets(["new", "rejected"], to: fixture.albumID)

        XCTAssertEqual(fixture.timeline.calls, 2)
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c", "new"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c", "new"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testPartialAddFailureKeepsItsErrorWhenReloadAlsoFails() async throws {
        let fixture = try await fixture()
        fixture.albums.addFailure = AlbumMutationError(succeededIDs: [], duplicateIDs: ["a"], failedIDs: ["rejected"])
        fixture.timeline.fail = true

        await fixture.model.addAssets(["a", "rejected"], to: fixture.albumID)

        XCTAssertEqual(fixture.timeline.calls, 2)
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testSuccessfulAddWithFailedRefreshReportsRefreshFailureWithoutHidingTheAlbum() async throws {
        let fixture = try await fixture()
        fixture.timeline.fail = true

        await fixture.model.addAssets(["new"], to: fixture.albumID)

        XCTAssertEqual(fixture.albums.addCalls, [["new"]])
        XCTAssertEqual(fixture.timeline.calls, 2)
        XCTAssertNotNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
        assertLoaded(fixture.model)
    }

    func testAddUserAndSharedLinkFailuresUseActionFeedbackAndCanRecover() async throws {
        let fixture = try await fixture()
        fixture.albums.failUsers = true
        await fixture.model.addUsers(["user"], to: fixture.albumID)
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)

        fixture.albums.failUsers = false
        await fixture.model.addUsers(["user"], to: fixture.albumID)
        XCTAssertNil(fixture.model.actionError)
        fixture.albums.failLink = true
        let failedLink = await fixture.model.createSharedLink(albumId: fixture.albumID)
        XCTAssertNil(failedLink)
        XCTAssertNotNil(fixture.model.actionError)
        assertLoaded(fixture.model)

        fixture.albums.failLink = false
        let link = await fixture.model.createSharedLink(albumId: fixture.albumID)
        XCTAssertEqual(link?.key, "test-key")
        XCTAssertNil(fixture.model.actionError)
        XCTAssertEqual(fixture.model.assets.map(\.id), ["a", "b", "c"])
    }

    func testFailedAlbumDeletionKeepsItsSnapshotAndLoadedPhase() async throws {
        let fixture = try await fixture()
        fixture.albums.failDelete = true

        let deleted = await fixture.model.deleteAlbum(fixture.albumID)

        XCTAssertFalse(deleted)
        XCTAssertNotNil(fixture.model.actionError)
        XCTAssertEqual(fixture.snapshot()?.map(\.id), ["a", "b", "c"])
        assertLoaded(fixture.model)
        fixture.albums.failDelete = false
        let successful = await fixture.model.deleteAlbum(fixture.albumID)
        XCTAssertTrue(successful)
        XCTAssertNil(fixture.model.actionError)
        XCTAssertNil(fixture.snapshot())
    }

    func testAlbumListDeleteAndAddUserFailuresAreVisibleWithoutReplacingItsList() async {
        LocalSnapshot.remove(LocalSnapshot.Key.albumsList)
        let repository = AlbumActionRepository(api: makeStubAPIClient())
        repository.list = [album("list")]
        let model = AlbumListViewModel(repo: repository)
        await model.loadAlbums()
        repository.failDelete = true

        await model.deleteAlbum("list")

        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.albums.map(\.id), ["list"])
        if case .loaded = model.phase {} else { XCTFail("The album list must stay loaded") }
        repository.failUsers = true
        await model.addUsers(["user"], to: "list")
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.albums.map(\.id), ["list"])
        repository.failUsers = false
        await model.addUsers(["user"], to: "list")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.albums.map(\.id), ["list"])
    }

    func testUserPickerFailureIsDistinctFromAnEmptyServerAndCanRetry() async {
        let repository = AlbumActionRepository(api: makeStubAPIClient())
        let model = AlbumUserPickerViewModel(repo: repository, currentUserID: "self")
        repository.failUserLookup = true

        await model.load()

        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("User lookup rejected"))
        } else {
            XCTFail("A failed request must not show No Other Users")
        }
        XCTAssertEqual(repository.userLookupCalls, 1)
        repository.failUserLookup = false
        repository.availableUsers = [user("self"), user("other")]

        await model.load()

        XCTAssertEqual(repository.userLookupCalls, 2)
        XCTAssertEqual(model.users.map(\.id), ["other"])
        if case .loaded = model.phase {} else { XCTFail("Retry should load the available users") }
        await model.load()
        XCTAssertEqual(repository.userLookupCalls, 2, "Repeated view tasks should not reload a successful picker")
    }

    func testUserPickerLoadsARealEmptyResultAfterFilteringTheCurrentUser() async {
        let repository = AlbumActionRepository(api: makeStubAPIClient())
        repository.availableUsers = [user("self")]
        let model = AlbumUserPickerViewModel(repo: repository, currentUserID: "self")

        await model.load()

        XCTAssertEqual(repository.userLookupCalls, 1)
        XCTAssertTrue(model.users.isEmpty)
        if case .loaded = model.phase {} else { XCTFail("A successful empty result should show No Other Users") }
    }

    private func fixture() async throws -> AlbumActionFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-action-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let id = UUID().uuidString
        snapshotKeys.append(LocalSnapshot.Key.album(id))
        let fixture = try AlbumActionFixture(directory: directory, albumID: id)
        let loaded = await fixture.model.loadAlbumDetail(id)
        XCTAssertTrue(loaded)
        return fixture
    }

    private func assertLoaded(_ model: AlbumDetailViewModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .loaded = model.phase {} else { XCTFail("Action failure must not replace the album grid", file: file, line: line) }
    }

    private func photo(_ id: String, time: TimeInterval) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: Date(timeIntervalSince1970: time))
    }

    private func album(_ id: String) -> AlbumResponseDTO {
        AlbumResponseDTO(id: id, albumName: id, description: nil, assetCount: 3,
            albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
    }

    private func user(_ id: String) -> UserResponseDTO {
        UserResponseDTO(id: id, email: "\(id)@example.test", name: id,
            profileImagePath: nil, profileChangedAt: nil, storageLabel: nil, isAdmin: false)
    }
}

@MainActor
private final class AlbumActionFixture {
    let albumID: String
    let photos: [AssetLite]
    let database: SwiftDataManager
    let assets: AlbumActionAssetRepository
    let albums: AlbumActionRepository
    let timeline: AlbumActionTimelineRepository
    let model: AlbumDetailViewModel

    init(directory: URL, albumID: String) throws {
        self.albumID = albumID
        photos = ["a", "b", "c"].enumerated().map { index, id in
            AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)))
        }
        database = SwiftDataManager(storeURL: directory.appendingPathComponent("cache.store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
        XCTAssertTrue(database.isPersistentStoreAvailable)
        try database.restoreToTimeline(photos)
        let api = makeStubAPIClient()
        assets = AlbumActionAssetRepository(api: api)
        albums = AlbumActionRepository(api: api)
        timeline = AlbumActionTimelineRepository(api: api)
        timeline.result = photos
        model = AlbumDetailViewModel(timelineRepo: timeline, albumRepo: albums, assetRepo: assets, dataManager: database)
    }

    func snapshot() -> [AssetLite]? {
        LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(albumID))
    }
}

private final class AlbumActionAssetRepository: AssetDetailRepository {
    struct VisibilityCall { let id: String; let value: String }
    var failureID: String?
    var failDelete = false
    var favoriteCalls: [String] = []
    var visibilityCalls: [VisibilityCall] = []
    var deleteCalls: [[String]] = []

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        favoriteCalls.append(id)
        if id == failureID { throw APIError.server(status: 403, message: "Rejected action") }
    }

    override func setVisibility(_ id: String, to value: Visibility) async throws {
        visibilityCalls.append(VisibilityCall(id: id, value: value.rawValue))
        if id == failureID { throw APIError.server(status: 403, message: "Rejected action") }
    }

    override func delete(_ ids: [String], force: Bool = false) async throws {
        deleteCalls.append(ids)
        if failDelete { throw APIError.server(status: 403, message: "Rejected action") }
    }
}

private final class AlbumActionRepository: AlbumRepository {
    var list: [AlbumResponseDTO] = []
    var addFailure: Error?
    var removeFailure: Error?
    var failDelete = false
    var failUsers = false
    var failLink = false
    var failUserLookup = false
    var availableUsers: [UserResponseDTO] = []
    var userLookupCalls = 0
    var addCalls: [[String]] = []
    var removeCalls: [[String]] = []

    override func all() async throws -> [AlbumResponseDTO] { list }

    override func users() async throws -> [UserResponseDTO] {
        userLookupCalls += 1
        if failUserLookup { throw APIError.server(status: 403, message: "User lookup rejected") }
        return availableUsers
    }

    override func addAssets(_ ids: [String], to albumId: String) async throws -> [String] {
        addCalls.append(ids)
        if let addFailure { throw addFailure }
        return []
    }

    override func removeAssets(_ ids: [String], from albumId: String) async throws {
        removeCalls.append(ids)
        if let removeFailure { throw removeFailure }
    }

    override func addUsers(_ userIds: [String], to albumId: String) async throws {
        if failUsers { throw APIError.server(status: 403, message: "Rejected action") }
    }

    override func createSharedLink(albumId: String) async throws -> SharedLinkDTO {
        if failLink { throw APIError.server(status: 403, message: "Rejected action") }
        return try JSONDecoder().decode(SharedLinkDTO.self,
            from: Data("{\"id\":\"link\",\"key\":\"test-key\",\"type\":\"ALBUM\"}".utf8))
    }

    override func delete(_ id: String) async throws {
        if failDelete { throw APIError.server(status: 403, message: "Rejected action") }
        list.removeAll { $0.id == id }
    }
}

private final class AlbumActionTimelineRepository: TimelineRepository {
    var result: [AssetLite] = []
    var fail = false
    var calls = 0

    override func albumAssets(_ albumId: String, expectedCount: Int? = nil) async throws -> [AssetLite] {
        calls += 1
        if fail { throw APIError.server(status: 503, message: "Refresh failed") }
        return result
    }
}
