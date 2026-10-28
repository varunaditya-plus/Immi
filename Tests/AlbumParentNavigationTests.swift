import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumParentNavigationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
        AlbumCoverStore.shared.clear()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        AlbumCoverStore.shared.clear()
        try await super.tearDown()
    }

    func testAllAlbumsDetailPublishesContentsAndMetadataToBothParents() async throws {
        let fixture = fixture()
        let original = album("album", name: "Original", count: 8, cover: "removed", shared: true)
        fixture.list.albums = [original]
        fixture.library.albums = [original]
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)
        let destination = parent.albumDestination(for: original, using: fixture.list)
        let contents = try XCTUnwrap(destination.onContentsChanged)
        let metadata = try XCTUnwrap(destination.onAlbumChanged)
        let read = expectation(description: "Library reconciles the changed album contents")
        fixture.libraryDriver.readStarted = read
        let remaining = AssetLite(makeTestAsset(id: "navigation-kept"))
        let observed = ParentNavigationProbe()
        withObservationTracking { _ = fixture.list.albums } onChange: {
            MainActor.assumeIsolated { observed.list = true }
        }
        withObservationTracking { _ = fixture.library.albums } onChange: {
            MainActor.assumeIsolated { observed.library = true }
        }

        contents([remaining])
        metadata(album("album", name: "Saved name", count: 8, cover: "removed"))
        await fulfillment(of: [read], timeout: 2)

        XCTAssertTrue(observed.list)
        XCTAssertTrue(observed.library)
        for rows in [fixture.list.albums, fixture.library.albums,
                     cached(.albumsList), cached(.libraryAlbums)] {
            XCTAssertEqual(rows.first?.albumName, "Saved name")
            XCTAssertEqual(rows.first?.assetCount, 1)
            XCTAssertEqual(rows.first?.albumThumbnailAssetId, "navigation-kept")
            XCTAssertEqual(rows.first?.shared, true, "A metadata edit must preserve sharing")
        }
        XCTAssertEqual(fixture.libraryDriver.reads, 1)
    }

    func testEmptyContentsFromAllAlbumsClearParentCountsAndCovers() async throws {
        let fixture = fixture()
        let original = album("album", count: 3, cover: "old-cover")
        fixture.list.albums = [original]
        fixture.library.albums = [original]
        let destination = LibraryView().allAlbumsDestination(using: fixture.library)
            .albumDestination(for: original, using: fixture.list)
        let read = expectation(description: "The empty album is reconciled")
        fixture.libraryDriver.readStarted = read

        try XCTUnwrap(destination.onContentsChanged)([])
        await fulfillment(of: [read], timeout: 2)

        for rows in [fixture.list.albums, fixture.library.albums,
                     cached(.albumsList), cached(.libraryAlbums)] {
            XCTAssertEqual(rows.first?.assetCount, 0)
            XCTAssertNil(rows.first?.albumThumbnailAssetId)
        }
    }

    func testAllAlbumsDetailDeletionInvalidatesBothParentsAndTheirOlderReads() async throws {
        let fixture = fixture()
        let original = album("deleted", count: 2)
        fixture.list.albums = [original, album("kept")]
        fixture.library.albums = fixture.list.albums
        let listRead = ParentNavigationGate<[AlbumResponseDTO]>()
        let libraryRead = ParentNavigationGate<[AlbumResponseDTO]>()
        fixture.listDriver.read = { try await listRead.value() }
        fixture.libraryDriver.read = { try await libraryRead.value() }
        LocalSnapshot.save(["old asset"], for: LocalSnapshot.Key.album(original.id))
        await AlbumCoverStore.shared.resolveCover(for: original, repository: fixture.listRepository)
        XCTAssertEqual(AlbumCoverStore.shared.coverID(for: original), "navigation-cover")
        let listLoading = Task { await fixture.list.loadAlbums() }
        let libraryLoading = Task { await fixture.library.refreshAlbums() }
        addTeardownBlock {
            await listRead.complete(.failure(CancellationError()))
            await libraryRead.complete(.failure(CancellationError()))
            await listLoading.value
            await libraryLoading.value
        }
        await fulfillment(of: [listRead.started, libraryRead.started], timeout: 2)
        let destination = LibraryView().allAlbumsDestination(using: fixture.library)
            .albumDestination(for: original, using: fixture.list)

        try XCTUnwrap(destination.onDeleted)()
        // Dismissing a loaded detail can report its final contents afterward.
        try XCTUnwrap(destination.onContentsChanged)([AssetLite(makeTestAsset(id: "stale-photo"))])
        try XCTUnwrap(destination.onAlbumChanged)(original)
        listRead.complete(.success([original, album("kept")]))
        libraryRead.complete(.success([original, album("kept")]))
        await listLoading.value
        await libraryLoading.value

        for rows in [fixture.list.albums, fixture.library.albums,
                     cached(.albumsList), cached(.libraryAlbums)] {
            XCTAssertEqual(rows.map(\.id), ["kept"])
        }
        XCTAssertNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(original.id)))
        XCTAssertNil(AlbumCoverStore.shared.coverID(for: original))
        XCTAssertTrue(fixture.listDriver.deletedIDs.isEmpty, "The child already deleted the server album")
    }

    func testRecentLibraryAndRoutedDestinationsBothRemoveDeletedAlbums() async throws {
        for routed in [false, true] {
            LocalSnapshot.clearAll()
            let fixture = fixture()
            let original = album("deleted", count: 5, cover: "removed")
            fixture.library.albums = [original, album("kept")]
            let parent = LibraryView()
            let destination: AlbumDetailView
            if routed {
                let route = parent.routedAlbumDestination(id: original.id, using: fixture.library)
                XCTAssertEqual(route.cachedAlbum?.id, original.id)
                destination = route.destination(original)
            } else {
                destination = parent.albumDestination(for: original, using: fixture.library)
            }

            try XCTUnwrap(destination.onDeleted)()

            XCTAssertEqual(fixture.library.albums.map(\.id), ["kept"])
            XCTAssertEqual(cached(.libraryAlbums).map(\.id), ["kept"])
            XCTAssertTrue(fixture.libraryDriver.deletedIDs.isEmpty)
        }
    }

    func testRoutedDeletionOfAnUnlistedAlbumStillRejectsItsOlderListResponse() async throws {
        let fixture = fixture()
        let old = ParentNavigationGate<[AlbumResponseDTO]>()
        fixture.libraryDriver.read = { try await old.value() }
        let loading = Task { await fixture.library.refreshAlbums() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await loading.value }
        await fulfillment(of: [old.started], timeout: 2)
        let route = LibraryView().routedAlbumDestination(id: "deleted", using: fixture.library)
        XCTAssertNil(route.cachedAlbum)

        try XCTUnwrap(route.destination(album("deleted")).onDeleted)()
        old.complete(.success([album("deleted")]))
        await loading.value

        XCTAssertTrue(fixture.library.albums.isEmpty)
        XCTAssertTrue(cached(.libraryAlbums).isEmpty)
    }

    func testContextAndSwipeDeletionPropagateOnlyAfterServerConfirmation() async {
        let fixture = fixture()
        let original = album("album")
        fixture.list.albums = [original]
        fixture.list.phase = .loaded(())
        fixture.library.albums = [original]
        LocalSnapshot.save([original], for: LocalSnapshot.Key.libraryAlbums)
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)
        fixture.listDriver.delete = { _ in throw APIError.unknown }

        await parent.deleteAlbum(original.id, using: fixture.list)

        XCTAssertEqual(fixture.library.albums.map(\.id), [original.id])
        XCTAssertEqual(cached(.libraryAlbums).map(\.id), [original.id])
        XCTAssertNotNil(fixture.list.actionError)
        fixture.listDriver.delete = { _ in }
        await parent.deleteAlbum(original.id, using: fixture.list)

        XCTAssertTrue(fixture.list.albums.isEmpty)
        XCTAssertTrue(fixture.library.albums.isEmpty)
        XCTAssertTrue(cached(.libraryAlbums).isEmpty)
        XCTAssertEqual(fixture.listDriver.deletedIDs, [original.id, original.id])
        XCTAssertNil(fixture.list.actionError)
    }

    func testCreationInAllAlbumsReachesLibraryAndRejectsBothOlderLists() async {
        let fixture = fixture()
        let original = album("original")
        let created = album("created", name: "Created", createdAt: 200)
        fixture.list.albums = [original]
        fixture.library.albums = [original]
        fixture.listDriver.created = created
        let listRead = ParentNavigationGate<[AlbumResponseDTO]>()
        let libraryRead = ParentNavigationGate<[AlbumResponseDTO]>()
        fixture.listDriver.read = { try await listRead.value() }
        fixture.libraryDriver.read = { try await libraryRead.value() }
        let loadingList = Task { await fixture.list.loadAlbums() }
        let loadingLibrary = Task { await fixture.library.refreshAlbums() }
        addTeardownBlock {
            await listRead.complete(.failure(CancellationError()))
            await libraryRead.complete(.failure(CancellationError()))
            await loadingList.value
            await loadingLibrary.value
        }
        await fulfillment(of: [listRead.started, libraryRead.started], timeout: 2)
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)

        let error = await parent.createAlbum(name: "Created", description: "", assetIds: [], using: fixture.list)
        listRead.complete(.success([original]))
        libraryRead.complete(.success([original]))
        await loadingList.value
        await loadingLibrary.value

        XCTAssertNil(error)
        XCTAssertEqual(Set(fixture.list.albums.map(\.id)), ["original", "created"])
        XCTAssertEqual(fixture.library.albums.map(\.id), ["created", "original"])
        XCTAssertEqual(cached(.libraryAlbums).map(\.id), ["created", "original"])
        XCTAssertEqual(fixture.listDriver.createdNames, ["Created"])
    }

    func testRejectedCreationAndSharingDoNotPublishParentChanges() async {
        let fixture = fixture()
        fixture.list.albums = [album("original")]
        fixture.library.albums = fixture.list.albums
        fixture.listDriver.share = { _, _ in throw APIError.unknown }
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)

        let error = await parent.createAlbum(name: "Rejected", description: "", assetIds: [], using: fixture.list)
        await parent.addUsers(["friend"], to: "original", using: fixture.list)

        XCTAssertNotNil(error)
        XCTAssertNotNil(fixture.list.actionError)
        XCTAssertEqual(fixture.library.albums.map(\.id), ["original"])
        XCTAssertEqual(fixture.library.albums.first?.shared, false)
        XCTAssertNil(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums))
        XCTAssertEqual(fixture.listDriver.reads, 0)
    }

    func testSharingReachesLibraryBeforeFallibleReconciliationCompletes() async {
        let fixture = fixture()
        fixture.list.albums = [album("album", name: "Kept name", count: 2)]
        fixture.library.albums = fixture.list.albums
        let read = ParentNavigationGate<[AlbumResponseDTO]>()
        fixture.listDriver.read = { try await read.value() }
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)
        let sharing = Task { await parent.addUsers(["friend"], to: "album", using: fixture.list) }
        addTeardownBlock { await read.complete(.failure(CancellationError())); await sharing.value }
        await fulfillment(of: [read.started], timeout: 2)

        XCTAssertEqual(fixture.library.albums.first?.shared, true)
        XCTAssertEqual(cached(.libraryAlbums).first?.shared, true)
        read.complete(.failure(APIError.unknown))
        await sharing.value

        XCTAssertEqual(fixture.library.albums.first?.albumName, "Kept name")
        XCTAssertEqual(fixture.library.albums.first?.assetCount, 2)
        XCTAssertEqual(fixture.library.albums.first?.shared, true)
        XCTAssertEqual(fixture.listDriver.sharedIDs, ["album"])
        XCTAssertEqual(fixture.listDriver.sharedUsers, [["friend"]])
        XCTAssertNil(fixture.list.actionError)
    }

    func testSharingFromEveryAlbumDetailDestinationReachesItsParent() throws {
        for route in ["all", "recent", "routed"] {
            LocalSnapshot.clearAll()
            let fixture = fixture()
            let original = album("album", name: "Kept", count: 7, cover: "kept-cover")
            fixture.list.albums = [original]
            fixture.library.albums = [original]
            let parent = LibraryView()
            let destination: AlbumDetailView
            switch route {
            case "all":
                destination = parent.allAlbumsDestination(using: fixture.library)
                    .albumDestination(for: original, using: fixture.list)
            case "recent": destination = parent.albumDestination(for: original, using: fixture.library)
            default:
                destination = parent.routedAlbumDestination(id: original.id, using: fixture.library)
                    .destination(original)
            }

            try XCTUnwrap(destination.onShared)()

            XCTAssertEqual(fixture.library.albums.first?.shared, true)
            XCTAssertEqual(cached(.libraryAlbums).first?.shared, true)
            XCTAssertEqual(fixture.library.albums.first?.albumName, "Kept")
            XCTAssertEqual(fixture.library.albums.first?.assetCount, 7)
            XCTAssertEqual(fixture.library.albums.first?.albumThumbnailAssetId, "kept-cover")
            if route == "all" {
                XCTAssertEqual(fixture.list.albums.first?.shared, true)
                XCTAssertEqual(cached(.albumsList).first?.shared, true)
            }
        }
    }

    func testAlbumDetailSharingReportsConfirmationAndSuppressesRejectedOrCanceledRequests() async {
        let fixture = fixture()
        let api = APIClient(session: MockSessionManager())
        let detail = AlbumDetailViewModel(timelineRepo: TimelineRepository(api: api),
            albumRepo: fixture.listRepository, assetRepo: AssetDetailRepository(api: api))

        fixture.listDriver.share = { _, _ in throw APIError.unknown }
        let rejected = await detail.addUsers(["friend"], to: "album")
        XCTAssertFalse(rejected)
        XCTAssertNotNil(detail.actionError)
        fixture.listDriver.share = { _, _ in }
        let accepted = await detail.addUsers(["friend"], to: "album")
        XCTAssertTrue(accepted)
        XCTAssertNil(detail.actionError)
        let held = ParentNavigationGate<Void>()
        fixture.listDriver.share = { _, _ in try await held.value() }
        let canceled = Task { await detail.addUsers(["friend"], to: "album") }
        addTeardownBlock { await held.complete(.failure(CancellationError())); _ = await canceled.value }
        await fulfillment(of: [held.started], timeout: 2)
        canceled.cancel()
        held.complete(.success(()))
        let published = await canceled.value
        XCTAssertFalse(published)
        XCTAssertNil(detail.actionError)
    }

    func testCallbacksFromAnOldAccountCannotModifyTheNextAccountsSnapshots() throws {
        let fixture = fixture()
        let original = album("old")
        fixture.list.albums = [original]
        fixture.library.albums = [original]
        let parent = LibraryView().allAlbumsDestination(using: fixture.library)
        let destination = parent.albumDestination(for: original, using: fixture.list)
        LocalSnapshot.clearAll()
        let next = album("next")
        LocalSnapshot.save([next], for: LocalSnapshot.Key.albumsList)
        LocalSnapshot.save([next], for: LocalSnapshot.Key.libraryAlbums)

        try XCTUnwrap(destination.onDeleted)()
        try XCTUnwrap(destination.onContentsChanged)([])
        try XCTUnwrap(destination.onAlbumChanged)(album("old", name: "Stale"))
        parent.onAlbumCreated?(album("stale-created"))
        parent.onAlbumShared?(original.id)

        XCTAssertEqual(fixture.list.albums.map(\.id), ["old"])
        XCTAssertEqual(fixture.library.albums.map(\.id), ["old"])
        XCTAssertEqual(cached(.albumsList).map(\.id), ["next"])
        XCTAssertEqual(cached(.libraryAlbums).map(\.id), ["next"])
    }

    private func fixture() -> ParentNavigationFixture {
        let api = APIClient(session: MockSessionManager())
        let listDriver = ParentNavigationDriver()
        let libraryDriver = ParentNavigationDriver()
        let listRepository = ParentNavigationAlbums(api: api, driver: listDriver)
        let library = LibraryViewModel(
            memoriesRepo: ParentNavigationMemories(api: api),
            albumRepo: ParentNavigationAlbums(api: api, driver: libraryDriver),
            peopleRepo: ParentNavigationPeople(api: api), searchRepo: ParentNavigationSearch(api: api),
            assetRepo: AssetDetailRepository(api: api))
        return ParentNavigationFixture(list: AlbumListViewModel(repo: listRepository),
            library: library, listRepository: listRepository,
            listDriver: listDriver, libraryDriver: libraryDriver)
    }

    private func album(_ id: String, name: String = "Album", count: Int = 0, cover: String? = nil,
                       shared: Bool = false, createdAt: TimeInterval = 100) -> AlbumResponseDTO {
        .init(id: id, albumName: name, description: nil, assetCount: count, albumThumbnailAssetId: cover,
            shared: shared, createdAt: Date(timeIntervalSince1970: createdAt), assets: nil)
    }

    private enum Snapshot: Equatable { case albumsList, libraryAlbums }
    private func cached(_ key: Snapshot) -> [AlbumResponseDTO] {
        LocalSnapshot.load([AlbumResponseDTO].self,
            for: key == .albumsList ? LocalSnapshot.Key.albumsList : LocalSnapshot.Key.libraryAlbums) ?? []
    }
}

