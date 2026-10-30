import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsModelPublicationTests: XCTestCase {
    private var previousAlbums: [AlbumResponseDTO]?

    override func setUp() {
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
    }

    override func tearDown() {
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.libraryAlbums) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.libraryAlbums) }
    }

    func testFailedAlbumRefreshDoesNotEstablishThatPinnedAlbumsWereDeleted() async {
        let repository = CollectionsAlbumRepository(api: APIClient(session: MockSessionManager()))
        repository.result = .failure(APIError.notConnected)
        let model = model(repository)
        model.albums = [album("offline")]

        await model.refreshAlbums()

        XCTAssertFalse(model.hasLoadedAlbums)
        XCTAssertEqual(model.albums.map(\.id), ["offline"])
        repository.result = .success([])
        await model.refreshAlbums()
        XCTAssertTrue(model.hasLoadedAlbums)
        XCTAssertTrue(model.albums.isEmpty)
    }

    func testChoosingAKeyPhotoRejectsAnOlderListAndPreservesItThroughRename() async {
        let repository = CollectionsAlbumRepository(api: APIClient(session: MockSessionManager()))
        let gate = CollectionsAlbumGate()
        repository.gate = gate
        let model = model(repository)
        let stale = album("album", cover: "old-cover")
        model.albums = [stale]
        let refresh = Task { await model.refreshAlbums() }
        addTeardownBlock { await gate.finish(.failure(CancellationError())); await refresh.value }
        await fulfillment(of: [gate.started], timeout: 2)

        model.applyAlbumCover(albumID: "album", assetID: "chosen-cover")
        var renamed = stale
        renamed.albumName = "New title"
        model.applyAlbumUpdate(renamed)
        gate.finish(.success([stale]))
        await refresh.value

        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "chosen-cover")
        XCTAssertEqual(model.albums.first?.albumName, "New title")
        let saved = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
        XCTAssertEqual(saved?.first?.albumThumbnailAssetId, "chosen-cover")
        XCTAssertEqual(saved?.first?.albumName, "New title")
    }

    private func model(_ repository: AlbumRepository) -> LibraryViewModel {
        let api = APIClient(session: MockSessionManager())
        return LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: repository,
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api))
    }

    private func album(_ id: String, cover: String? = nil) -> AlbumResponseDTO {
        AlbumResponseDTO(id: id, albumName: "Album", description: nil, assetCount: 2,
            albumThumbnailAssetId: cover, shared: false, createdAt: .distantPast, assets: nil)
    }
}

@MainActor
private final class CollectionsAlbumRepository: AlbumRepository {
    var result: Result<[AlbumResponseDTO], Error> = .success([])
    var gate: CollectionsAlbumGate?

    override func all() async throws -> [AlbumResponseDTO] {
        if let gate { return try await gate.value() }
        return try result.get()
    }
}

@MainActor
private final class CollectionsAlbumGate {
    let started = XCTestExpectation(description: "Held collection album list started")
    private var continuation: CheckedContinuation<[AlbumResponseDTO], Error>?

    func value() async throws -> [AlbumResponseDTO] {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: Result<[AlbumResponseDTO], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
