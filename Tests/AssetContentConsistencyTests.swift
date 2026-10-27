import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetContentConsistencyTests: XCTestCase {
    private var cachedKeys: Set<String> = []
    private var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for key in cachedKeys { ImageMemoryCache.shared.remove(for: key) }
        cachedKeys.removeAll()
        try await super.tearDown()
    }

    func testTimelinePublishesInteriorReplacementWithUnchangedEndpointsAndCount() async throws {
        let store = try makeStore()
        let ids = (0..<4).map { _ in UUID().uuidString }
        try store.insertOrUpdateCachedAsset(cached(ids[0], day: 1))
        try store.insertOrUpdateCachedAsset(cached(ids[1], day: 2))
        try store.insertOrUpdateCachedAsset(cached(ids[2], day: 3))
        let model = TimelineViewModel(dataManager: store)
        await model.loadTimeline()
        XCTAssertEqual(model.allAssets.map(\.id), Array(ids.prefix(3)))

        try store.deleteCachedAsset(id: ids[1])
        try store.insertOrUpdateCachedAsset(cached(ids[3], day: 2))
        await model.loadTimeline()

        XCTAssertEqual(model.allAssets.map(\.id), [ids[0], ids[3], ids[2]])
        XCTAssertEqual(model.sections.flatMap(\.assets).map(\.id), [ids[0], ids[3], ids[2]])
        XCTAssertNil(model.asset(for: ids[1]))
        XCTAssertEqual(model.asset(for: ids[3])?.createdAt, date(day: 2))
    }

    func testTimelinePublishesEveryChangedMediaFieldForTheSameIDs() async throws {
        let store = try makeStore()
        let id = UUID().uuidString
        let model = TimelineViewModel(dataManager: store)
        for variant in mediaVariants(id) where variant.origin == .server {
            try store.insertOrUpdateCachedAsset(cached(asset(id)))
            await model.loadTimeline()
            let update = expectation(description: "Flat asset observers receive updated metadata")
            withObservationTracking { _ = model.allAssets } onChange: { update.fulfill() }
            try store.insertOrUpdateCachedAsset(cached(variant))
            await model.loadTimeline()
            await fulfillment(of: [update], timeout: 2)

            let published = try XCTUnwrap(model.allAssets.first)
            assertFields(published, equalTo: variant)
            assertFields(try XCTUnwrap(model.sections.first?.assets.first), equalTo: variant)
        }
    }

    func testReturningToTimelineReadsAssetMutationsMissedWhileInactive() async throws {
        let store = try makeStore()
        let id = UUID().uuidString
        try store.insertOrUpdateCachedAsset(cached(id, day: 1))
        let model = TimelineViewModel(dataManager: store)
        await model.loadTimelineIfNeeded()
        XCTAssertFalse(model.allAssets[0].isFavorite)
        try store.patchCachedAsset(id, isFavorite: true)

        await model.loadTimelineIfNeeded()

        XCTAssertEqual(model.allAssets.map(\.id), [id])
        XCTAssertTrue(model.allAssets[0].isFavorite)
        XCTAssertTrue(model.sections[0].assets[0].isFavorite)
    }

    func testCanceledTimelineBuildCannotPublishAndTheNextLoadStillWorks() async throws {
        let store = try makeStore()
        let model = TimelineViewModel(dataManager: store)
        let id = UUID().uuidString
        try store.insertOrUpdateCachedAsset(cached(id, day: 1))
        var load: Task<Void, Never>?
        withObservationTracking { _ = model.phase } onChange: {
            MainActor.assumeIsolated { load?.cancel() }
        }
        load = Task { await model.loadTimeline() }
        await load?.value

        XCTAssertTrue(model.allAssets.isEmpty, "Canceled grouping must not publish a snapshot")
        XCTAssertTrue(model.sections.isEmpty)
        await model.loadTimeline()
        XCTAssertEqual(model.allAssets.map(\.id), [id])
        XCTAssertEqual(model.sections.first?.assets.first?.id, id)
    }

    func testGridReconfiguresEverySameIDContentChange() async throws {
        let id = UUID().uuidString
        for variant in mediaVariants(id) {
            let originalImage = image(.red)
            cache(originalImage, id: id, preview: false)
            let grid = makeGrid([asset(id)])
            try await waitUntil { grid.zoomSource(for: id)?.image === originalImage }
            let currentImage = image(.blue)
            cache(currentImage, id: id, preview: false)

            grid.apply(sections: [section([variant])], configuration: gridConfiguration(), hero: nil)
            try await waitUntil { grid.zoomSource(for: id)?.image === currentImage }
            assertFields(try XCTUnwrap(grid.visibleAssetForTimelineNavigation()), equalTo: variant)
        }
    }

    func testGridAcceptsInteriorReplacementAndUpdatesHeaderTitle() async throws {
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { cache(image(.gray), id: id, preview: false) }
        let initial = Array(ids.prefix(3)).map { asset($0) }
        let grid = makeGrid(initial)
        let collection = try collectionView(in: grid)
        try await waitUntil { grid.revealCell(for: ids[1]) != nil }
        grid.apply(sections: [section(initial, title: "Title only")], configuration: gridConfiguration(), hero: nil)
        try await waitUntil {
            collection.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                .flatMap { $0.subviews.compactMap { $0 as? UILabel } }.first?.text == "Title only"
        }
        grid.apply(sections: [section([asset(ids[0]), asset(ids[3]), asset(ids[2])], title: "Updated month")],
            configuration: gridConfiguration(), hero: nil)
        try await waitUntil {
            grid.revealCell(for: ids[3]) != nil
                && collection.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                    .flatMap { $0.subviews.compactMap { $0 as? UILabel } }.first?.text == "Updated month"
        }

        XCTAssertNil(grid.revealCell(for: ids[1]))
        let labels = collection.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .flatMap { $0.subviews.compactMap { $0 as? UILabel } }
        XCTAssertEqual(labels.map(\.text), ["Updated month"])
    }

    func testLatestGridInputReplacesAnOlderPendingSnapshotEvenWhenItMatchesVisibleContent() async throws {
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { cache(image(.gray), id: id, preview: false) }
        let initial = Array(ids.prefix(3)).map { asset($0) }
        let grid = makeGrid(initial)
        let collection = try collectionView(in: grid)
        try await waitUntil { grid.revealCell(for: ids[1]) != nil }
        grid.scrollViewWillBeginDragging(collection)
        grid.apply(sections: [section([asset(ids[0]), asset(ids[3]), asset(ids[2])])],
            configuration: gridConfiguration(), hero: nil)
        XCTAssertNil(grid.revealCell(for: ids[3]), "Updates should wait while the user scrolls")
        grid.apply(sections: [section(initial)], configuration: gridConfiguration(), hero: nil)
        grid.scrollViewDidEndDragging(collection, willDecelerate: false)
        await nextMainQueueTurn()

        XCTAssertNotNil(grid.revealCell(for: ids[1]))
        XCTAssertNil(grid.revealCell(for: ids[3]), "The obsolete pending replacement must not reappear")
    }

    func testPagerAndFilmstripAcceptInteriorReplacement() async throws {
        let ids = (0..<4).map { _ in UUID().uuidString }
        let pictures = ids.map { _ in image(.gray) }
        for (id, picture) in zip(ids, pictures) {
            cache(picture, id: id, preview: true)
            cache(picture, id: id, preview: false)
        }
        let initial = Array(ids.prefix(3)).map { asset($0) }
        let updated = [asset(ids[0]), asset(ids[3]), asset(ids[2])]
        let pager = makePager(initial, currentID: ids[1])
        pager.apply(assets: updated, currentAssetID: ids[3])
        pager.view.layoutIfNeeded()
        let pagerCollection = try collectionView(in: pager)
        let pagerCell = try XCTUnwrap(pagerCollection.cellForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertTrue(displayedImage(in: pagerCell) === pictures[3])

        let strip = makeFilmstrip(initial, currentID: ids[1])
        strip.apply(assets: updated, currentAssetID: ids[3])
        strip.view.layoutIfNeeded()
        var selected: AssetLite?
        strip.onSelect = { selected = $0 }
        let stripCollection = try collectionView(in: strip)
        strip.collectionView(stripCollection, didSelectItemAt: IndexPath(item: 1, section: 0))
        XCTAssertEqual(selected?.id, ids[3])
    }

    func testPagerAndFilmstripRefreshMetadataWithoutChangingIdentity() async throws {
        let id = UUID().uuidString
        for variant in mediaVariants(id) {
            let original = image(.red)
            cache(original, id: id, preview: true)
            cache(original, id: id, preview: false)
            let pager = makePager([asset(id)], currentID: id)
            let strip = makeFilmstrip([asset(id)], currentID: id)
            let current = image(.blue)
            cache(current, id: id, preview: true)
            cache(current, id: id, preview: false)
            pager.apply(assets: [variant], currentAssetID: id)
            strip.apply(assets: [variant], currentAssetID: id)
            pager.view.layoutIfNeeded()
            strip.view.layoutIfNeeded()
            let pagerCell = try XCTUnwrap(try collectionView(in: pager).cellForItem(at: IndexPath(item: 0, section: 0)))
            let stripCollection = try collectionView(in: strip)
            let stripCell = try XCTUnwrap(stripCollection.cellForItem(at: IndexPath(item: 0, section: 0)))
            XCTAssertTrue(displayedImage(in: pagerCell) === current)
            XCTAssertTrue(displayedImage(in: stripCell) === current)
            var selected: AssetLite?
            strip.onSelect = { selected = $0 }
            strip.collectionView(stripCollection, didSelectItemAt: IndexPath(item: 0, section: 0))
            assertFields(try XCTUnwrap(selected), equalTo: variant)
        }
    }

    func testCollectionGroupingRefreshesInteriorIDsAndSameIDMetadata() async throws {
        let ids = (0..<4).map { _ in UUID().uuidString }
        for id in ids { cache(image(.gray), id: id, preview: false) }
        let fixture = CollectionInput(assets: Array(ids.prefix(3)).map { asset($0) })
        let host = UIHostingController(rootView: CollectionContentFixture(input: fixture)
            .environment(MockSessionManager() as SessionManager))
        _ = try await makeWindow(root: host)
        try await waitUntil { self.gridController(in: host)?.revealCell(for: ids[1]) != nil }
        let replacement = [asset(ids[0]), asset(ids[3]), asset(ids[2])]
        fixture.value = .init(assets: replacement)
        try await waitUntil { self.gridController(in: host)?.revealCell(for: ids[3]) != nil }
        let grid = try XCTUnwrap(gridController(in: host))
        XCTAssertNil(grid.revealCell(for: ids[1]))

        let before = image(.red)
        cache(before, id: ids[3], preview: false)
        var baseline = replacement
        baseline[1].duration = 20
        fixture.value = .init(assets: baseline)
        try await waitUntil { grid.zoomSource(for: ids[3])?.image === before }
        let after = image(.blue)
        cache(after, id: ids[3], preview: false)
        baseline[1].duration = 40
        fixture.value = .init(assets: baseline)
        try await waitUntil { grid.zoomSource(for: ids[3])?.image === after }
        let cellPath = try XCTUnwrap(grid.revealCell(for: ids[3]))
        let cell = try XCTUnwrap(try collectionView(in: grid).cellForItem(at: cellPath))
        XCTAssertEqual(cell.contentView.subviews.compactMap { $0 as? UILabel }.first?.text, "0:40")
    }

    func testContentChangesDoNotChangeAssetIdentity() {
        let original = asset("stable")
        var changed = original
        changed.isFavorite = true
        XCTAssertEqual(original, changed)
        XCTAssertEqual(Set([original, changed]).count, 1)
        XCTAssertFalse(original.hasSameContent(as: changed))
        XCTAssertTrue(original.hasSameContent(as: original))
    }

    private func makeStore() throws -> SwiftDataManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("content-consistency-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SwiftDataManager(storeURL: directory.appendingPathComponent("store.sqlite"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    private func cached(_ id: String, day: Int) -> CachedAsset { cached(asset(id, createdAt: date(day: day))) }
    private func cached(_ asset: AssetLite) -> CachedAsset {
        CachedAsset(id: asset.id, assetId: asset.id, type: asset.isVideo ? "VIDEO" : "IMAGE",
            isFavorite: asset.isFavorite, duration: asset.duration, livePhotoVideoId: asset.livePhotoVideoID,
            createdAt: asset.createdAt, ratio: asset.ratio, thumbhash: asset.thumbhash)
    }

    private func asset(_ id: String, isVideo: Bool = false, ratio: Double = 1, thumbhash: String? = nil,
        createdAt: Date? = nil, isFavorite: Bool = false, duration: Double? = nil,
        livePhotoVideoID: String? = nil, origin: AssetOrigin = .server) -> AssetLite {
        AssetLite(id: id, isVideo: isVideo, ratio: ratio, thumbhash: thumbhash,
            createdAt: createdAt ?? date(day: 1), isFavorite: isFavorite, duration: duration,
            livePhotoVideoID: livePhotoVideoID, origin: origin)
    }

    private func mediaVariants(_ id: String) -> [AssetLite] {
        [asset(id, isVideo: true), asset(id, ratio: 2), asset(id, thumbhash: "changed"),
         asset(id, createdAt: date(day: 2)), asset(id, isFavorite: true), asset(id, duration: 75),
         asset(id, livePhotoVideoID: "live-video"), asset(id, origin: .both)]
    }

    private func assertFields(_ actual: AssetLite, equalTo expected: AssetLite,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.isVideo, expected.isVideo, file: file, line: line)
        XCTAssertEqual(actual.ratio, expected.ratio, file: file, line: line)
        XCTAssertEqual(actual.thumbhash, expected.thumbhash, file: file, line: line)
        XCTAssertEqual(actual.createdAt, expected.createdAt, file: file, line: line)
        XCTAssertEqual(actual.isFavorite, expected.isFavorite, file: file, line: line)
        XCTAssertEqual(actual.duration, expected.duration, file: file, line: line)
        XCTAssertEqual(actual.livePhotoVideoID, expected.livePhotoVideoID, file: file, line: line)
        XCTAssertEqual(actual.origin, expected.origin, file: file, line: line)
    }

    private func section(_ assets: [AssetLite], title: String = "Original month") -> TimelineSection {
        TimelineSection(id: "2026-09", title: title, assets: assets, count: assets.count, startIndex: 0)
    }
    private func gridConfiguration() -> PhotoGridConfiguration { PhotoGridConfiguration(columns: 3) }
    private func makeGrid(_ assets: [AssetLite]) -> PhotoGridController {
        let session = MockSessionManager()
        let controller = PhotoGridController(loader: PhotoThumbnailLoader(session: session), session: session)
        size(controller)
        controller.apply(sections: [section(assets)], configuration: gridConfiguration(), hero: nil)
        controller.view.layoutIfNeeded()
        return controller
    }
    private func makePager(_ assets: [AssetLite], currentID: String) -> PhotoPagerController {
        let controller = PhotoPagerController(loader: PhotoPreviewLoader(session: MockSessionManager()))
        size(controller)
        controller.apply(assets: assets, currentAssetID: currentID)
        controller.view.layoutIfNeeded()
        return controller
    }
    private func makeFilmstrip(_ assets: [AssetLite], currentID: String) -> PhotoFilmstripController {
        let controller = PhotoFilmstripController(loader: PhotoThumbnailLoader(session: MockSessionManager()))
        size(controller, height: 76)
        controller.apply(assets: assets, currentAssetID: currentID)
        controller.view.layoutIfNeeded()
        return controller
    }
    private func size(_ controller: UIViewController, height: CGFloat = 600) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        controller.view.layoutIfNeeded()
    }
    private func collectionView(in controller: UIViewController) throws -> UICollectionView {
        try XCTUnwrap(controller.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
    }
    private func displayedImage(in cell: UICollectionViewCell) -> UIImage? {
        let container = cell.contentView.subviews.first { $0 is UIScrollView } ?? cell.contentView
        return container.subviews.compactMap { $0 as? UIImageView }.first?.image
    }
    private func cache(_ image: UIImage, id: String, preview: Bool) {
        let key = ImageCache.memoryKey("\(id)-\(preview ? "preview" : "thumbnail")",
            preview ? PhotoPreviewLoader.maxPixelSize : PhotoThumbnailLoader.maxPixelSize)
        ImageMemoryCache.shared.insert(image, for: key)
        cachedKeys.insert(key)
    }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
    private func date(day: Int) -> Date {
        ISO8601DateFormatter().date(from: String(format: "2026-09-%02dT12:00:00Z", day))!
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(predicate() ? true : nil, "Content did not update before timeout", file: file, line: line)
    }
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func makeWindow(root: UIViewController) async throws -> UIWindow {
        try await waitUntil { !UIApplication.shared.connectedScenes.isEmpty }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }
    private func gridController(in controller: UIViewController) -> PhotoGridController? {
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.gridController(in: $0) }.first
    }
}

@MainActor @Observable
private final class CollectionInput {
    struct Value { let assets: [AssetLite] }
    var value: Value
    init(assets: [AssetLite]) { value = Value(assets: assets) }
}

private struct CollectionContentFixture: View {
    let input: CollectionInput
    var body: some View {
        NavigationStack {
            PhotoCollectionScreen(title: "Collection", layout: .monthly, assets: input.value.assets,
                phase: .loaded(()), onRetry: {}, onToggleFavorite: { _ in }, onDelete: { _ in }, shareURLs: { _ in [] })
        }
    }
}