@MainActor
private struct ParentNavigationFixture {
    let list: AlbumListViewModel
    let library: LibraryViewModel
    let listRepository: ParentNavigationAlbums
    let listDriver: ParentNavigationDriver
    let libraryDriver: ParentNavigationDriver
}

@MainActor
private final class ParentNavigationProbe {
    var list = false
    var library = false
}

@MainActor
private final class ParentNavigationDriver {
    var read: () async throws -> [AlbumResponseDTO] = { throw APIError.unknown }
    var delete: (String) async throws -> Void = { _ in }
    var share: ([String], String) async throws -> Void = { _, _ in }
    var created: AlbumResponseDTO?
    var readStarted: XCTestExpectation?
    private(set) var reads = 0
    private(set) var deletedIDs: [String] = []
    private(set) var createdNames: [String] = []
    private(set) var sharedIDs: [String] = []
    private(set) var sharedUsers: [[String]] = []

    func all() async throws -> [AlbumResponseDTO] {
        reads += 1
        readStarted?.fulfill()
        readStarted = nil
        return try await read()
    }
    func deleteAlbum(_ id: String) async throws { deletedIDs.append(id); try await delete(id) }
    func create(_ name: String) throws -> AlbumResponseDTO {
        createdNames.append(name)
        guard let created else { throw APIError.unknown }
        return created
    }
    func shareAlbum(_ users: [String], id: String) async throws {
        sharedIDs.append(id)
        sharedUsers.append(users)
        try await share(users, id)
    }
}

