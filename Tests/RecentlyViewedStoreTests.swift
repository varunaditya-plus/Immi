import Observation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class RecentlyViewedStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var manager: SwiftDataManager!

    override func setUp() async throws {
        try await super.setUp()
        suite = "recently-viewed.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    override func tearDown() async throws {
        let container = manager.modelContainer
        manager = nil
        try container.erase()
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testViewsAreBoundedInVisitOrderAndRevisitsPersistFreshMetadataWithoutDuplicates() throws {
        let store = store(limit: 3)
        let photos = (0..<4).map { makeTestAsset(id: "photo-\($0)") }
        for photo in photos { store.record(photo) }
        XCTAssertEqual(store.assets.map(\.id), ["photo-3", "photo-2", "photo-1"])
        let revisited = AssetResponseDTO(id: photos[1].id, type: "IMAGE", originalFileName: "live.heic",
            fileCreatedAt: photos[1].fileCreatedAt, isFavorite: true, isArchived: false, isTrashed: false,
            duration: nil, thumbhash: nil, localDateTime: photos[1].localDateTime, exifInfo: nil,
            people: nil, livePhotoVideoId: "motion")

        store.record(revisited)

        XCTAssertEqual(store.assets.map(\.id), ["photo-1", "photo-3", "photo-2"])
        let restored = self.store(limit: 3)
        XCTAssertEqual(restored.assets.map(\.id), store.assets.map(\.id))
        XCTAssertTrue(try XCTUnwrap(restored.assets.first).isFavorite)
        XCTAssertEqual(restored.assets.first?.livePhotoVideoID, "motion")
    }

    func testServerAndAccountIsolationAndAnonymousViewsNeverPersist() {
        let current = store()
        current.record(makeTestAsset(id: "viewed"))
        XCTAssertTrue(store(user: "other").assets.isEmpty)
        XCTAssertTrue(store(server: "https://other.example/api").assets.isEmpty)
        let saved = defaults.persistentDomain(forName: suite) as NSDictionary?
        let anonymous = RecentlyViewedStore(owner: nil, defaults: defaults, dataManager: manager)

        anonymous.record(makeTestAsset(id: "anonymous"))
        anonymous.clear()

        XCTAssertTrue(anonymous.assets.isEmpty)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, saved)
        XCTAssertEqual(store().assets.map(\.id), ["viewed"])
    }

    func testExpiredStoreCannotReadRecordClearOrPatchAnotherSession() {
        let old = store()
        let viewed = makeTestAsset(id: "saved")
        old.record(viewed)
        LocalSnapshot.clearAll()
        var changed = AssetLite(viewed)
        changed.isFavorite = true

        old.record(makeTestAsset(id: "late"))
        old.clear()
        old.updateFavorites(from: [changed])
        old.updateFavorite(viewed.id, to: true)
        old.updateCaptureDate(viewed.id, to: .distantPast)

        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(old.assets.isEmpty)
        XCTAssertEqual(store().assets.map(\.id), ["saved"])
        XCTAssertFalse(store().assets.first?.isFavorite ?? true)
        XCTAssertEqual(store().assets.first?.createdAt, viewed.fileCreatedAt)
    }

    func testPrivateTrashedDeletedAndLocalPhotosCannotBeRecordedOrDisplayedThroughStaleMetadata() async throws {
        let store = store()
        let photos = (0..<4).map { _ in makeTestAsset(id: UUID().uuidString) }
        for photo in photos { store.record(photo) }
        let changed = expectation(description: "Recently viewed observes accepted privacy changes")
        withObservationTracking { _ = store.assets } onChange: { changed.fulfill() }
        try manager.setAssetVisibility([photos[0].id], to: "archive")
        try manager.setAssetVisibility([photos[1].id], to: "locked")
        RemovedAssets.shared.remove([photos[2].id], reason: .trashed)
        DeletedServerAssetRegistry.shared.record([photos[3].id], permanently: false)
        defer {
            RemovedAssets.shared.restore([photos[2].id])
            DeletedServerAssetRegistry.shared.restore([photos[3].id])
        }
        await fulfillment(of: [changed], timeout: 2)
        for photo in photos { store.record(photo) }
        var archived = makeTestAsset(id: "archive", isArchived: true)
        archived.visibility = "archive"
        var locked = makeTestAsset(id: "locked")
        locked.visibility = "locked"
        let trashed = makeTestAsset(id: "trash", isTrashed: true)
        let local = makeTestAsset(id: LocalPhotoLibrary.assetID(for: "synthetic-local"))
        for photo in [archived, locked, trashed, local] { store.record(photo) }

        XCTAssertTrue(store.assets.isEmpty)
        XCTAssertTrue(self.store().assets.isEmpty, "Relaunch must preserve current privacy filtering")
        try manager.setAssetVisibility([photos[0].id], to: "timeline")
        XCTAssertEqual(store.assets.map(\.id), [photos[0].id], "Rejected stale views must not create extra history")
    }

    func testSeparateStoresMergeVisitsAndClearTheLatestPersistedHistory() {
        let first = store(), second = store()
        first.record(makeTestAsset(id: "first"))
        second.record(makeTestAsset(id: "second"))
        XCTAssertEqual(store().assets.map(\.id), ["second", "first"])
        let staleEmpty = RecentlyViewedStore(owner: owner("another"), defaults: defaults, dataManager: manager)
        RecentlyViewedStore(owner: owner("another"), defaults: defaults, dataManager: manager)
            .record(makeTestAsset(id: "concurrent"))

        staleEmpty.clear()
        first.clear()

        XCTAssertTrue(store().assets.isEmpty)
        XCTAssertTrue(RecentlyViewedStore(owner: owner("another"), defaults: defaults, dataManager: manager).assets.isEmpty)
    }

    func testAcceptedFavoritesPreserveVisitOrderAndCannotReplaceOtherMetadataOrAddUnviewedPhotos() throws {
        let store = store()
        let first = makeTestAsset(id: "first"), second = makeTestAsset(id: "second")
        store.record(first)
        store.record(second)
        var updated = AssetLite(first)
        updated.isFavorite = true
        updated.createdAt = .distantPast

        store.updateFavorites(from: [updated, AssetLite(makeTestAsset(id: "unviewed"))])

        XCTAssertEqual(store.assets.map(\.id), ["second", "first"])
        XCTAssertTrue(store.assets.last?.isFavorite == true)
        XCTAssertEqual(store.assets.last?.createdAt, first.fileCreatedAt)
        XCTAssertTrue(self.store().assets.last?.isFavorite == true)
        try manager.restoreToTimeline([AssetLite(first), AssetLite(second)])
        store.clear()
        XCTAssertTrue(self.store().assets.isEmpty)
        XCTAssertEqual(Set(manager.timelineAssets().map(\.asset.id)), [first.id, second.id],
            "Clearing history must preserve the photos already in the library")
    }

    private func owner(_ user: String = "user", server: String = "https://recent.example/api") -> BackupQueueOwner {
        BackupQueueOwner(server: server, userID: user)
    }

    private func store(user: String = "user", server: String = "https://recent.example/api", limit: Int = 100) -> RecentlyViewedStore {
        RecentlyViewedStore(owner: owner(user, server: server), defaults: defaults, dataManager: manager, limit: limit)
    }

    func testPartialViewerUpdatesPreserveOtherFieldsAndDoNotAddOrReorderRecords() {
        let store = store()
        let first = makeTestAsset(id: "first"), second = makeTestAsset(id: "second")
        store.record(first)
        store.record(second)
        let savedDate = first.fileCreatedAt.addingTimeInterval(86_400)

        store.updateCaptureDate(first.id, to: savedDate)
        store.updateFavorite(first.id, to: true)
        store.updateCaptureDate("not-viewed", to: .distantPast)
        store.updateFavorite("not-viewed", to: true)

        XCTAssertEqual(store.assets.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.assets.last?.createdAt, savedDate)
        XCTAssertTrue(store.assets.last?.isFavorite == true)
        XCTAssertEqual(store.assets.first?.createdAt, second.fileCreatedAt)
        XCTAssertFalse(store.assets.first?.isFavorite ?? true)
        XCTAssertEqual(self.store().assets.last?.createdAt, savedDate)
        XCTAssertTrue(self.store().assets.last?.isFavorite == true)
    }
}
