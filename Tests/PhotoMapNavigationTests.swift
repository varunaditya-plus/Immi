import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapNavigationTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-map-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    override func tearDown() async throws {
        let container = store.modelContainer
        store = nil
        try container.erase()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testUnfilteredLibraryMapDoesNotRestrictTheServerToPartiallyCachedPhotos() {
        let cached = [photo()]
        XCTAssertNil(PhotoMapNavigation.libraryIDs(for: cached, options: .init()))
        XCTAssertNil(PhotoMapNavigation.libraryIDs(for: cached, options: .init(sort: .recentlyAdded)),
            "Changing the sort must not hide uncached locations")
    }

    func testFilteredLibraryMapKeepsTheActualAdmittedPhotoScope() {
        let favorite = photo()
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [favorite], options: .init(filters: [.favorites])), [favorite.id])
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [], options: .init(filters: [.favorites])), [],
            "An empty filtered collection must not become the whole library")
        XCTAssertEqual(PhotoMapNavigation.libraryIDs(for: [favorite], options: .init(showsScreenshots: false)), [favorite.id])
    }

    func testDetailNavigationRejectsArchivedLockedAndTrashedMetadataEvenBeforeTheStoreLearnsOfIt() {
        let publicPhoto = makeTestAsset(id: UUID().uuidString)
        var archived = makeTestAsset(id: UUID().uuidString, isArchived: true)
        archived.visibility = "archive"
        var locked = makeTestAsset(id: UUID().uuidString)
        locked.visibility = "locked"
        let trashed = makeTestAsset(id: UUID().uuidString, isTrashed: true)

        XCTAssertTrue(PhotoMapNavigation.allowsNavigation(to: publicPhoto, dataManager: store))
        for asset in [archived, locked, trashed] {
            XCTAssertFalse(PhotoMapNavigation.allowsNavigation(to: asset, dataManager: store),
                "Known non-timeline metadata cannot link to a map that deliberately excludes the photo")
        }
    }

    func testLivePrivacyChangesRemoveDetailAndCollectionMapScopesDespiteStalePublicMetadata() throws {
        let publicPhoto = makeTestAsset(id: UUID().uuidString)
        let selected = AssetLite(publicPhoto)
        XCTAssertTrue(PhotoMapNavigation.allowsNavigation(to: publicPhoto, dataManager: store))
        XCTAssertEqual(PhotoMapNavigation.ids(for: [selected], dataManager: store), [publicPhoto.id])

        for visibility in ["archive", "locked"] {
            try store.setAssetVisibility([publicPhoto.id], to: visibility)
            XCTAssertFalse(PhotoMapNavigation.allowsNavigation(to: publicPhoto, dataManager: store))
            XCTAssertTrue(PhotoMapNavigation.ids(for: [selected], dataManager: store).isEmpty,
                "An archive-only collection must not advertise an empty map")
            try store.setAssetVisibility([publicPhoto.id], to: "timeline")
            XCTAssertTrue(PhotoMapNavigation.allowsNavigation(to: publicPhoto, dataManager: store))
            XCTAssertEqual(PhotoMapNavigation.ids(for: [selected], dataManager: store), [publicPhoto.id])
        }

        RemovedAssets.shared.remove([publicPhoto.id], reason: .trashed)
        defer { RemovedAssets.shared.restore([publicPhoto.id]) }
        XCTAssertFalse(PhotoMapNavigation.allowsNavigation(to: publicPhoto, dataManager: store))
        XCTAssertTrue(PhotoMapNavigation.ids(for: [selected], dataManager: store).isEmpty)
    }

    func testMixedCollectionMapScopeKeepsPublicPhotosAndRejectsOnlyRestrictedMembers() throws {
        let publicPhoto = photo(), archived = photo(), locked = photo()
        try store.setAssetVisibility([archived.id], to: "archive")
        try store.setAssetVisibility([locked.id], to: "locked")

        XCTAssertEqual(PhotoMapNavigation.ids(for: [publicPhoto, archived, locked], dataManager: store), [publicPhoto.id])
        XCTAssertTrue(PhotoMapNavigation.ids(for: [], dataManager: store).isEmpty)
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }
}