private final class ParentNavigationAlbums: AlbumRepository {
    private let driver: ParentNavigationDriver
    init(api: APIClient, driver: ParentNavigationDriver) { self.driver = driver; super.init(api: api) }
    override func all() async throws -> [AlbumResponseDTO] { try await driver.all() }
    override func delete(_ id: String) async throws { try await driver.deleteAlbum(id) }
    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        try await driver.create(name)
    }
    override func addUsers(_ userIds: [String], to albumId: String) async throws {
        try await driver.shareAlbum(userIds, id: albumId)
    }
    override func recentAssetIDs(
        in albumID: String, limit: Int, includeArchived: Bool = true
    ) async throws -> [String] { ["navigation-cover"] }
}

private final class ParentNavigationMemories: MemoriesRepository {
    override func getMemories() async throws -> [MemoryDTO] { throw APIError.unknown }
}
private final class ParentNavigationPeople: PeopleRepository {
    override func all(size: Int? = nil) async throws -> [PersonDTO] { throw APIError.unknown }
}
private final class ParentNavigationSearch: SearchRepository {
    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO { throw APIError.unknown }
}

@MainActor
private final class ParentNavigationGate<Value> {
    let started = XCTestExpectation(description: "A parent album read is held")
    private var hasStarted = false
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []
    func value() async throws -> Value {
        if !hasStarted { hasStarted = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func complete(_ value: Result<Value, Error>) {
        guard result == nil else { return }
        result = value
        let current = waiters
        waiters = []
        current.forEach { $0.resume(with: value) }
    }
}
