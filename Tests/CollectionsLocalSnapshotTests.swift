import Photos
import SwiftData
import SwiftUI
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsLocalSnapshotTests: SimulatorHostedTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []
    private weak var fixtureModel: LibraryViewModel?
    private weak var fixtureManager: SwiftDataManager?
    private var fixtureContainer: ModelContainer?

    override func tearDown() async throws {
        try await super.tearDown()
        try await waitUntil("Hosted views and tasks release the fixture before its store is erased") {
            self.fixtureModel == nil && self.fixtureManager == nil
        }
        guard fixtureModel == nil, fixtureManager == nil else { return }
        try fixtureContainer?.erase()
        fixtureContainer = nil
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suites.removeAll()
    }

    func testCompletedDeviceScanRefreshesFeaturedMetadataWithoutAnotherInvalidation() async throws {
        let suite = "collections-local-snapshot-\(UUID())"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        fixtureManager = manager
        fixtureContainer = manager.modelContainer
        let older = photo("older", offset: 0)
        let newer = photo("newer", offset: 60)
        let initial = LocalPhotoScan(photos: [older, newer], albumTitles: [:])
        let held = CollectionsSnapshotScan()
        var calls = 0
        let library = LocalPhotoLibrary(defaults: defaults, reader: .init(
            authorizationStatus: { .authorized },
            requestAuthorization: { XCTFail("Synthetic authorized library must not request permission"); return .authorized },
            photosInAlbums: { ids in
                XCTAssertEqual(ids, ["synthetic-album"])
                calls += 1
                return calls == 1 ? initial : await held.value()
            }))
        library.selectedAlbumIDs = ["synthetic-album"]
        await library.load()
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api), assetRepo: AssetDetailRepository(api: api),
            dataManager: manager, localPhotos: { library.photos })
        fixtureModel = model
        let window = try await host(LibraryView(isActive: false, viewModel: model, localLibrary: library))
        let olderID = LocalPhotoLibrary.assetID(for: older.id)
        let newerID = LocalPhotoLibrary.assetID(for: newer.id)
        try await waitUntil("The real Collections screen curates the initial selected snapshots") {
            model.featuredPhotos.first?.id == newerID
        }
        XCTAssertTrue(model.featuredPhotos.allSatisfy { !$0.isFavorite })

        library.libraryDidChange()
        let invalidation = library.revision
        let refresh = Task { await library.load() }
        addTeardownBlock { await held.finish(initial); await refresh.value }
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertEqual(library.photos, initial.photos, "Full-access invalidation precedes the new snapshot")
        XCTAssertEqual(model.featuredPhotos.first?.id, newerID)
        _ = try await screenshot(window)

        var favorite = older
        favorite.isFavorite = true
        held.finish(LocalPhotoScan(photos: [favorite, newer], albumTitles: [:]))
        await refresh.value

        try await waitUntil("Completed snapshots refresh curation even when invalidation has already been handled") {
            model.featuredPhotos.first?.id == olderID && model.featuredPhotos.first?.isFavorite == true
        }
        let featured = try XCTUnwrap(model.featuredPhotos.first)
        XCTAssertEqual(PhotoAssetAccessibility.value(for: featured), String(localized: "Favorite"))
        XCTAssertEqual(model.recentDays.flatMap(\.assets).first(where: { $0.id == olderID })?.isFavorite, true)
        XCTAssertEqual(library.revision, invalidation, "Publishing a scan must not start an invalidation loop")
        XCTAssertEqual(calls, 2)
        _ = try await screenshot(window)
    }

    private func photo(_ name: String, offset: TimeInterval) -> LocalPhoto {
        let date = Date(timeIntervalSince1970: 1_793_188_800 + offset)
        return LocalPhoto(id: "\(name)-\(UUID())", createdAt: date, modifiedAt: date,
            isVideo: false, isLivePhoto: false, duration: nil, ratio: 1)
    }
}

@MainActor
private final class CollectionsSnapshotScan {
    let started = XCTestExpectation(description: "The replacement selected-photo scan is held")
    private var continuation: CheckedContinuation<LocalPhotoScan, Never>?

    func value() async -> LocalPhotoScan {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: LocalPhotoScan) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
