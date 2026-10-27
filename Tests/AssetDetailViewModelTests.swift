import XCTest
@testable import ImmichApp

@MainActor
final class AssetDetailViewModelTests: XCTestCase {
    var mockRepo: MockAssetDetailRepository!
    var viewModel: AssetDetailViewModel!

    override func setUp() async throws {
        try await super.setUp()
        clearSnapshots()
        mockRepo = MockAssetDetailRepository(api: makeStubAPIClient())
        viewModel = AssetDetailViewModel(repo: mockRepo)
    }

    override func tearDown() async throws {
        clearSnapshots()
        try await super.tearDown()
    }

    private func clearSnapshots() {
        for id in ["asset-123", "invalid-id"] {
            LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id))
        }
    }

    func testInitialState() {
        XCTAssertNil(viewModel.detail)
        XCTAssertNil(viewModel.actionError)
        if case .idle = viewModel.phase {
            // Success
        } else {
            XCTFail("Expected idle phase")
        }
    }

    func testLoadAssetSuccess() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123", thumbhash: "hash")

        await viewModel.load("asset-123")

        XCTAssertEqual(viewModel.detail?.id, "asset-123")
        XCTAssertEqual(viewModel.detail?.originalFileName, "photo.jpg")
        if case .loaded = viewModel.phase {
            // Success
        } else {
            XCTFail("Expected loaded phase")
        }
    }

    func testLoadAssetError() async {
        mockRepo.shouldFail = true

        await viewModel.load("invalid-id")

        if case .failed = viewModel.phase {
            XCTAssertNil(viewModel.detail)
        } else {
            XCTFail("Expected failed phase")
        }
    }

    func testToggleFavorite() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123", isFavorite: false)
        await viewModel.load("asset-123")

        await viewModel.toggleFavorite("asset-123")

        XCTAssertTrue(viewModel.detail?.isFavorite ?? false)
        XCTAssertTrue(mockRepo.mockAsset?.isFavorite ?? false)
        XCTAssertEqual(mockRepo.favoriteRequests.map(\.id), ["asset-123"])
        XCTAssertEqual(mockRepo.favoriteRequests.map(\.value), [true])
        XCTAssertNil(viewModel.actionError)

        await viewModel.toggleFavorite("asset-123")
        XCTAssertFalse(viewModel.detail?.isFavorite ?? true)
        XCTAssertEqual(mockRepo.favoriteRequests.map(\.value), [true, false])
    }

    func testToggleFavoriteFailureSetsActionErrorAndKeepsState() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123", isFavorite: false)
        await viewModel.load("asset-123")

        mockRepo.shouldFail = true
        await viewModel.toggleFavorite("asset-123")

        XCTAssertNotNil(viewModel.actionError)
        XCTAssertFalse(viewModel.detail?.isFavorite ?? true)
        XCTAssertEqual(mockRepo.favoriteRequests.map(\.id), ["asset-123"])
        XCTAssertEqual(mockRepo.favoriteRequests.map(\.value), [true])
        XCTAssertEqual(mockRepo.mockAsset?.isFavorite, false)
    }

    func testToggleArchive() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123", isArchived: false)
        await viewModel.load("asset-123")

        await viewModel.toggleArchive("asset-123")

        XCTAssertTrue(viewModel.detail?.isArchived ?? false)
        // Repository translates archive toggle into a visibility update.
        XCTAssertEqual(mockRepo.lastVisibility, "archive")

        await viewModel.toggleArchive("asset-123")
        XCTAssertFalse(viewModel.detail?.isArchived ?? true)
        XCTAssertEqual(mockRepo.lastVisibility, "timeline")
    }

    func testDeleteSuccessReturnsTrue() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123")
        await viewModel.load("asset-123")

        let deleted = await viewModel.delete("asset-123")

        XCTAssertTrue(deleted)
        XCTAssertNil(viewModel.actionError)
        XCTAssertEqual(mockRepo.deletedIds, ["asset-123"])
    }

    func testDeleteFailureReturnsFalseAndSetsActionError() async {
        mockRepo.mockAsset = makeTestAsset(id: "asset-123")
        await viewModel.load("asset-123")

        mockRepo.shouldFail = true
        let deleted = await viewModel.delete("asset-123")

        XCTAssertFalse(deleted)
        XCTAssertNotNil(viewModel.actionError)
    }

    func testDownloadOriginalSuccess() async {
        let expected = Data([0xFF, 0xD8, 0xFF, 0xE0])
        mockRepo.mockDownloadData = expected

        let data = await viewModel.downloadOriginal("asset-123")

        XCTAssertEqual(data, expected)
        XCTAssertNil(viewModel.actionError)
    }

    func testDownloadOriginalFailureReturnsNil() async {
        mockRepo.shouldFail = true

        let data = await viewModel.downloadOriginal("asset-123")

        XCTAssertNil(data)
        XCTAssertNotNil(viewModel.actionError)
    }

    func testRetry() async {
        mockRepo.shouldFail = true
        await viewModel.load("asset-123")

        if case .failed = viewModel.phase {
            // Expected
        } else {
            XCTFail("Expected failed phase")
        }

        mockRepo.shouldFail = false
        mockRepo.mockAsset = makeTestAsset(id: "asset-123")

        await viewModel.retry("asset-123")

        if case .loaded = viewModel.phase {
            XCTAssertEqual(viewModel.detail?.id, "asset-123")
        } else {
            XCTFail("Expected loaded phase after retry")
        }
    }
}

class MockAssetDetailRepository: AssetDetailRepository {
    var mockAsset: AssetResponseDTO?
    var shouldFail = false
    var mockDownloadData = Data()
    var deletedIds: [String] = []
    var lastVisibility: String?
    private(set) var favoriteRequests: [(id: String, value: Bool)] = []

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        if shouldFail {
            throw APIError.unknown
        }
        guard let mockAsset else {
            throw APIError.unknown
        }
        return mockAsset
    }

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        favoriteRequests.append((id, value))
        if shouldFail {
            throw APIError.unknown
        }
        guard mockAsset?.id == id else { throw APIError.unknown }
        mockAsset?.isFavorite = value
    }

    override func toggleArchive(_ id: String, to value: Bool) async throws {
        if shouldFail {
            throw APIError.unknown
        }
        guard mockAsset?.id == id else { throw APIError.unknown }
        lastVisibility = value ? "archive" : "timeline"
        mockAsset?.isArchived = value
    }

    override func delete(_ id: String) async throws {
        if shouldFail {
            throw APIError.unknown
        }
        deletedIds.append(id)
    }

    override func downloadOriginal(_ id: String) async throws -> Data {
        if shouldFail {
            throw APIError.unknown
        }
        return mockDownloadData
    }
}
