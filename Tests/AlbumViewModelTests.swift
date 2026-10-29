import XCTest
@testable import ImmichApp

@MainActor
final class AlbumListViewModelTests: XCTestCase {
    var mockRepo: MockAlbumRepository!
    var viewModel: AlbumListViewModel!

    override func setUp() async throws {
        try await super.setUp()
        // Potret lokal BERTAHAN antar-run, dan `loadAlbums` sekarang membacanya
        // lebih dulu. Tanpa dibersihkan, test yang menguji kegagalan akan
        // menemukan daftar yang sudah terisi dari run sebelumnya — dan lulus
        // atau gagal tergantung urutan eksekusi.
        LocalSnapshot.clearAll()
        mockRepo = MockAlbumRepository(api: makeStubAPIClient())
        viewModel = AlbumListViewModel(repo: mockRepo)
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    private func makeAlbum(
        id: String,
        name: String,
        shared: Bool = false,
        assetCount: Int = 0,
        thumbnailID: String? = nil
    ) -> AlbumResponseDTO {
        AlbumResponseDTO(
            id: id,
            albumName: name,
            description: nil,
            assetCount: assetCount,
            albumThumbnailAssetId: thumbnailID,
            shared: shared,
            createdAt: Date(),
            assets: nil
        )
    }

    func testInitialState() {
        XCTAssertTrue(viewModel.albums.isEmpty)
        XCTAssertFalse(viewModel.showCreateSheet)
        XCTAssertNil(viewModel.actionError)
        if case .idle = viewModel.phase {
            // Success
        } else {
            XCTFail("Expected idle phase")
        }
    }

    func testLoadAlbumsSuccess() async {
        mockRepo.mockAlbums = [
            makeAlbum(id: "1", name: "Summer", assetCount: 10),
            makeAlbum(id: "2", name: "Shared Album", shared: true, assetCount: 5),
        ]

        await viewModel.loadAlbums()

        XCTAssertEqual(viewModel.albums.map(\.id), ["1", "2"])
        XCTAssertEqual(viewModel.albums.map(\.shared), [false, true])
        if case .loaded = viewModel.phase {
            // Success
        } else {
            XCTFail("Expected loaded phase")
        }
    }

    func testLoadAlbumsError() async {
        mockRepo.shouldFailAll = true

        await viewModel.loadAlbums()

        if case .failed = viewModel.phase {
            XCTAssertTrue(viewModel.albums.isEmpty)
        } else {
            XCTFail("Expected failed phase")
        }
    }

    func testCreateAlbum() async {
        mockRepo.mockCreateResult = makeAlbum(id: "new-1", name: "New Album")

        let error = await viewModel.createAlbum(
            name: "New Album", description: "", assetIds: [])

        XCTAssertNil(error)
        XCTAssertTrue(viewModel.albums.contains { $0.id == "new-1" })
    }

    func testCreateAlbumEmptyName() async {
        let error = await viewModel.createAlbum(
            name: "", description: "", assetIds: [])

        XCTAssertNil(error)
        XCTAssertTrue(viewModel.albums.isEmpty)
    }

    func testCreateAlbumFailureReturnsErrorAndKeepsListPhase() async {
        mockRepo.mockAlbums = [makeAlbum(id: "1", name: "Existing")]
        await viewModel.loadAlbums()

        mockRepo.shouldFailCreate = true
        let error = await viewModel.createAlbum(
            name: "Doomed", description: "", assetIds: [])

        // Kegagalan sheet DIKEMBALIKAN; `phase` milik daftar dan harus tetap
        // loaded, daftarnya pun tidak boleh tersentuh.
        XCTAssertNotNil(error)
        XCTAssertEqual(viewModel.albums.count, 1)
        if case .loaded = viewModel.phase {
            // Success
        } else {
            XCTFail("Expected phase to stay loaded after create failure")
        }
    }

    func testDeleteAlbum() async {
        viewModel.albums = [makeAlbum(id: "1", name: "To Delete")]

        await viewModel.deleteAlbum("1")

        XCTAssertTrue(viewModel.albums.isEmpty)
    }

    func testDeleteAlbumFailureKeepsAlbum() async {
        viewModel.albums = [makeAlbum(id: "1", name: "Sticky")]
        mockRepo.shouldFailDelete = true

        await viewModel.deleteAlbum("1")

        XCTAssertEqual(viewModel.albums.count, 1)
    }

    func testApplyContentsUpdatesCountAndReplacesMissingCover() {
        viewModel.albums = [
            makeAlbum(
                id: "1",
                name: "Changing",
                assetCount: 3,
                thumbnailID: "removed-cover")
        ]
        let older = AssetLite(
            id: "older",
            isVideo: false,
            ratio: 1,
            thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1))
        let newer = AssetLite(
            id: "newer",
            isVideo: false,
            ratio: 1,
            thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 2))

        viewModel.applyContents([older, newer], to: "1")

        XCTAssertEqual(viewModel.albums[0].assetCount, 2)
        XCTAssertEqual(viewModel.albums[0].albumThumbnailAssetId, "newer")
    }

    func testRemoveDeletedAlbumUpdatesSharedList() {
        viewModel.albums = [
            makeAlbum(id: "1", name: "Deleted"),
            makeAlbum(id: "2", name: "Kept")
        ]

        viewModel.removeDeletedAlbum("1")

        XCTAssertEqual(viewModel.albums.map(\.id), ["2"])
    }
}

class MockAlbumRepository: AlbumRepository {
    var mockAlbums: [AlbumResponseDTO] = []
    var mockCreateResult: AlbumResponseDTO?
    var shouldFailAll = false
    var shouldFailCreate = false
    var shouldFailDelete = false

    override func all() async throws -> [AlbumResponseDTO] {
        if shouldFailAll {
            throw APIError.unknown
        }
        return mockAlbums
    }

    override func create(
        name: String,
        description: String?,
        assetIds: [String]
    ) async throws -> AlbumResponseDTO {
        if shouldFailCreate {
            throw APIError.server(status: 500, message: "create failed")
        }
        guard let mockCreateResult else {
            throw APIError.unknown
        }
        return mockCreateResult
    }

    override func delete(_ id: String) async throws {
        if shouldFailDelete {
            throw APIError.unknown
        }
        mockAlbums.removeAll { $0.id == id }
    }
}
