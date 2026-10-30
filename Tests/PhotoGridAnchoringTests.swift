import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoGridAnchoringTests: XCTestCase {
    private var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
    }

    func testDensityChangesPreserveTheVisiblePhotoAndItsPixelOffset() async throws {
        let assets = makeAssets(count: 244)
        let sections = makeSections(assets)
        let variants = [
            PhotoGridConfiguration(showsSectionHeaders: false, showsAddTile: true, padsFirstRow: true),
            PhotoGridConfiguration(showsSectionHeaders: true, heroHeight: 170, showsAddTile: true),
            PhotoGridConfiguration(layoutStyle: .justified, showsSectionHeaders: false),
        ]

        for initial in variants {
            var configuration = initial
            let (grid, collection) = try await makeGrid(sections, configuration)
            XCTAssertTrue(grid.scrollToAsset(id: assets[150].id, animated: false))
            collection.contentOffset.y += 27
            await settle(grid)
            grid.setSelecting(true)
            grid.setSelection([assets[150].id, assets[154].id])

            for columns in [5, 2] {
                let anchor = try topPhoto(in: collection, sections: sections, configuration: configuration)
                let oldWidth = try frame(of: anchor.id, in: collection,
                    sections: sections, configuration: configuration).width
                configuration.columns = columns

                grid.apply(sections: sections, configuration: configuration,
                    hero: configuration.heroHeight > 0 ? AnyView(Color.clear) : nil)
                await settle(grid)

                let newFrame = try frame(of: anchor.id, in: collection,
                    sections: sections, configuration: configuration)
                XCTAssertNotEqual(newFrame.width, oldWidth, "The actual UIKit layout must change density")
                XCTAssertEqual(newFrame.minY - collection.contentOffset.y, anchor.offset, accuracy: 1.5,
                    "A density change must retain the old visible photo's position")
                let selected = Set((collection.indexPathsForSelectedItems ?? []).compactMap {
                    asset(at: $0, sections: sections, configuration: configuration)?.id
                })
                XCTAssertEqual(selected, [assets[150].id, assets[154].id])
            }
        }
    }

    func testLayoutAndContentWaitForDecelerationAndApplyOnlyTheLatestRequest() async throws {
        let assets = makeAssets(count: 240)
        let sections = makeSections(assets)
        var configuration = PhotoGridConfiguration(showsSectionHeaders: false, padsFirstRow: true)
        let (grid, collection) = try await makeGrid(sections, configuration)
        XCTAssertTrue(grid.scrollToAsset(id: assets[150].id, animated: false))
        let oldWidth = try frame(of: assets[150].id, in: collection,
            sections: sections, configuration: configuration).width
        grid.scrollViewWillBeginDragging(collection)
        var intermediate = configuration
        intermediate.columns = 5
        let intermediateSections = makeSections(Array(assets.dropFirst(20)))

        grid.apply(sections: intermediateSections, configuration: intermediate, hero: nil)
        collection.layoutIfNeeded()

        XCTAssertEqual(try frame(of: assets[150].id, in: collection,
            sections: sections, configuration: configuration).width, oldWidth, accuracy: 0.1)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 240)
        collection.contentOffset.y += 41
        let anchor = try topPhoto(in: collection, sections: sections, configuration: configuration)
        configuration.columns = 2
        let finalSections = makeSections(Array(assets.dropFirst(30)))
        grid.apply(sections: finalSections, configuration: configuration, hero: nil)
        grid.scrollViewDidEndDragging(collection, willDecelerate: true)
        await settle(grid)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 240)
        XCTAssertEqual(try frame(of: assets[150].id, in: collection,
            sections: sections, configuration: .init(showsSectionHeaders: false, padsFirstRow: true)).width,
            oldWidth, accuracy: 0.1)

        grid.scrollViewDidEndDecelerating(collection)
        await settle(grid)

        XCTAssertEqual(collection.numberOfItems(inSection: 0), 210)
        let restored = try frame(of: anchor.id, in: collection,
            sections: finalSections, configuration: configuration)
        XCTAssertEqual(restored.minY - collection.contentOffset.y, anchor.offset, accuracy: 1.5)
        XCTAssertGreaterThan(restored.width, oldWidth)
        XCTAssertFalse(grid.scrollToAsset(id: assets[0].id, animated: false))
    }

    func testIntentionalNewestPositionSurvivesDensityAndContentChanges() async throws {
        var assets = makeAssets(count: 240)
        var configuration = PhotoGridConfiguration(showsSectionHeaders: false,
            startsAtNewest: true, padsFirstRow: true)
        let (grid, collection) = try await makeGrid(makeSections(assets), configuration)
        XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)

        for columns in [5, 2] {
            configuration.columns = columns
            assets.append(contentsOf: makeAssets(count: 1))
            let sections = makeSections(assets)
            grid.apply(sections: sections, configuration: configuration, hero: nil)
            await settle(grid)

            XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)
            let last = try XCTUnwrap(assets.last)
            XCTAssertTrue(try frame(of: last.id, in: collection,
                sections: sections, configuration: configuration).intersects(collection.bounds))
        }
    }

    func testNonDragScrollingPreservesItsPositionWhenDensityChanges() async throws {
        let assets = makeAssets(count: 240)
        let sections = makeSections(assets)
        var configuration = PhotoGridConfiguration(showsSectionHeaders: false,
            startsAtNewest: true, padsFirstRow: true)
        let (grid, collection) = try await makeGrid(sections, configuration)
        XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)

        collection.setContentOffset(CGPoint(x: 0,
            y: collection.contentOffset.y - collection.bounds.height * 3), animated: false)
        collection.layoutIfNeeded()
        let anchor = try topPhoto(in: collection, sections: sections, configuration: configuration)
        let offsetBeforeLayout = collection.contentOffset.y
        grid.view.setNeedsLayout()
        grid.view.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset.y, offsetBeforeLayout, accuracy: 1.5,
            "A controller layout pass must not repin a non-drag scroll")
        configuration.columns = 5
        grid.apply(sections: sections, configuration: configuration, hero: nil)
        await settle(grid)
        let restored = try frame(of: anchor.id, in: collection,
            sections: sections, configuration: configuration)
        XCTAssertEqual(restored.minY - collection.contentOffset.y, anchor.offset, accuracy: 1.5)
        XCTAssertLessThan(collection.contentOffset.y, newestOffset(collection) - 10)
    }

    func testShortLibraryKeepsTheNewestIntentForLaterPhotos() async throws {
        var assets = makeAssets(count: 2)
        let configuration = PhotoGridConfiguration(showsSectionHeaders: false, startsAtNewest: true)
        let (grid, collection) = try await makeGrid(makeSections(assets), configuration)
        XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)

        assets.append(contentsOf: makeAssets(count: 240))
        grid.apply(sections: makeSections(assets), configuration: configuration, hero: nil)
        await settle(grid)

        XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)
        XCTAssertGreaterThan(collection.contentOffset.y, 100)
    }

    func testNewestAnchorSurvivesViewportResizeBeforeAContentUpdate() async throws {
        var assets = makeAssets(count: 240)
        let configuration = PhotoGridConfiguration(showsSectionHeaders: false,
            startsAtNewest: true, padsFirstRow: true)
        let (grid, collection) = try await makeGrid(makeSections(assets), configuration)
        let oldWidth = collection.bounds.width
        let window = try XCTUnwrap(grid.view.window)
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        grid.view.frame = window.bounds
        collection.frame = grid.view.bounds
        assets.append(contentsOf: makeAssets(count: 1))

        grid.apply(sections: makeSections(assets), configuration: configuration, hero: nil)
        await settle(grid)

        XCTAssertGreaterThan(collection.bounds.width, oldWidth)
        XCTAssertEqual(collection.contentOffset.y, newestOffset(collection), accuracy: 1.5)
    }

    private func makeGrid(
        _ sections: [TimelineSection],
        _ configuration: PhotoGridConfiguration
    ) async throws -> (PhotoGridController, UICollectionView) {
        try await waitUntil { !UIApplication.shared.connectedScenes.isEmpty }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if previousKeyWindow == nil { previousKeyWindow = scene.windows.first { $0.isKeyWindow } }
        let grid = PhotoGridController(loader: AnchoringThumbnailLoader(), session: MockSessionManager())
        grid.apply(sections: sections, configuration: configuration,
            hero: configuration.heroHeight > 0 ? AnyView(Color.clear) : nil)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = grid
        window.makeKeyAndVisible()
        windows.append(window)
        await settle(grid)
        let collection = try XCTUnwrap(grid.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
        try await waitUntil { collection.alpha == 1 && collection.numberOfSections > 0 }
        return (grid, collection)
    }

    private func makeAssets(count: Int) -> [AssetLite] {
        (0..<count).map { index in
            AssetLite(id: UUID().uuidString, isVideo: false,
                ratio: [0.6, 1.0, 1.8][index % 3], thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 86_400)))
        }
    }

    private func makeSections(_ assets: [AssetLite]) -> [TimelineSection] {
        let split = min(120, assets.count)
        return [Array(assets.prefix(split)), Array(assets.dropFirst(split))]
            .enumerated().compactMap { index, group in
                guard !group.isEmpty else { return nil }
                return TimelineSection(id: "section-\(index)", title: "Month \(index)",
                    assets: group, count: group.count, startIndex: index == 0 ? 0 : split)
            }
    }

    private func asset(
        at path: IndexPath,
        sections: [TimelineSection],
        configuration: PhotoGridConfiguration
    ) -> AssetLite? {
        let section = path.section - (configuration.heroHeight > 0 ? 1 : 0)
        guard section >= 0 else { return nil }
        if configuration.showsSectionHeaders {
            guard sections.indices.contains(section), sections[section].assets.indices.contains(path.item)
            else { return nil }
            return sections[section].assets[path.item]
        }
        let assets = sections.flatMap(\.assets)
        let columns = max(configuration.columns, 1)
        let remainder = assets.count % columns
        let padding = configuration.padsFirstRow && remainder != 0 ? columns - remainder : 0
        let index = path.item - padding
        return assets.indices.contains(index) ? assets[index] : nil
    }

    private func frame(
        of id: String,
        in collection: UICollectionView,
        sections: [TimelineSection],
        configuration: PhotoGridConfiguration
    ) throws -> CGRect {
        for section in 0..<collection.numberOfSections {
            for item in 0..<collection.numberOfItems(inSection: section) {
                let path = IndexPath(item: item, section: section)
                if asset(at: path, sections: sections, configuration: configuration)?.id == id {
                    return try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame
                }
            }
        }
        XCTFail("Expected photo is absent from the collection")
        throw CancellationError()
    }

    private func topPhoto(
        in collection: UICollectionView,
        sections: [TimelineSection],
        configuration: PhotoGridConfiguration
    ) throws -> (id: String, offset: CGFloat) {
        for path in collection.indexPathsForVisibleItems.sorted() {
            if let photo = asset(at: path, sections: sections, configuration: configuration),
               let attributes = collection.layoutAttributesForItem(at: path) {
                return (photo.id, attributes.frame.minY - collection.contentOffset.y)
            }
        }
        XCTFail("Expected a visible photo to anchor")
        throw CancellationError()
    }

    private func newestOffset(_ collection: UICollectionView) -> CGFloat {
        max(-collection.adjustedContentInset.top,
            collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height)
    }

    private func settle(_ grid: PhotoGridController) async {
        for _ in 0..<4 {
            grid.view.layoutIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The UIKit collection did not reach the expected state")
        throw CancellationError()
    }
}

@MainActor
private final class AnchoringThumbnailLoader: PhotoThumbnailLoader {
    private let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }

    init() { super.init(session: MockSessionManager()) }

    override func cachedImage(for assetId: String) -> UIImage? { thumbnail }
}
