import XCTest
@testable import ImmichApp

@MainActor
final class AccountSnapshotIsolationTests: XCTestCase {
    override func setUp() async throws {
        LocalSnapshot.clearAll()
        UnreadableAssets.shared.clear()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        UnreadableAssets.shared.clear()
    }

    func testOldAssetFailureCannotPurgeTheNextAccountsPhoto() async {
        let started = expectation(description: "Old detail request started")
        let purge = expectation(description: "Old request must not purge a new account's photo")
        purge.isInverted = true
        let gate = SnapshotResultGate<Void>()
        let model = AssetDetailViewModel(repo: HeldAssetFailureRepository(
            api: makeStubAPIClient(), started: started, gate: gate))
        let load = Task { await model.load("same-asset-id") }
        await fulfillment(of: [started], timeout: 2)

        LocalSnapshot.clearAll()
        UnreadableAssets.shared.clear()
        UnreadableAssets.shared.noteSuccess()
        UnreadableAssets.shared.onPurge = { _ in purge.fulfill() }
        gate.resume(())
        await load.value

        await fulfillment(of: [purge], timeout: 0.7)
    }

    func testCurrentAssetFailureStillReportsUnreadablePhoto() async {
        let started = expectation(description: "Current detail request started")
        let purge = expectation(description: "Current unreadable photo is reported")
        let gate = SnapshotResultGate<Void>()
        let model = AssetDetailViewModel(repo: HeldAssetFailureRepository(
            api: makeStubAPIClient(), started: started, gate: gate))
        UnreadableAssets.shared.noteSuccess()
        UnreadableAssets.shared.onPurge = { ids in
            XCTAssertEqual(ids, ["same-asset-id"])
            purge.fulfill()
        }
        let load = Task { await model.load("same-asset-id") }
        await fulfillment(of: [started], timeout: 2)
        gate.resume(())
        await load.value

        await fulfillment(of: [purge], timeout: 2)
    }

    func testCollectionResultCannotReplaceNextAccountsSnapshot() async {
        let started = expectation(description: "Collection request started")
        let gate = SnapshotResultGate<[AssetLite]>()
        let key = "account-isolation.collection"
        let model = AssetGridViewModel(
            assetRepo: MockAssetDetailRepository(api: makeStubAPIClient()),
            albumRepo: MockAlbumRepository(api: makeStubAPIClient()),
            snapshotKey: key,
            loader: {
                started.fulfill()
                return await gate.wait()
            })
        let load = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)

