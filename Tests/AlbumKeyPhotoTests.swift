import XCTest
@testable import ImmichApp

@MainActor
final class AlbumKeyPhotoTests: XCTestCase {
    private var directories: [URL] = []
    private var snapshots: [String] = []

    override func tearDown() async throws {
        snapshots.forEach { LocalSnapshot.remove(LocalSnapshot.Key.album($0)) }
        LocalSnapshot.remove(LocalSnapshot.Key.albumsList)
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testChoosingAKeyPhotoRequiresMembershipAndPreservesCompleteAlbumContents() async throws {
        let f = try await fixture()
        let invalid = await f.model.setKeyPhoto("not-a-member", for: f.album)
        XCTAssertNil(invalid)
        XCTAssertTrue(f.repository.calls.isEmpty)

        let result = await f.model.setKeyPhoto(f.photos[1].id, for: f.album)
        let chosen = try XCTUnwrap(result)

        XCTAssertEqual(chosen.albumThumbnailAssetId, f.photos[1].id)
        XCTAssertEqual(chosen.albumName, f.album.albumName)
        XCTAssertEqual(chosen.assetCount, 2)
        XCTAssertEqual(f.repository.calls.map(\.0), [f.photos[1].id])
        XCTAssertEqual(f.repository.calls.map(\.1), [f.album.id])
        XCTAssertEqual(f.model.assets.map(\.id), f.photos.map(\.id))
        let saved = LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.album(f.album.id))
        XCTAssertEqual(saved?.map(\.id), f.photos.map(\.id))
    }

    func testFailedKeyPhotoKeepsTheCurrentCoverAndLoadedGrid() async throws {
        let f = try await fixture()
        f.repository.operation = { throw APIError.server(status: 403, message: "Read only") }

        let changed = await f.model.setKeyPhoto(f.photos[1].id, for: f.album)

        XCTAssertNil(changed)
        XCTAssertNotNil(f.model.actionError)
        XCTAssertEqual(f.album.albumThumbnailAssetId, f.photos[0].id)
        XCTAssertEqual(f.model.assets.map(\.id), f.photos.map(\.id))
        XCTAssertNotNil(f.model.phase.value)
    }

    func testLateCoverResultCannotPublishAfterAlbumDeletionOrAccountChange() async throws {
        for accountChange in [false, true] {
            let f = try await fixture()
            let gate = KeyPhotoGate()
            f.repository.operation = { try await gate.wait() }
            let changing = Task { await f.model.setKeyPhoto(f.photos[1].id, for: f.album) }
            addTeardownBlock { await gate.finish(); _ = await changing.value }
            await fulfillment(of: [gate.started], timeout: 2)
            if accountChange { LocalSnapshot.clearAll() }
            else {
                let deleted = await f.model.deleteAlbum(f.album.id)
                XCTAssertTrue(deleted)
            }
            gate.finish()

            let result = await changing.value
            XCTAssertNil(result)
            XCTAssertNil(f.model.actionError)
        }
    }

    func testExplicitCoverCallbackReachesBothParentsWithoutStaleRenameOverwritingIt() throws {
        let api = makeStubAPIClient()
        let model = AlbumListViewModel(repo: AlbumRepository(api: api))
        let original = album(id: "parent", photos: [photo("first"), photo("second")])
        model.albums = [original]
        var changes: [(String, String)] = []
        let view = AlbumsListView(viewModel: model, onAlbumCoverChanged: { changes.append(($0, $1)) })
        let detail = view.albumDestination(for: original, using: model)

        try XCTUnwrap(detail.onCoverChanged)(original.id, "second")
        var renamed = original
        renamed.albumName = "New name"
        model.applyAlbumUpdate(renamed)

        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "second")
        XCTAssertEqual(model.albums.first?.albumName, "New name")
        XCTAssertEqual(changes.first?.0, original.id)
        XCTAssertEqual(changes.first?.1, "second")
        XCTAssertEqual(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)?.first?.albumThumbnailAssetId, "second")
    }

    private func fixture() async throws -> KeyPhotoFixture {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("key-photo-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        snapshots.append(id)
        let db = SwiftDataManager(storeURL: directory.appendingPathComponent("store"), backupJournalURL: directory.appendingPathComponent("journal.json"))
        let photos = [photo(UUID().uuidString), photo(UUID().uuidString)]
        try db.restoreToTimeline(photos)
        let api = makeStubAPIClient()
        let repository = KeyPhotoRepository(api: api)
        let timeline = KeyPhotoTimeline(api: api)
        timeline.result = photos
        let model = AlbumDetailViewModel(timelineRepo: timeline, albumRepo: repository,
            assetRepo: AssetDetailRepository(api: api), dataManager: db)
        let loaded = await model.loadAlbumDetail(id)
        XCTAssertTrue(loaded)
        return KeyPhotoFixture(model: model, repository: repository, album: album(id: id, photos: photos), photos: photos)
    }

    private func photo(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }

    private func album(id: String, photos: [AssetLite]) -> AlbumResponseDTO {
        .init(id: id, albumName: "Album", description: "Description", assetCount: photos.count,
              albumThumbnailAssetId: photos.first?.id, shared: false, createdAt: .distantPast, assets: nil)
    }
}

private struct KeyPhotoFixture {
    let model: AlbumDetailViewModel
    let repository: KeyPhotoRepository
    let album: AlbumResponseDTO
    let photos: [AssetLite]
}

private final class KeyPhotoRepository: AlbumRepository {
    var calls: [(String, String)] = []
    var operation: () async throws -> Void = {}
    override func setKeyPhoto(_ assetID: String, for albumID: String) async throws {
        calls.append((assetID, albumID))
        try await operation()
    }
    override func delete(_ id: String) async throws {}
}

private final class KeyPhotoTimeline: TimelineRepository {
    var result: [AssetLite] = []
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { result }
}

@MainActor
private final class KeyPhotoGate {
    let started = XCTestExpectation(description: "Key-photo request reached the server")
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    func wait() async throws {
        started.fulfill()
        if completed { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        completed = true
        continuation?.resume()
        continuation = nil
    }
}
