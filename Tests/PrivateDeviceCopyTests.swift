import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class PrivateDeviceCopyTests: XCTestCase {
    func testSyncedPrivateCopiesStayOutOfPhotosWithoutLosingBackupMappings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "locked-device", to: "locked-server")
        try store.linkDeviceAsset(localIdentifier: "archive-device", to: "archive-server")
        try store.linkDeviceAsset(localIdentifier: "uploaded-device", to: "new-upload")
        try store.applySyncBatch(upserts: [
            cached("locked-server", private: true),
            cached("archive-server", private: true),
        ], deletedIds: [])
        let model = timeline(store, photos: [
            photo("locked-device"), photo("archive-device"),
            photo("uploaded-device"), photo("local-only"),
        ])

        await model.loadTimeline()

        XCTAssertEqual(Set(model.allAssets.map(\.id)), ["device:uploaded-device", "device:local-only"])
        XCTAssertEqual(model.allAssets.first { $0.id == "device:uploaded-device" }?.origin, .both)
        XCTAssertEqual(model.allAssets.first { $0.id == "device:local-only" }?.origin, .device)
        XCTAssertEqual(store.uploadedLocalIdentifiers(), ["locked-device", "archive-device", "uploaded-device"])
        XCTAssertEqual(store.cachedAssetCount(), 2)
    }

    func testPrivateVisibilitySurvivesCacheResetAndRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = fixture.store()
            try store.linkDeviceAsset(localIdentifier: "private-device", to: "private-server")
            try store.applySyncBatch(upserts: [cached("private-server", private: true)], deletedIds: [])
            try store.clearAllCache()
            XCTAssertEqual(store.cachedAssetCount(), 0)
        }
        let restored = fixture.store()
        let model = timeline(restored, photos: [photo("private-device"), photo("local-only")])

        await model.loadTimeline()

        XCTAssertEqual(restored.nonTimelineAssetIDs, ["private-server"])
        XCTAssertEqual(model.allAssets.map(\.id), ["device:local-only"])
        XCTAssertEqual(restored.serverAssetIDsByLocalIdentifier()["private-device"], "private-server")
    }

    func testUncachedMoveToLockedFolderPersistsAndMoveBackReleasesOnlyThatAsset() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "private-device", to: "private-server")
        try store.setTimelineVisibility(["other-private-server"], inTimeline: false)
        let api = VisibilityMutationAPIClient(session: MockSessionManager())
        let repo = AssetDetailRepository(api: api, dataManager: store)
        let detail = AssetDetailViewModel(repo: repo)

        let locked = await detail.move("private-server", to: .locked)
        XCTAssertTrue(locked)
        XCTAssertEqual(api.visibilities, ["locked"])
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["private-server", "other-private-server"])
        let hidden = timeline(store, photos: [photo("private-device")])
        await hidden.loadTimeline()
        XCTAssertTrue(hidden.allAssets.isEmpty)

        let restored = await detail.move("private-server", to: .timeline)
        XCTAssertTrue(restored)
        XCTAssertEqual(api.visibilities, ["locked", "timeline"])
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["other-private-server"])
        let visible = timeline(store, photos: [photo("private-device")])
        await visible.loadTimeline()
        XCTAssertEqual(visible.allAssets.map(\.id), ["device:private-device"])
        XCTAssertEqual(visible.allAssets.first?.origin, .both)
    }

    func testFailedVisibilityMutationLeavesPhotoVisibleAndDoesNotWritePrivateState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "device", to: "server")
        let api = VisibilityMutationAPIClient(session: MockSessionManager())
        api.shouldFail = true
        let repo = AssetDetailRepository(api: api, dataManager: store)
        let detail = AssetDetailViewModel(repo: repo)

        let moved = await detail.move("server", to: .locked)

        XCTAssertFalse(moved)
        XCTAssertNotNil(detail.actionError)
        XCTAssertTrue(fixture.store().nonTimelineAssetIDs.isEmpty)
        let model = timeline(store, photos: [photo("device")])
        await model.loadTimeline()
        XCTAssertEqual(model.allAssets.map(\.id), ["device:device"])
    }

    func testDetailArchiveToggleUpdatesPrivateFallbackAndRestoresTimeline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.insertOrUpdateCachedAsset(cached("server", private: false))
        try store.linkDeviceAsset(localIdentifier: "device", to: "server")
        let api = VisibilityMutationAPIClient(session: MockSessionManager())
        let repo = AssetDetailRepository(api: api, dataManager: store)
        let detail = AssetDetailViewModel(repo: repo)
        detail.detail = makeTestAsset(id: "server", isArchived: false)

        await detail.toggleArchive("server")
        let archived = timeline(store, photos: [photo("device")])
        await archived.loadTimeline()
        XCTAssertTrue(archived.allAssets.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "server")).isArchived)
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["server"])

        await detail.toggleArchive("server")
        let restored = timeline(store, photos: [photo("device")])
        await restored.loadTimeline()
        XCTAssertEqual(restored.allAssets.map(\.id), ["server"])
        XCTAssertFalse(try XCTUnwrap(store.getCachedAsset(id: "server")).isArchived)
        XCTAssertTrue(fixture.store().nonTimelineAssetIDs.isEmpty)
    }

    func testSyncCanRestoreVisibilityWithoutRemovingAnotherPrivateAsset() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "device", to: "server")
        try store.setTimelineVisibility(["server", "other-private"], inTimeline: false)
        try store.applySyncBatch(upserts: [cached("server", private: false)], deletedIds: [])
        XCTAssertEqual(store.nonTimelineAssetIDs, ["other-private"])
        try store.clearAllCache()
        let restored = fixture.store()
        let model = timeline(restored, photos: [photo("device")])

        await model.loadTimeline()

        XCTAssertEqual(model.allAssets.map(\.id), ["device:device"])
        XCTAssertEqual(restored.nonTimelineAssetIDs, ["other-private"])
    }

    func testTrashRestoreDoesNotExposeKnownPrivateAsset() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "private-device", to: "private-server")
        try store.setTimelineVisibility(["private-server"], inTimeline: false)
        try store.restoreToTimeline([
            AssetLite(makeTestAsset(id: "private-server")),
            AssetLite(makeTestAsset(id: "ordinary-server")),
        ])
        let model = timeline(store, photos: [photo("private-device")])

        await model.loadTimeline()

        XCTAssertEqual(model.allAssets.map(\.id), ["ordinary-server"])
        XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "private-server")).isArchived)
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["private-server"])
    }

    func testKeptAliveTimelineReplacesInteriorPrivatePhotoEvenWhenCountsAndEndpointsMatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.applySyncBatch(upserts: [
            CachedAsset(id: "first", assetId: "first", type: "IMAGE", createdAt: date),
            CachedAsset(id: "old-interior", assetId: "old-interior", type: "IMAGE", createdAt: date.addingTimeInterval(1)),
            CachedAsset(id: "new-interior", assetId: "new-interior", type: "IMAGE", isArchived: true, createdAt: date.addingTimeInterval(2)),
            CachedAsset(id: "last", assetId: "last", type: "IMAGE", createdAt: date.addingTimeInterval(3)),
        ], deletedIds: [])
        let model = timeline(store, photos: [])
        await model.loadTimeline()
        XCTAssertEqual(model.allAssets.map(\.id), ["first", "old-interior", "last"])

        try store.setTimelineVisibility(["old-interior"], inTimeline: false)
        try store.setTimelineVisibility(["new-interior"], inTimeline: true)
        await model.loadTimelineIfNeeded()

        XCTAssertEqual(model.allAssets.map(\.id), ["first", "new-interior", "last"])
        XCTAssertFalse(model.sections.flatMap(\.assets).contains { $0.id == "old-interior" })
    }

    func testProtectedVisibilityOverridesStaleCacheUntilAuthoritativeTimelineSync() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = fixture.store()
            try store.setTimelineVisibility(["private-server"], inTimeline: false)
            // Model a restored or stale cache row. This bypasses the authoritative
            // sync path, which is the operation allowed to release suppression.
            store.modelContext.insert(cached("private-server", private: false))
            try store.modelContext.save()
        }
        let restored = fixture.store()
        XCTAssertEqual(restored.timelineAssets().map(\.asset.id), ["private-server"])
        XCTAssertEqual(restored.nonTimelineAssetIDs, ["private-server"])
        let model = timeline(restored, photos: [])
        await model.loadTimeline()
        XCTAssertTrue(model.allAssets.isEmpty)

        try restored.applySyncBatch(upserts: [cached("private-server", private: false)], deletedIds: [])
        await model.loadTimelineIfNeeded()

        XCTAssertEqual(model.allAssets.map(\.id), ["private-server"])
        XCTAssertTrue(fixture.store().nonTimelineAssetIDs.isEmpty)
    }

    func testLogoutClearsProtectedVisibilityAndMappings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "device", to: "server")
        try store.setTimelineVisibility(["server"], inTimeline: false)

        try store.clearAllAccountData()

        XCTAssertTrue(store.nonTimelineAssetIDs.isEmpty)
        let restored = fixture.store()
        XCTAssertTrue(restored.nonTimelineAssetIDs.isEmpty)
        XCTAssertTrue(restored.uploadedLocalIdentifiers().isEmpty)
    }

    func testOldJournalSeedsPrivacyFromExistingCacheBeforeFullSync() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = fixture.store()
            try store.insertOrUpdateCachedAsset(cached("legacy-private", private: true))
        }
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journalURL)) as? [String: Any])
        journal.removeValue(forKey: "nonTimelineAssetIDs")
        try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journalURL, options: .atomic)
        do {
            let upgraded = fixture.store()
            XCTAssertEqual(upgraded.nonTimelineAssetIDs, ["legacy-private"])
            try upgraded.clearAllCache()
        }
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["legacy-private"])
    }

    func testHidingStillPersistsToCacheWhenProtectedJournalWriteFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.insertOrUpdateCachedAsset(cached("private-server", private: false))
        try store.linkDeviceAsset(localIdentifier: "private-device", to: "private-server")
        try FileManager.default.removeItem(at: fixture.journalURL)
        try FileManager.default.createDirectory(at: fixture.journalURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.setTimelineVisibility(["private-server"], inTimeline: false))

        XCTAssertEqual(store.nonTimelineAssetIDs, ["private-server"])
        XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "private-server")).isArchived)
        let current = timeline(store, photos: [photo("private-device"), photo("local-only")])
        await current.loadTimeline()
        XCTAssertEqual(current.allAssets.map(\.id), ["device:local-only"])
        let restored = fixture.store()
        XCTAssertTrue(try XCTUnwrap(restored.getCachedAsset(id: "private-server")).isArchived)
        let relaunched = timeline(restored, photos: [photo("private-device"), photo("local-only")])
        await relaunched.loadTimeline()
        XCTAssertEqual(relaunched.allAssets.map(\.id), ["device:local-only"])
        XCTAssertEqual(restored.serverAssetIDsByLocalIdentifier()["private-device"], "private-server")
    }

    func testPrivateSyncRowsStillPersistWhenProtectedJournalWriteFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.linkDeviceAsset(localIdentifier: "private-device", to: "private-server")
        try FileManager.default.removeItem(at: fixture.journalURL)
        try FileManager.default.createDirectory(at: fixture.journalURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.applySyncBatch(
            upserts: [cached("private-server", private: true)], deletedIds: []))

        XCTAssertEqual(store.nonTimelineAssetIDs, ["private-server"])
        XCTAssertTrue(try XCTUnwrap(store.getCachedAsset(id: "private-server")).isArchived)
        let current = timeline(store, photos: [photo("private-device"), photo("local-only")])
        await current.loadTimeline()
        XCTAssertEqual(current.allAssets.map(\.id), ["device:local-only"])
        let restored = fixture.store()
        XCTAssertTrue(try XCTUnwrap(restored.getCachedAsset(id: "private-server")).isArchived)
        let relaunched = timeline(restored, photos: [photo("private-device"), photo("local-only")])
        await relaunched.loadTimeline()
        XCTAssertEqual(relaunched.allAssets.map(\.id), ["device:local-only"])
    }

    func testUnreadableJournalSuppressesUnknownMappedCopiesUntilFreshSync() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = fixture.store()
            try store.linkDeviceAsset(localIdentifier: "mapped-device", to: "mapped-server")
            try store.clearAllCache()
        }
        try Data("corrupt journal".utf8).write(to: fixture.journalURL, options: .atomic)
        let restored = fixture.store()
        XCTAssertEqual(restored.cachedAssetCount(), 0)
        XCTAssertEqual(restored.nonTimelineAssetIDs, ["mapped-server"])
        let model = timeline(restored, photos: [photo("mapped-device"), photo("local-only")])
        await model.loadTimeline()
        XCTAssertEqual(model.allAssets.map(\.id), ["device:local-only"])

        try restored.applySyncBatch(upserts: [cached("mapped-server", private: false)], deletedIds: [])
        await model.loadTimelineIfNeeded()

        XCTAssertEqual(Set(model.allAssets.map(\.id)), ["mapped-server", "device:local-only"])
        XCTAssertTrue(restored.nonTimelineAssetIDs.isEmpty)
        let repaired = fixture.store()
        XCTAssertEqual(repaired.startupState, .ready)
        XCTAssertTrue(repaired.nonTimelineAssetIDs.isEmpty)
        XCTAssertEqual(repaired.serverAssetIDsByLocalIdentifier()["mapped-device"], "mapped-server")
    }

    func testStaleSyncBatchCannotOverrideAnExplicitVisibilityMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let oldRevision = store.visibilityMutationRevision
        try store.setTimelineVisibility([], inTimeline: false)
        XCTAssertEqual(store.visibilityMutationRevision, oldRevision)
        try store.setTimelineVisibility(["private-server"], inTimeline: false)
        XCTAssertNotEqual(store.visibilityMutationRevision, oldRevision)

        XCTAssertThrowsError(try store.applySyncBatch(
            upserts: [cached("private-server", private: false)], deletedIds: [],
            expectedVisibilityRevision: oldRevision)) { error in
                XCTAssertTrue(error is CancellationError)
            }
        XCTAssertNil(store.getCachedAsset(id: "private-server"))
        XCTAssertEqual(store.nonTimelineAssetIDs, ["private-server"])
        XCTAssertEqual(fixture.store().nonTimelineAssetIDs, ["private-server"])

        let currentRevision = store.visibilityMutationRevision
        try store.applySyncBatch(upserts: [cached("private-server", private: false)], deletedIds: [],
            expectedVisibilityRevision: currentRevision)
        XCTAssertNotNil(store.getCachedAsset(id: "private-server"))
        XCTAssertTrue(store.nonTimelineAssetIDs.isEmpty)
        try store.clearAllAccountData()
        XCTAssertNotEqual(store.visibilityMutationRevision, currentRevision)
    }

    private func timeline(_ store: SwiftDataManager, photos: [LocalPhoto]) -> TimelineViewModel {
        TimelineViewModel(dataManager: store, localPhotos: { photos })
    }

    private func cached(_ id: String, private isPrivate: Bool) -> CachedAsset {
        CachedAsset(id: id, assetId: id, type: "IMAGE", isArchived: isPrivate,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func photo(_ id: String) -> LocalPhoto {
        LocalPhoto(id: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isVideo: false,
            isLivePhoto: false, duration: nil, ratio: 1)
    }

    private struct Fixture {
        let directory: URL
        var storeURL: URL { directory.appendingPathComponent("test.store") }
        var journalURL: URL { directory.appendingPathComponent("journal.json") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("private-copies-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @MainActor
        func store() -> SwiftDataManager {
            SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class VisibilityMutationAPIClient: APIClient {
    var shouldFail = false
    var visibilities: [String] = []

    override func sendVoid(_ endpoint: Endpoint) async throws {
        XCTAssertEqual(endpoint.method, .put)
        XCTAssertTrue(endpoint.path.hasPrefix("/assets/"))
        let body = try XCTUnwrap(endpoint.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        visibilities.append(try XCTUnwrap(object["visibility"]))
        if shouldFail { throw APIError.unknown }
    }
}
