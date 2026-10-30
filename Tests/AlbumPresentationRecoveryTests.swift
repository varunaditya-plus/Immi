import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumPresentationRecoveryTests: SimulatorHostedTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []
    private var snapshotIDs: [String] = []
    private var trashedIDs: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        snapshotIDs.forEach { LocalSnapshot.remove(LocalSnapshot.Key.album($0)) }
        DeletedServerAssetRegistry.shared.restore(trashedIDs)
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func testPersistedNoMatchAlbumFilterHasAnActualRecoveryButtonThatRestoresItsGrid() async throws {
        let db = try database()
        let photos = [photo(), photo()]
        try db.restoreToTimeline(photos)
        let albumID = UUID().uuidString
        snapshotIDs.append(albumID)
        let album = AlbumResponseDTO(id: albumID, albumName: "Filtered album", description: nil,
            assetCount: photos.count, albumThumbnailAssetId: photos.first?.id,
            shared: false, createdAt: .distantPast, assets: nil)
        let suite = "album-filter-recovery.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let owner = BackupQueueOwner(server: "https://synthetic.example/api", userID: "test")
        AlbumsOrganizationStore(owner: owner, defaults: defaults).setPhotoFilter(.videos, albumID: albumID)
        let reopenedStore = AlbumsOrganizationStore(owner: owner, defaults: defaults)
        XCTAssertEqual(reopenedStore.value.photoFilters[albumID], .videos)
        let api = makeStubAPIClient()
        let timeline = RecoveryTimelineRepository(api: api)
        timeline.photos = photos
        let model = AlbumDetailViewModel(timelineRepo: timeline, albumRepo: AlbumRepository(api: api),
            assetRepo: AssetDetailRepository(api: api), dataManager: db)
        let window = try await host(NavigationStack {
            AlbumDetailView(album: album, organizationStore: reopenedStore, viewModel: model)
        })
        try await waitUntil("The reopened album has loaded its full membership") { model.phase.value != nil }
        XCTAssertTrue(reopenedStore.value.orderedPhotos(model.assets, albumID: albumID).isEmpty)
        XCTAssertNil(photoCollection(in: window))

        try await activateAccessibilityButton(named: "Remove Filter", in: window)

        try await waitUntil("The real recovery action restores the full photo grid and its add control") {
            guard let collection = self.photoCollection(in: window) else { return false }
            return (0..<collection.numberOfSections).reduce(0) { $0 + collection.numberOfItems(inSection: $1) } == photos.count + 2
        }
        XCTAssertEqual(reopenedStore.value.photoFilters[albumID], .all)
        XCTAssertEqual(AlbumsOrganizationStore(owner: owner, defaults: defaults).value.photoFilters[albumID], .all)
        XCTAssertEqual(model.assets.map(\.id), photos.map(\.id))
        XCTAssertEqual(timeline.reads, 1, "Clearing the presentation filter must not reload or mutate membership")
    }

    func testMountedPhotoReorderSheetDropsNewlyLockedAndTrashedPhotosBeforeSaving() async throws {
        let db = try database()
        let years = [2006, 2008, 2009]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let photos = try years.map { year in
            photo(createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: 6, day: 15, hour: 12))))
        }
        try db.restoreToTimeline(photos)
        var saved: [String]?
        let window = try await host(AlbumPhotoReorderSheet(assets: photos,
            visibilityPolicy: AssetVisibilityPolicy(scope: .collection, dataManager: db)) { saved = $0 })
        let initialText = try await waitForRenderedYears(Set(years.map(String.init)), in: window)
        for year in years {
            XCTAssertTrue(initialText.contains(String(year)),
                "Each admitted photo must initially render its distinct capture year: \(initialText)")
        }

        try db.setAssetVisibility([photos[1].id], to: "locked")
        DeletedServerAssetRegistry.shared.record([photos[2].id], permanently: false)
        trashedIDs.append(photos[2].id)

        let filteredText = try await waitForRenderedYears(["2006"], excluding: ["2008", "2009"], in: window)
        XCTAssertTrue(filteredText.contains("2006"), "The admitted photo must remain visibly rendered: \(filteredText)")
        XCTAssertFalse(filteredText.contains("2008"), "The newly locked photo must disappear without reopening: \(filteredText)")
        XCTAssertFalse(filteredText.contains("2009"), "The newly trashed photo must disappear without reopening: \(filteredText)")
        try await activateAccessibilityButton(named: "Done", in: window)
        XCTAssertEqual(saved, [photos[0].id])
    }

    private func database() throws -> SwiftDataManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return SwiftDataManager(storeURL: directory.appendingPathComponent("store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
    }

    private func photo(createdAt: Date = Date()) -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: createdAt)
    }

    private func photoCollection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView,
           collection.visibleCells.contains(where: { $0 is PhotoGridCell || $0 is PhotoGridHostCell }) { return collection }
        for child in view.subviews {
            if let collection = photoCollection(in: child) { return collection }
        }
        return nil
    }

    private func waitForRenderedYears(_ expected: Set<String>, excluding excluded: Set<String> = [],
                                      in window: UIWindow) async throws -> String {
        let deadline = Date().addingTimeInterval(4)
        var text = ""
        repeat {
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if expected.allSatisfy({ text.contains($0) }), excluded.allSatisfy({ !text.contains($0) }) { break }
        } while Date() < deadline
        return text
    }
}

private final class RecoveryTimelineRepository: TimelineRepository {
    var photos: [AssetLite] = []
    var reads = 0
    override func albumAssets(_ albumId: String) async throws -> [AssetLite] { reads += 1; return photos }
}
