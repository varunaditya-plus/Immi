import XCTest
@testable import ImmichApp

@MainActor
final class LibraryAlbumRetrievalTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        clearSnapshots()
    }

    override func tearDown() async throws {
        clearSnapshots()
        try await super.tearDown()
    }

    func testPickerKeepsAllAlbumsWhileTheLibraryPreviewStaysBounded() async {
        let repository = MockAlbumRepository(api: makeStubAPIClient())
        repository.mockAlbums = albums(count: 25)
        repository.mockAlbums[0].updatedAt = Date(timeIntervalSince1970: 100)
        let model = model(repository)
        let expected = ["album-0"] + (1..<25).reversed().map { "album-\($0)" }

        await model.load()

        XCTAssertEqual(model.albums.map(\.id), expected)
        XCTAssertEqual(model.recentAlbums.map(\.id), Array(expected.prefix(15)))
        XCTAssertTrue(model.albums.contains { $0.albumName == "Album 1" })
        XCTAssertFalse(model.recentAlbums.contains { $0.id == "album-1" })
        let saved = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
        XCTAssertEqual(saved?.map(\.id), expected)
    }

    func testOfflineReloadRestoresOlderAlbumsBeyondThePreview() async {
        let repository = MockAlbumRepository(api: makeStubAPIClient())
        repository.mockAlbums = albums(count: 25)
        let first = model(repository)
        await first.load()
        let expected = first.albums.map(\.id)
        repository.shouldFailAll = true
        let reopened = model(repository)

        await reopened.load()

        XCTAssertEqual(reopened.albums.map(\.id), expected)
        XCTAssertEqual(reopened.albums.count, 25)
        XCTAssertEqual(reopened.recentAlbums.count, 15)
        XCTAssertEqual(reopened.albums.last?.id, "album-0")
    }

    func testAlbumOnlyRefreshKeepsNewOlderAlbumsInThePickerAndSnapshot() async {
        let repository = MockAlbumRepository(api: makeStubAPIClient())
        repository.mockAlbums = albums(count: 25)
        let model = model(repository)
        await model.load()
        let preview = model.recentAlbums.map(\.id)
        repository.mockAlbums.append(album(id: "older", date: -100))

        await model.refreshAlbums()

        XCTAssertEqual(model.albums.count, 26)
        XCTAssertEqual(model.albums.last?.id, "older")
        XCTAssertEqual(model.recentAlbums.map(\.id), preview)
        let saved = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
        XCTAssertEqual(saved?.count, 26)
        XCTAssertEqual(saved?.last?.id, "older")
    }

    func testAnEmptyServerResultClearsTheCompleteListAndPreview() async {
        let repository = MockAlbumRepository(api: makeStubAPIClient())
        repository.mockAlbums = albums(count: 25)
        let model = model(repository)
        await model.load()
        XCTAssertEqual(model.albums.count, 25)
        repository.mockAlbums = []

        await model.refreshAlbums()

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(model.recentAlbums.isEmpty)
        let saved = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)
        XCTAssertEqual(saved?.count, 0)
    }

    func testASmallAlbumCollectionIsNotPaddedOrTruncated() async {
        let repository = MockAlbumRepository(api: makeStubAPIClient())
        repository.mockAlbums = albums(count: 3)
        let model = model(repository)

        await model.load()

        XCTAssertEqual(model.albums.map(\.id), ["album-2", "album-1", "album-0"])
        XCTAssertEqual(model.recentAlbums.map(\.id), model.albums.map(\.id))
    }

    private func model(_ repository: AlbumRepository) -> LibraryViewModel {
        let api = makeStubAPIClient()
        return LibraryViewModel(
            memoriesRepo: EmptyLibraryMemories(api: api), albumRepo: repository,
            peopleRepo: EmptyLibraryPeople(api: api), searchRepo: EmptyLibrarySearch(api: api),
            assetRepo: AssetDetailRepository(api: api))
    }

    private func albums(count: Int) -> [AlbumResponseDTO] {
        (0..<count).map { album(id: "album-\($0)", name: "Album \($0)", date: TimeInterval($0)) }
    }

    private func album(id: String, name: String = "Older album", date: TimeInterval) -> AlbumResponseDTO {
        AlbumResponseDTO(id: id, albumName: name, description: nil, assetCount: 0,
            albumThumbnailAssetId: nil, shared: false, createdAt: Date(timeIntervalSince1970: date), assets: nil)
    }

    private func clearSnapshots() {
        for key in [LocalSnapshot.Key.libraryAlbums, LocalSnapshot.Key.libraryPeople, LocalSnapshot.Key.libraryFavorites] {
            LocalSnapshot.remove(key)
        }
    }
}

private final class EmptyLibraryMemories: MemoriesRepository {
    override func getMemories() async throws -> [MemoryDTO] { [] }
}

private final class EmptyLibraryPeople: PeopleRepository {
    override func all(size: Int? = nil) async throws -> [PersonDTO] { [] }
}

private final class EmptyLibrarySearch: SearchRepository {
    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: [], total: 0, nextPage: nil))
    }
}
