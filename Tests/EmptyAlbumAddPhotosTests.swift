import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class EmptyAlbumAddPhotosTests: XCTestCase {
    private var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
    }

    func testEmptyHeroAndMonthlyGridsHaveOneUsableAddControlWithoutAMonthHeader() async throws {
        for (hero, justified) in [(false, false), (false, true), (true, false)] {
            let grid = makeGrid()
            var configuration = PhotoGridConfiguration(columns: 3,
                showsSectionHeaders: !hero, heroHeight: hero ? 120 : 0, showsAddTile: true)
            if justified { configuration.layoutStyle = .justified }
            grid.apply(sections: [], configuration: configuration,
                hero: hero ? AnyView(Color.clear) : nil)
            await nextMainQueueTurn()
            grid.view.layoutIfNeeded()
            let collection = try collectionView(in: grid)
            let expectedSections = hero ? 2 : 1
            XCTAssertEqual(collection.numberOfSections, expectedSections)
            guard collection.numberOfSections == expectedSections else { continue }
            let path = IndexPath(item: 0, section: hero ? 1 : 0)
            XCTAssertEqual(collection.numberOfItems(inSection: path.section), 1)
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? PhotoGridAddCell)
            XCTAssertGreaterThanOrEqual(cell.frame.height, 44, "Adding the first photo needs a tappable control")
            XCTAssertTrue(cell.isAccessibilityElement)
            XCTAssertEqual(cell.accessibilityLabel, String(localized: "Add Photos"))
            XCTAssertTrue(cell.accessibilityTraits.contains(.button))
            XCTAssertNil(collection.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: path.section)))
            var additions = 0
            var opened: [String] = []
            var selected: Set<String> = []
            grid.onAddTapped = { additions += 1 }
            grid.onOpen = { opened.append($0) }
            grid.onSelectionChanged = { selected = $0 }

            XCTAssertTrue(grid.collectionView(collection, shouldSelectItemAt: path))
            grid.collectionView(collection, didSelectItemAt: path)

            XCTAssertEqual(additions, 1)
            XCTAssertTrue(opened.isEmpty, "The add control must not open a synthetic asset")
            XCTAssertTrue(selected.isEmpty)
            XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)
        }
    }

    func testRemovingTheLastPhotoAndAddingOneBackNeverDuplicatesTheAddControl() async throws {
        let grid = makeGrid()
        let asset = AssetLite(makeTestAsset(id: UUID().uuidString))
        let configuration = PhotoGridConfiguration(columns: 3, showsSectionHeaders: false, showsAddTile: true)
        for assets in [[asset], [], [asset], []] {
            grid.apply(sections: assets.isEmpty ? [] : [section(assets)], configuration: configuration, hero: nil)
            await nextMainQueueTurn()
            grid.view.layoutIfNeeded()
            let collection = try collectionView(in: grid)
            XCTAssertEqual(collection.numberOfSections, 1)
            guard collection.numberOfSections == 1 else { continue }
            XCTAssertEqual(collection.numberOfItems(inSection: 0), assets.count + 1)
            XCTAssertEqual(collection.visibleCells.filter { $0 is PhotoGridAddCell }.count, 1)
            XCTAssertEqual(grid.revealCell(for: asset.id) != nil, !assets.isEmpty)
        }
    }

    func testEmptyCollectionsWithoutAnAddActionDoNotGainASectionOrControl() async throws {
        let grid = makeGrid()
        grid.apply(sections: [], configuration: PhotoGridConfiguration(), hero: nil)
        await nextMainQueueTurn()
        grid.view.layoutIfNeeded()
        let collection = try collectionView(in: grid)
        XCTAssertEqual(collection.numberOfSections, 0)
        XCTAssertFalse(collection.visibleCells.contains { $0 is PhotoGridAddCell })
    }

    func testFilteringEveryPrivatePhotoStillLeavesOnlyTheAddControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("empty-album-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let hidden = AssetLite(makeTestAsset(id: UUID().uuidString))
        try store.setAssetVisibility([hidden.id], to: "locked")
        let grid = makeGrid()
        grid.visibilityPolicy = AssetVisibilityPolicy(scope: .collection, dataManager: store)
        grid.apply(sections: [section([hidden])], configuration: .init(showsAddTile: true), hero: nil)
        await nextMainQueueTurn()
        grid.view.layoutIfNeeded()
        let collection = try collectionView(in: grid)

        XCTAssertNil(grid.revealCell(for: hidden.id))
        XCTAssertNil(grid.visibleAssetForTimelineNavigation())
        XCTAssertEqual(collection.numberOfSections, 1)
        guard collection.numberOfSections == 1 else { return }
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        XCTAssertTrue(collection.cellForItem(at: IndexPath(item: 0, section: 0)) is PhotoGridAddCell)
    }

    func testActualCollectionOnlyOffersItsFirstPhotoActionAfterLoadingSucceeds() async throws {
        let input = EmptyAlbumInput()
        let host = try await host(input)
        try await waitUntil { self.gridController(in: host) != nil }
        let initialGrid = try XCTUnwrap(gridController(in: host))
        await nextMainQueueTurn()
        XCTAssertTrue(try addCells(in: initialGrid).isEmpty)

        input.phase = .loaded(())
        try await waitUntil { (try? self.addCells(in: initialGrid).count) == 1 }
        let collection = try collectionView(in: initialGrid)
        let cell = try XCTUnwrap(try addCells(in: initialGrid).first)
        let path = try XCTUnwrap(collection.indexPath(for: cell))
        initialGrid.collectionView(collection, didSelectItemAt: path)
        XCTAssertEqual(input.additions, 1, "The actual screen forwards the tap to its album picker action")

        input.phase = .failed("Offline")
        try await waitUntil { self.gridController(in: host) == nil }
        XCTAssertEqual(input.additions, 1)
        input.phase = .loading
        try await waitUntil { self.gridController(in: host) != nil }
        let retriedGrid = try XCTUnwrap(gridController(in: host))
        await nextMainQueueTurn()
        XCTAssertTrue(try addCells(in: retriedGrid).isEmpty)
        input.phase = .loaded(())
        try await waitUntil { (try? self.addCells(in: retriedGrid).count) == 1 }
    }

    func testActualCollectionHidesTheControlDuringSelectionAndWhenNoActionIsProvided() async throws {
        let input = EmptyAlbumInput()
        input.phase = .loaded(())
        input.assets = [AssetLite(makeTestAsset(id: UUID().uuidString))]
        let host = try await host(input)
        try await waitUntil {
            guard let grid = self.gridController(in: host) else { return false }
            return (try? self.addCells(in: grid).count) == 1
        }
        let grid = try XCTUnwrap(gridController(in: host))
        grid.onSelectingChanged?(true)
        try await waitUntil { (try? self.addCells(in: grid).isEmpty) == true }
        grid.onSelectingChanged?(false)
        try await waitUntil { (try? self.addCells(in: grid).count) == 1 }
        input.allowsAdding = false
        try await waitUntil { (try? self.addCells(in: grid).isEmpty) == true }
        input.assets = []
        await nextMainQueueTurn()
        XCTAssertTrue(try addCells(in: grid).isEmpty)
        XCTAssertEqual(input.additions, 0)
    }

    func testPendingScrollSnapshotCannotActivateAnAddControlThatIsNoLongerAllowed() async throws {
        for reason in ["configuration", "selection", "both"] {
            let grid = makeGrid()
            let asset = AssetLite(makeTestAsset(id: UUID().uuidString))
            let visible = PhotoGridConfiguration(columns: 3, showsSectionHeaders: false, showsAddTile: true)
            grid.apply(sections: [section([asset])], configuration: visible, hero: nil)
            await nextMainQueueTurn()
            grid.view.layoutIfNeeded()
            let collection = try collectionView(in: grid)
            let addPath = try XCTUnwrap(collection.visibleCells.first(where: { $0 is PhotoGridAddCell })
                .flatMap { collection.indexPath(for: $0) })
            let photoPath = try XCTUnwrap(grid.revealCell(for: asset.id))
            var additions = 0
            var selected: Set<String> = []
            grid.onAddTapped = { additions += 1 }
            grid.onSelectionChanged = { selected = $0 }

            grid.scrollViewWillBeginDragging(collection)
            var current = visible
            current.showsAddTile = reason == "selection"
            grid.apply(sections: [section([asset])], configuration: current, hero: nil)
            grid.setSelecting(reason != "configuration")
            XCTAssertTrue(collection.cellForItem(at: addPath) is PhotoGridAddCell,
                "The old cell must remain visible while its removal snapshot is held")

            XCTAssertFalse(grid.collectionView(collection, shouldSelectItemAt: addPath), reason)
            // UIKit can deliver a selection already admitted before state changed.
            grid.collectionView(collection, didSelectItemAt: addPath)
            XCTAssertEqual(additions, 0, reason)
            XCTAssertTrue(selected.isEmpty)
            XCTAssertTrue(collection.indexPathsForSelectedItems?.isEmpty ?? true)

            grid.setSelecting(true)
            XCTAssertTrue(grid.collectionView(collection, shouldSelectItemAt: photoPath))
            collection.selectItem(at: photoPath, animated: false, scrollPosition: [])
            grid.collectionView(collection, didSelectItemAt: photoPath)
            XCTAssertEqual(selected, [asset.id], "Real photos must remain selectable")

            grid.scrollViewDidEndDragging(collection, willDecelerate: false)
            await nextMainQueueTurn()
            grid.setSelecting(false)
            grid.apply(sections: [section([asset])], configuration: visible, hero: nil)
            await nextMainQueueTurn()
            grid.view.layoutIfNeeded()
            let restoredPath = try XCTUnwrap(collection.visibleCells.first(where: { $0 is PhotoGridAddCell })
                .flatMap { collection.indexPath(for: $0) })
            XCTAssertTrue(grid.collectionView(collection, shouldSelectItemAt: restoredPath))
            grid.collectionView(collection, didSelectItemAt: restoredPath)
            XCTAssertEqual(additions, 1, "Leaving selection and restoring the action must make it usable again")
        }
    }

    private func makeGrid() -> PhotoGridController {
        let session = MockSessionManager()
        let controller = PhotoGridController(loader: PhotoThumbnailLoader(session: session), session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func collectionView(in controller: PhotoGridController) throws -> UICollectionView {
        try XCTUnwrap(controller.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
    }

    private func addCells(in controller: PhotoGridController) throws -> [PhotoGridAddCell] {
        controller.view.layoutIfNeeded()
        return try collectionView(in: controller).visibleCells.compactMap { $0 as? PhotoGridAddCell }
    }

    private func section(_ assets: [AssetLite]) -> TimelineSection {
        .init(id: "2026-10", title: "October", assets: assets, count: assets.count, startIndex: 0)
    }

    private func host(_ input: EmptyAlbumInput) async throws -> UIViewController {
        try await waitUntil { !UIApplication.shared.connectedScenes.isEmpty }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if previousKeyWindow == nil { previousKeyWindow = scene.windows.first { $0.isKeyWindow } }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: EmptyAlbumFixture(input: input)
            .environment(MockSessionManager() as SessionManager))
        window.rootViewController = host
        window.makeKeyAndVisible()
        windows.append(window)
        return host
    }

    private func gridController(in controller: UIViewController) -> PhotoGridController? {
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.gridController(in: $0) }.first
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "The hosted collection must finish its UI update", file: file, line: line)
    }
}

@MainActor @Observable
private final class EmptyAlbumInput {
    var phase: LoadingPhase<Void> = .loading
    var assets: [AssetLite] = []
    var allowsAdding = true
    var additions = 0
}

private struct EmptyAlbumFixture: View {
    let input: EmptyAlbumInput
    var body: some View {
        NavigationStack {
            PhotoCollectionScreen(title: "Album", assets: input.assets, phase: input.phase,
                onRetry: {}, onToggleFavorite: { _ in }, onDelete: { _ in }, shareURLs: { _ in [] },
                onAddPhotos: input.allowsAdding ? { input.additions += 1 } : nil)
        }
    }
}