        LocalSnapshot.clearAll()
        let nextAccountsPhotos = [AssetLite(makeTestAsset(id: "next-account-photo"))]
        LocalSnapshot.save(nextAccountsPhotos, for: key)
        gate.resume([AssetLite(makeTestAsset(id: "previous-account-photo"))])
        await load.value

        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["next-account-photo"])
        XCTAssertTrue(model.assets.isEmpty)
    }

    func testCurrentCollectionResultStillUpdatesSnapshot() async {
        let started = expectation(description: "Collection request started")
        let gate = SnapshotResultGate<[AssetLite]>()
        let key = "account-isolation.current-collection"
        let model = AssetGridViewModel(
            assetRepo: MockAssetDetailRepository(api: makeStubAPIClient()),
            albumRepo: MockAlbumRepository(api: makeStubAPIClient()),
            snapshotKey: key,
            loader: {
                started.fulfill()
                return await gate.wait()
            })
        let load = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)

        gate.resume([AssetLite(makeTestAsset(id: "current-account-photo"))])
        await load.value

        XCTAssertEqual(model.assets.map(\.id), ["current-account-photo"])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["current-account-photo"])
    }

    func testCompletedLibraryResponseCannotPublishAfterOtherRequestsCrossAccountChange() async {
        let albumsReturned = expectation(description: "Old albums returned")
        let peopleStarted = expectation(description: "People request is held")
        let peopleGate = SnapshotResultGate<[PersonDTO]>()
        let api = makeStubAPIClient()
        let model = LibraryViewModel(
            memoriesRepo: EmptySnapshotMemoriesRepository(api: api),
            albumRepo: CompletedSnapshotAlbumsRepository(api: api, returned: albumsReturned),
            peopleRepo: HeldSnapshotPeopleRepository(api: api, started: peopleStarted, gate: peopleGate),
            searchRepo: EmptySnapshotSearchRepository(api: api),
            assetRepo: MockAssetDetailRepository(api: api))
        let load = Task { await model.load() }
        await fulfillment(of: [albumsReturned, peopleStarted], timeout: 2)

        LocalSnapshot.clearAll()
        let nextAlbum = snapshotAlbum(id: "next-account-album")
        LocalSnapshot.save([nextAlbum], for: LocalSnapshot.Key.libraryAlbums)
        peopleGate.resume([])
        await load.value

        XCTAssertEqual(
            LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)?.map(\.id),
            [nextAlbum.id])
        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertFalse(model.hasLoaded)
    }

    func testOldAlbumModelCannotOverwriteOrDeleteNextAccountsSnapshots() async {
        let repo = MockAlbumRepository(api: makeStubAPIClient())
        repo.mockAlbums = [snapshotAlbum(id: "shared-album-id")]
        let model = AlbumListViewModel(repo: repo)
        await model.loadAlbums()

        LocalSnapshot.clearAll()
        let nextAlbum = snapshotAlbum(id: "next-account-album")
        LocalSnapshot.save([nextAlbum], for: LocalSnapshot.Key.albumsList)
        LocalSnapshot.save(["next-account-photo"], for: LocalSnapshot.Key.album("shared-album-id"))

        // The repository intentionally allows the old operation to finish. The
        // model must protect storage even after a successful network result.
        await model.deleteAlbum("shared-album-id")

        XCTAssertEqual(
            LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)?.map(\.id),
            [nextAlbum.id])
        XCTAssertEqual(
            LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album("shared-album-id")),
            ["next-account-photo"])
    }
}

@MainActor
private final class SnapshotResultGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: Value) {
        XCTAssertNotNil(continuation, "Wait for the request to start before releasing it")
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private func snapshotAlbum(id: String) -> AlbumResponseDTO {
    AlbumResponseDTO(
        id: id, albumName: id, description: nil, assetCount: 1,
        albumThumbnailAssetId: nil, shared: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), assets: nil)
}

private final class CompletedSnapshotAlbumsRepository: AlbumRepository {
    private let returned: XCTestExpectation

    init(api: APIClient, returned: XCTestExpectation) {
        self.returned = returned
        super.init(api: api)
    }

    override func all() async throws -> [AlbumResponseDTO] {
        returned.fulfill()
        return [snapshotAlbum(id: "previous-account-album")]
    }
}

private final class HeldSnapshotPeopleRepository: PeopleRepository {
    private let started: XCTestExpectation
    private let gate: SnapshotResultGate<[PersonDTO]>

    init(api: APIClient, started: XCTestExpectation, gate: SnapshotResultGate<[PersonDTO]>) {
        self.started = started
        self.gate = gate
        super.init(api: api)
    }

    override func all(size: Int? = nil) async throws -> [PersonDTO] {
        started.fulfill()
        return await gate.wait()
    }
}

private final class EmptySnapshotMemoriesRepository: MemoriesRepository {
    override func getMemories() async throws -> [MemoryDTO] { [] }
}

private final class EmptySnapshotSearchRepository: SearchRepository {
    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: [], total: 0, nextPage: nil))
    }
}

private final class HeldAssetFailureRepository: AssetDetailRepository {
    private let started: XCTestExpectation
    private let gate: SnapshotResultGate<Void>

    init(api: APIClient, started: XCTestExpectation, gate: SnapshotResultGate<Void>) {
        self.started = started
        self.gate = gate
        super.init(api: api)
    }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        started.fulfill()
        await gate.wait()
        throw APIError.server(status: 400, message: "Asset no longer readable")
    }
}
