import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionCacheIntegrationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        MockURLProtocol.reset()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testCollectionFavoritePublishesTheRepositoryCacheChangeOnce() async throws {
        let (manager, repository, api, asset) = try fixture()
        let model = AssetGridViewModel(assetRepo: repository, albumRepo: AlbumRepository(api: api),
            dataManager: manager, loader: { [asset] })
        model.assets = [asset]

        await model.toggleFavorite(asset)

        XCTAssertEqual(model.assets.first?.isFavorite, true)
        XCTAssertEqual(manager.getCachedAsset(id: asset.id)?.isFavorite, true)
        XCTAssertNotNil(repository.completedRevision)
        XCTAssertEqual(manager.assetMutationRevision, repository.completedRevision,
            "The view model must not issue a second cache mutation after the repository updates it")
    }

    func testAlbumArchiveKeepsMembersAndPublishesTheRepositoryCacheChangeOnce() async throws {
        let (manager, repository, api, asset) = try fixture()
        let model = AlbumDetailViewModel(timelineRepo: TimelineRepository(api: api),
            albumRepo: AlbumRepository(api: api), assetRepo: repository, dataManager: manager)
        model.assets = [asset]

        await model.setArchived([asset.id], to: true)

        XCTAssertEqual(model.assets.map(\.id), [asset.id])
        XCTAssertEqual(manager.getCachedAsset(id: asset.id)?.isArchived, true)
        XCTAssertTrue(manager.nonTimelineAssetIDs.contains(asset.id))
        XCTAssertNotNil(repository.completedRevision)
        XCTAssertEqual(manager.assetMutationRevision, repository.completedRevision)
    }

    func testCollectionLockRemovesTheRowWithoutRepeatingTheRepositoryPrivacyWrite() async throws {
        let (manager, repository, api, asset) = try fixture()
        let model = AssetGridViewModel(assetRepo: repository, albumRepo: AlbumRepository(api: api),
            dataManager: manager, loader: { [asset] })
        model.assets = [asset]

        let succeeded = await model.setLocked([asset.id])

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertTrue(manager.nonTimelineAssetIDs.contains(asset.id))
        XCTAssertNotNil(repository.completedRevision)
        XCTAssertEqual(manager.assetMutationRevision, repository.completedRevision)
    }

    private func fixture() throws -> (SwiftDataManager, RecordingCacheAssetRepository, APIClient, AssetLite) {
        MockURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("cache.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        try manager.restoreToTimeline([asset])
        let session = MockSessionManager()
        try session.setServer("https://collection-cache.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
        MockURLProtocol.responseProvider = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (Data("{}".utf8), response, nil)
        }
        return (manager, RecordingCacheAssetRepository(api: api, manager: manager), api, asset)
    }
}

@MainActor
private final class RecordingCacheAssetRepository: AssetDetailRepository {
    private let manager: SwiftDataManager
    private(set) var completedRevision: UUID?

    init(api: APIClient, manager: SwiftDataManager) {
        self.manager = manager
        super.init(api: api, dataManager: manager)
    }

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        try await super.toggleFavorite(id, to: value)
        completedRevision = manager.assetMutationRevision
    }

    override func setVisibility(_ id: String, to value: Visibility) async throws {
        try await super.setVisibility(id, to: value)
        completedRevision = manager.assetMutationRevision
    }
}
