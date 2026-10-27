import Observation
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetVisibilityPolicyTests: XCTestCase {
    private var directories: [URL] = []
    private var defaultsNames: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        for name in defaultsNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        directories.removeAll()
        defaultsNames.removeAll()
        try await super.tearDown()
    }

    func testOrdinaryCollectionsAndDeviceCopiesKeepArchivesButHidePrivateAndUnknownAssets() throws {
        let fixture = try fixture()
        for id in ["archive", "locked", "hidden", "unknown"] {
            try fixture.store.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
        }
        try fixture.store.setAssetVisibility(["archive"], to: "archive")
        try fixture.store.setAssetVisibility(["locked"], to: "locked")
        try fixture.store.setAssetVisibility(["hidden"], to: "hidden")
        try fixture.store.setTimelineVisibility(["unknown"], inTimeline: false)
        let assets = ["ordinary", "archive", "locked", "hidden", "unknown",
                      "device:local-archive", "device:local-locked", "device:local-hidden",
                      "device:local-unknown", "device:local-only"].map(asset)

        XCTAssertEqual(fixture.policy().filter(assets).map(\.id),
                       ["ordinary", "archive", "device:local-archive", "device:local-only"])
        XCTAssertEqual(fixture.policy(scope: .timeline).filter(assets).map(\.id),
                       ["ordinary", "device:local-only"])
        XCTAssertEqual(fixture.policy(scope: .locked).filter(assets).map(\.id), assets.map(\.id),
                       "Only the explicitly authorized locked scope may admit private content")
        XCTAssertEqual(fixture.store.uploadedLocalIdentifiers().count, 4,
                       "Privacy filtering must retain the backup mapping")
    }

    func testRetainedPolicyUsesTheLatestVisibilityAndRestoresAnExplicitlyUnarchivedAsset() throws {
        let fixture = try fixture()
        let policy = fixture.policy()
        let oldRows = [asset("photo"), asset("other")]
        try fixture.store.setAssetVisibility(["photo"], to: "archive")
        XCTAssertEqual(policy.filter(oldRows).map(\.id), ["photo", "other"])
        let oldState = policy.state

        try fixture.store.setAssetVisibility(["photo"], to: "locked")

        XCTAssertNotEqual(policy.state, oldState)
        XCTAssertEqual(policy.filter(oldRows).map(\.id), ["other"])
        XCTAssertFalse(policy.allows(id: "photo"))
        try fixture.store.setAssetVisibility(["photo"], to: "timeline")
        XCTAssertEqual(policy.filter(oldRows).map(\.id), ["photo", "other"])
    }

    func testNewBackupMappingInvalidatesBothListAndPointVisibilityReads() throws {
        let fixture = try fixture()
        try fixture.store.setAssetVisibility(["private-server"], to: "locked")
        let policy = fixture.policy()
        let local = asset("device:new-mapping")
        XCTAssertEqual(policy.filter([local]).map(\.id), [local.id])
        XCTAssertTrue(policy.allows(id: local.id))
        let listChanged = expectation(description: "A retained list observes the new private mapping")
        let pointChanged = expectation(description: "A retained image observes the new private mapping")
        withObservationTracking { _ = policy.filter([local]) } onChange: { listChanged.fulfill() }
        withObservationTracking { _ = policy.allows(id: local.id) } onChange: { pointChanged.fulfill() }

        try fixture.store.linkDeviceAsset(localIdentifier: "new-mapping", to: "private-server")

        XCTAssertTrue(policy.filter([local]).isEmpty)
        XCTAssertFalse(policy.allows(id: local.id))
        wait(for: [listChanged, pointChanged], timeout: 1)
    }

    func testRetainedPolicyCopiesRefreshTheirMappingsAfterUnlinkAndRelink() throws {
        let fixture = try fixture()
        try fixture.store.setAssetVisibility(["first", "second"], to: "locked")
        try fixture.store.linkDeviceAsset(localIdentifier: "local", to: "first")
        let policy = fixture.policy()
        let copy = policy
        let local = asset("device:local")
        XCTAssertFalse(policy.allows(id: local.id))
        XCTAssertTrue(copy.filter([local]).isEmpty)

        try fixture.store.unlinkDeviceAsset(localIdentifier: "local")

        XCTAssertTrue(copy.allows(id: local.id), "An unlinked original must stop inheriting the old server's privacy")
        XCTAssertEqual(policy.filter([local]).map(\.id), [local.id])
        XCTAssertEqual(fixture.store.privateAssetIDs, ["first", "second"])
        try fixture.store.linkDeviceAsset(localIdentifier: "local", to: "second")
        XCTAssertFalse(policy.allows(id: local.id))
        XCTAssertTrue(copy.filter([local]).isEmpty)
        try fixture.store.setAssetVisibility(["second"], to: "archive")
        XCTAssertTrue(copy.allows(id: local.id), "Visibility checks must stay live when the mapping itself is cached")
    }

    func testColdLaunchDeletionFilteringHonorsTrashAndObservesRestore() throws {
        let fixture = try fixture()
        try fixture.store.linkDeviceAsset(localIdentifier: "local-soft", to: "soft")
        try fixture.store.linkDeviceAsset(localIdentifier: "local-permanent", to: "permanent")
        fixture.deleted.record(["soft"], permanently: false)
        fixture.deleted.record(["permanent"], permanently: true)
        let reopened = DeletedServerAssetRegistry(defaults: fixture.defaults)
        let removed = RemovedAssets()
        let policy = AssetVisibilityPolicy(dataManager: fixture.store, removed: removed, deleted: reopened)
        let trash = AssetVisibilityPolicy(removalScope: .trash, dataManager: fixture.store,
                                          removed: removed, deleted: reopened)
        let oldRows = ["soft", "permanent", "ordinary", "device:local-soft", "device:local-permanent"].map(asset)
        XCTAssertTrue(removed.ids.isEmpty)
        XCTAssertEqual(policy.filter(oldRows).map(\.id), ["ordinary"])
        XCTAssertEqual(trash.filter(oldRows).map(\.id), ["soft", "ordinary", "device:local-soft"])
        let changed = expectation(description: "A retained screen observes durable restoration")
        withObservationTracking { _ = policy.state } onChange: { changed.fulfill() }

        reopened.restore(["soft"])

        XCTAssertEqual(policy.filter(oldRows).map(\.id), ["soft", "ordinary", "device:local-soft"])
        XCTAssertFalse(policy.allows(id: "permanent"))
        // This is synchronous observation; waiting also fails if the registry
        // becomes non-observable while its filter still returns the right IDs.
        wait(for: [changed], timeout: 1)
    }

    func testMappedTemporaryRemovalsRespectTrashAndRebuildSectionOffsets() throws {
        let fixture = try fixture()
        try fixture.store.linkDeviceAsset(localIdentifier: "local-soft", to: "soft")
        fixture.removed.remove(["soft"], reason: .trashed)
        fixture.removed.remove(["missing"], reason: .unavailable)
        let sections = [
            TimelineSection(id: "one", title: "One", assets: [asset("soft"), asset("device:local-soft")], count: 2),
            TimelineSection(id: "two", title: "Two", assets: [asset("missing"), asset("keep")], count: 2, startIndex: 2),
            TimelineSection(id: "three", title: "Three", assets: [asset("last")], count: 1, startIndex: 4),
        ]

        let visible = fixture.policy().filterSections(sections)

        XCTAssertEqual(visible.map(\.id), ["two", "three"])
        XCTAssertEqual(visible.flatMap(\.assets).map(\.id), ["keep", "last"])
        XCTAssertEqual(visible.map(\.count), [1, 1])
        XCTAssertEqual(visible.map(\.startIndex), [0, 1])
        let trash = fixture.policy(removalScope: .trash).filterSections(sections)
        XCTAssertEqual(trash.flatMap(\.assets).map(\.id), ["soft", "device:local-soft", "keep", "last"])
    }

    func testCachedThumbnailCannotBypassPrivacyButAuthorizedLockedScopeStillWorks() throws {
        let fixture = try fixture()
        let loader = PhotoThumbnailLoader(session: MockSessionManager())
        loader.visibilityPolicy = fixture.policy()
        let key = ImageCache.memoryKey(loader.cacheKey(for: "photo"), PhotoThumbnailLoader.maxPixelSize)
        let cached = image()
        ImageMemoryCache.shared.insert(cached, for: key)
        defer { ImageMemoryCache.shared.remove(for: key) }
        XCTAssertTrue(loader.cachedImage(for: "photo") === cached)

        try fixture.store.setAssetVisibility(["photo"], to: "locked")

        XCTAssertNil(loader.cachedImage(for: "photo"))
        loader.visibilityPolicy = fixture.policy(scope: .locked)
        XCTAssertTrue(loader.cachedImage(for: "photo") === cached)
    }

    func testLateGridThumbnailCannotPaintAnAssetLockedDuringTheRequest() async throws {
        let fixture = try fixture()
        let loader = HeldPrivacyThumbnailLoader()
        loader.visibilityPolicy = fixture.policy()
        let cell = PhotoGridCell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        cell.configure(with: asset("photo"), loader: loader)
        await fulfillment(of: [loader.started], timeout: 2)

        try fixture.store.setAssetVisibility(["photo"], to: "locked")
        loader.resolve(image())
        await fulfillment(of: [loader.returned], timeout: 2)
        await mainQueueFence()

        let displayed = try XCTUnwrap(imageViews(in: cell).first)
        XCTAssertNil(displayed.image)
        try fixture.store.setAssetVisibility(["photo"], to: "timeline")
        let cached = image()
        loader.cached = cached
        cell.configure(with: asset("photo"), loader: loader)
        XCTAssertTrue(imageViews(in: cell).contains { $0.image === cached })
    }

    func testLatePagerPreviewCannotPaintAnAssetLockedDuringTheRequest() async throws {
        let fixture = try fixture()
        let loader = HeldPrivacyPreviewLoader()
        loader.visibilityPolicy = fixture.policy()
        let cell = PhotoPagerCell(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        cell.configure(with: asset("photo"), loader: loader)
        await fulfillment(of: [loader.started], timeout: 2)

        try fixture.store.setAssetVisibility(["photo"], to: "locked")
        loader.resolve(image())
        await fulfillment(of: [loader.returned], timeout: 2)
        await mainQueueFence()

        let displayed = try XCTUnwrap(imageViews(in: cell).first)
        XCTAssertNil(displayed.image)
        try fixture.store.setAssetVisibility(["photo"], to: "archive")
        let cached = image()
        loader.cached = cached
        cell.configure(with: asset("photo"), loader: loader)
        XCTAssertTrue(displayed.image === cached, "Known archives remain usable in ordinary album viewers")
    }

    func testDeferredScrollingSnapshotClearsAnOldPrivateCellImmediately() async throws {
        let fixture = try fixture()
        let loader = HeldPrivacyThumbnailLoader()
        loader.cached = image()
        let session = MockSessionManager()
        let controller = PhotoGridController(loader: loader, session: session)
        controller.visibilityPolicy = fixture.policy()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        let configuration = PhotoGridConfiguration(showsSectionHeaders: false)
        let oldSections = [TimelineSection(id: "all", title: "", assets: [asset("photo")], count: 1)]
        controller.apply(sections: oldSections, configuration: configuration, hero: nil)
        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        try await waitUntil {
            controller.view.layoutIfNeeded()
            return collection.cellForItem(at: IndexPath(item: 0, section: 0)) != nil
        }
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? PhotoGridCell)
        let displayed = try XCTUnwrap(imageViews(in: cell).first)
        XCTAssertTrue(displayed.image === loader.cached)
        controller.scrollViewWillBeginDragging(collection)

        try fixture.store.setAssetVisibility(["photo"], to: "locked")
        controller.apply(sections: oldSections, configuration: configuration, hero: nil)

        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1,
                       "The scrolling grid must still be holding the old snapshot")
        XCTAssertTrue(cell.contentView.isHidden)
        XCTAssertNil(displayed.image)
        try fixture.store.setAssetVisibility(["photo"], to: "timeline")
        controller.apply(sections: oldSections, configuration: configuration, hero: nil)
        XCTAssertFalse(cell.contentView.isHidden)
        XCTAssertTrue(displayed.image === loader.cached)
        try fixture.store.setAssetVisibility(["photo"], to: "locked")
        controller.apply(sections: oldSections, configuration: configuration, hero: nil)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
    }

    func testOpenViewerDropsItsPrivatePageWhileAuthorizedLockedViewerKeepsIt() throws {
        let fixture = try fixture()
        let photo = asset("photo"), other = asset("other")
        let viewer = AssetViewerState(currentAsset: photo, assets: [photo, other])
        let target = viewer.target(serverID: photo.id, detail: nil)
        try fixture.store.setAssetVisibility([photo.id], to: "locked")

        XCTAssertTrue(viewer.removeDisallowedPages(using: fixture.policy()))

        XCTAssertEqual(viewer.pages.map(\.id), ["other"])
        XCTAssertEqual(viewer.currentAsset.id, "other")
        XCTAssertFalse(viewer.isCurrent(target))
        let onlyPrivate = AssetViewerState(currentAsset: photo, assets: [photo])
        XCTAssertTrue(onlyPrivate.removeDisallowedPages(using: fixture.policy()))
        XCTAssertTrue(onlyPrivate.isEmpty, "The detail view uses this condition to dismiss")
        let authorized = AssetViewerState(currentAsset: photo, assets: [photo])
        XCTAssertFalse(authorized.removeDisallowedPages(using: fixture.policy(scope: .locked)))
        XCTAssertEqual(authorized.pages.map(\.id), [photo.id])
        let loader = HeldPrivacyPreviewLoader()
        loader.cached = image()
        loader.visibilityPolicy = fixture.policy(scope: .locked)
        let cell = PhotoPagerCell(frame: .zero)
        cell.configure(with: photo, loader: loader)
        XCTAssertTrue(imageViews(in: cell).contains { $0.image === loader.cached },
                      "The authorized scope must render the private photo, not just retain an ID")
        cell.prepareForReuse()
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-policy-\(UUID())")
        directories.append(directory)
        let name = "visibility-policy-\(UUID())"
        defaultsNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("store"),
                                     backupJournalURL: directory.appendingPathComponent("journal.json"))
        return Fixture(store: store, removed: RemovedAssets(), defaults: defaults,
                       deleted: DeletedServerAssetRegistry(defaults: defaults))
    }

    private func asset(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil,
                  createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  origin: LocalPhotoLibrary.isLocal(id) ? .both : .server)
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func imageViews(in view: UIView) -> [UIImageView] {
        (view as? UIImageView).map { [$0] } ?? view.subviews.flatMap(imageViews(in:))
    }

    private func mainQueueFence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(2)
        while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The grid did not display its opening cell")
    }

    @MainActor
    private struct Fixture {
        let store: SwiftDataManager
        let removed: RemovedAssets
        let defaults: UserDefaults
        let deleted: DeletedServerAssetRegistry

        func policy(scope: AssetVisibilityPolicy.Scope = .collection,
                    removalScope: RemovedAssets.Scope = .library) -> AssetVisibilityPolicy {
            AssetVisibilityPolicy(scope: scope, removalScope: removalScope,
                                  dataManager: store, removed: removed, deleted: deleted)
        }
    }
}

@MainActor
private final class HeldPrivacyThumbnailLoader: PhotoThumbnailLoader {
    var cached: UIImage?
    let started = XCTestExpectation(description: "Grid image request started")
    let returned = XCTestExpectation(description: "Grid image request returned")
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { cached }
    override func image(for assetId: String) async -> UIImage? {
        let image = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        returned.fulfill()
        return image
    }
    func resolve(_ image: UIImage?) {
        continuation?.resume(returning: image)
        continuation = nil
    }
}

@MainActor
private final class HeldPrivacyPreviewLoader: PhotoPreviewLoader {
    var cached: UIImage?
    let started = XCTestExpectation(description: "Pager image request started")
    let returned = XCTestExpectation(description: "Pager image request returned")
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { cached }
    override func hasPreview(for assetId: String) -> Bool { cached != nil }
    override func localLivePhotoAssetID(for assetId: String) -> String? { nil }
    override func image(for assetId: String) async -> UIImage? {
        let image = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        returned.fulfill()
        return image
    }
    func resolve(_ image: UIImage?) {
        continuation?.resume(returning: image)
        continuation = nil
    }
}
