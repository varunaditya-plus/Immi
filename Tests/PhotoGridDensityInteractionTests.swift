import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoGridDensityInteractionTests: SimulatorHostedTestCase {
    func testMenuZoomChangesRealDensityKeepsCentroidPhotoAndRetainsSelection() async throws {
        let fixture = try await grid()
        fixture.controller.setSelecting(true)
        fixture.controller.setSelection([fixture.assets[155].id, fixture.assets[159].id])
        let anchor = try centroidPhoto(fixture)
        let originalWidth = try frame(anchor.id, fixture).width
        var settled: [Int] = []
        fixture.controller.onDensityChanged = { settled.append($0) }

        fixture.controller.zoomDensity(in: false)
        try await waitUntil("The actual layout settles at five columns") { settled == [5] }
        fixture.collection.layoutIfNeeded()
        let restored = try frame(anchor.id, fixture)
        XCTAssertEqual(restored.minY + anchor.fraction * restored.height - fixture.collection.contentOffset.y,
            anchor.viewportY, accuracy: 2)
        XCTAssertEqual(settled, [5])
        XCTAssertLessThan(restored.width, originalWidth - 10)
        let padding = fixture.collection.numberOfItems(inSection: 0) - fixture.assets.count
        XCTAssertEqual(Set((fixture.collection.indexPathsForSelectedItems ?? []).map { $0.item - padding }), [155, 159])
    }

    func testPinchProgressChangesActualCellGeometryBeforeCommitAndCanCancel() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        let oldWidth = try frame(anchor.id, fixture).width
        var settled: [Int] = []
        fixture.controller.onDensityChanged = { settled.append($0) }
        fixture.controller.beginDensityZoom(at: anchor.contentPoint)
        fixture.controller.updateDensityZoom(scale: 0.8, at: anchor.contentPoint)
        fixture.collection.layoutIfNeeded()
        let intermediate = try frame(anchor.id, fixture)
        XCTAssertLessThan(intermediate.width, oldWidth - 1,
            "The gesture must interpolate real collection-view frames, rather than only write a setting")
        XCTAssertGreaterThan(intermediate.width, (fixture.collection.bounds.width - 8) / 5 + 1)
        XCTAssertEqual(intermediate.minY + anchor.fraction * intermediate.height - fixture.collection.contentOffset.y,
            anchor.viewportY, accuracy: 2)

        fixture.controller.finishDensityZoom(committing: false)
        try await waitUntil("Canceled pinch restores its real layout") {
            abs(((try? self.frame(anchor.id, fixture).width) ?? 0) - oldWidth) < 1
        }
        XCTAssertTrue(settled.isEmpty, "Canceled gestures must not overwrite the density preference")
    }

    func testCommittedPinchKeepsTouchedPhotoAcrossPaddingChangesAndThenAcceptsUpdates() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        var settled: [Int] = []
        fixture.controller.onDensityChanged = { settled.append($0) }
        fixture.controller.beginDensityZoom(at: anchor.contentPoint)
        fixture.controller.updateDensityZoom(scale: 0.6, at: anchor.contentPoint)
        fixture.controller.finishDensityZoom(committing: true)
        try await waitUntil("Pinch commits and publishes the new density") { settled == [5] }
        try await Task.sleep(for: .milliseconds(100))
        fixture.collection.layoutIfNeeded()
        let frame = try frame(anchor.id, fixture)
        XCTAssertEqual(frame.minY + anchor.fraction * frame.height - fixture.collection.contentOffset.y,
            anchor.viewportY, accuracy: 2)
        XCTAssertEqual(frame.width, (fixture.collection.bounds.width - 8) / 5, accuracy: 1)
        let remaining = Array(fixture.assets.dropFirst(10))
        fixture.controller.apply(sections: [TimelineSection(id: "month", title: "Month", assets: remaining)],
            configuration: .init(columns: 5, allowsDensityZoom: true, showsSectionHeaders: false, padsFirstRow: true), hero: nil)
        try await waitUntil("New data is no longer held after the pinch") {
            fixture.collection.numberOfItems(inSection: 0) == 235
        }
    }

    func testNativeMultiSelectionKeepsPinchOutOfSelectionGestures() async throws {
        let fixture = try await grid()
        let pinch = try XCTUnwrap(fixture.collection.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)
        XCTAssertTrue(fixture.controller.gestureRecognizerShouldBegin(pinch))
        fixture.controller.setSelecting(true)
        XCTAssertFalse(fixture.controller.gestureRecognizerShouldBegin(pinch))
        XCTAssertTrue(fixture.collection.allowsMultipleSelectionDuringEditing)
    }

    func testSnapshotWaitsFromPinchBeginAndCancelBeforeThresholdReleasesIt() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        fixture.controller.beginDensityZoom(at: anchor.contentPoint)
        let remaining = Array(fixture.assets.dropFirst(10))
        fixture.controller.apply(sections: [TimelineSection(id: "month", title: "Month", assets: remaining)],
            configuration: .init(allowsDensityZoom: true, showsSectionHeaders: false, padsFirstRow: true), hero: nil)
        fixture.collection.layoutIfNeeded()
        XCTAssertEqual(fixture.collection.numberOfItems(inSection: 0), 243)
        fixture.controller.finishDensityZoom(committing: false)
        try await waitUntil("Cancel before threshold must release the held snapshot") {
            fixture.collection.numberOfItems(inSection: 0) == 231
        }
    }

    func testSquarePinchKeepsTheSamePhotoUnderTheFingersInBothAxes() async throws {
        for x: CGFloat in [35, 133, 195, 325, 385] {
            let fixture = try await grid()
            let anchor = try centroidPhoto(fixture, viewportX: x)
            fixture.controller.beginDensityZoom(at: anchor.contentPoint)
            for scale: CGFloat in [0.95, 0.85, 0.75, 0.6] {
                let contentPoint = CGPoint(x: x + fixture.collection.contentOffset.x,
                    y: anchor.viewportY + fixture.collection.contentOffset.y)
                fixture.controller.updateDensityZoom(scale: scale, at: contentPoint)
                fixture.collection.layoutIfNeeded()
                let actual = try frame(anchor.id, fixture)
                let displayed = actual.offsetBy(dx: -fixture.collection.contentOffset.x,
                    dy: -fixture.collection.contentOffset.y)
                XCTAssertTrue(displayed.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: anchor.viewportY)),
                    "The same photo must stay under the gesture rather than jump several columns")
                XCTAssertEqual(displayed.minY + anchor.fraction * displayed.height, anchor.viewportY, accuracy: 2)
                let fractionX = displayed.minX + anchor.fractionX * displayed.width
                XCTAssertLessThanOrEqual(abs(fractionX - x), displayed.width + 2,
                    "Any fractional-pixel drift stays within one tile, including near column edges")
                if x == 195 { XCTAssertEqual(fractionX, x, accuracy: 2) }
            }
            fixture.controller.finishDensityZoom(committing: false)
            try await waitUntil("Canceled focal layout returns to the original grid") {
                abs(((try? self.frame(anchor.id, fixture).width) ?? 0) - (fixture.collection.bounds.width - 4) / 3) < 1
            }
            let restored = try frame(anchor.id, fixture)
            XCTAssertEqual(restored.minX + restored.width * anchor.fractionX - fixture.collection.contentOffset.x, x, accuracy: 2)
            XCTAssertEqual(restored.minY + restored.height * anchor.fraction - fixture.collection.contentOffset.y,
                anchor.viewportY, accuracy: 2)
        }
    }

    func testFocalCommitSettlesToNormalPaddingAndCanReturnToNewest() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        var settled: [Int] = []
        fixture.controller.onDensityChanged = { settled.append($0) }
        fixture.controller.beginDensityZoom(at: anchor.contentPoint)
        fixture.controller.updateDensityZoom(scale: 0.6, at: anchor.contentPoint)
        let during = try frame(anchor.id, fixture)
        XCTAssertEqual(during.midX - fixture.collection.contentOffset.x, anchor.viewportX, accuracy: 2)
        fixture.controller.finishDensityZoom(committing: true)
        try await waitUntil("Released pinch settles before publishing its preference") { settled == [5] }
        XCTAssertEqual(fixture.collection.numberOfItems(inSection: 0), 245,
            "Temporary focal padding must not become persistent library content")
        let final = try frame(anchor.id, fixture)
        XCTAssertEqual(final.minY + final.height * anchor.fraction - fixture.collection.contentOffset.y,
            anchor.viewportY, accuracy: 2)
        fixture.controller.scrollToNewest(animated: false)
        fixture.collection.layoutIfNeeded()
        XCTAssertTrue(try frame(fixture.assets.last!.id, fixture).intersects(fixture.collection.bounds))
    }

    func testFocalLayoutHandlesBothZoomDirectionsIncludingTenColumnPadding() async throws {
        for columns in [1, 3, 5, 10] {
            let fixture = try await grid(columns: columns)
            let anchor = try centroidPhoto(fixture, viewportX: 185)
            let target = try XCTUnwrap(PhotoGridDensity.next(columns: columns, zoomingIn: columns != 1))
            fixture.controller.beginDensityZoom(at: anchor.contentPoint)
            fixture.controller.updateDensityZoom(scale: CGFloat(columns) / CGFloat(target), at: anchor.contentPoint)
            fixture.collection.layoutIfNeeded()
            let during = try frame(anchor.id, fixture).offsetBy(dx: -fixture.collection.contentOffset.x,
                dy: -fixture.collection.contentOffset.y)
            XCTAssertTrue(during.insetBy(dx: -1, dy: -1).contains(CGPoint(x: 185, y: anchor.viewportY)))
            XCTAssertEqual(during.minY + during.height * anchor.fraction, anchor.viewportY, accuracy: 2)
            fixture.controller.finishDensityZoom(committing: false)
            try await waitUntil("Canceled zoom restores its source density") {
                abs(((try? self.frame(anchor.id, fixture).width) ?? 0)
                    - (fixture.collection.bounds.width - CGFloat(columns - 1) * 2) / CGFloat(columns)) < 1
            }
        }
    }

    func testRemovingTheAnchorDuringAnimatedMenuZoomDoesNotPersistAWrongDensity() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        let remaining = fixture.assets.filter { $0.id != anchor.id }
        var published: [Int] = []
        fixture.controller.onDensityChanged = { published.append($0) }
        fixture.controller.zoomDensity(in: false)
        fixture.controller.apply(sections: [TimelineSection(id: "month", title: "Month", assets: remaining)],
            configuration: .init(allowsDensityZoom: true, showsSectionHeaders: false, padsFirstRow: true), hero: nil)
        try await waitUntil("The canceled menu zoom releases its latest content snapshot") {
            fixture.collection.numberOfItems(inSection: 0) == 240
        }
        XCTAssertTrue(published.isEmpty)
        let refreshed = Fixture(controller: fixture.controller, collection: fixture.collection, assets: remaining)
        XCTAssertEqual(try frame(remaining[155].id, refreshed).width, (fixture.collection.bounds.width - 4) / 3, accuracy: 1)
        XCTAssertFalse(fixture.controller.scrollToAsset(id: anchor.id, animated: false))
    }

    func testPinchBeginningInAColumnGapUsesTheClosestPhoto() async throws {
        let fixture = try await grid()
        let expected = try centroidPhoto(fixture, viewportX: 132)
        let original = try frame(expected.id, fixture)
        let point = CGPoint(x: original.minX - 0.8, y: expected.contentPoint.y)
        fixture.controller.beginDensityZoom(at: point)
        fixture.controller.updateDensityZoom(scale: 0.6, at: point)
        fixture.collection.layoutIfNeeded()
        let actual = try frame(expected.id, fixture).offsetBy(dx: -fixture.collection.contentOffset.x,
            dy: -fixture.collection.contentOffset.y)
        XCTAssertTrue(actual.contains(CGPoint(x: point.x, y: expected.viewportY)),
            "The anchor fallback must consider X distance, rather than an arbitrary photo in the same row")
        fixture.controller.finishDensityZoom(committing: false)
        try await waitUntil("Gap-anchor cancellation restores its real source layout") {
            abs(((try? self.frame(expected.id, fixture).width) ?? 0) - original.width) < 1
        }
    }

    func testChangedCentroidSetsTargetColumnAndKeepsLatestYForSettlement() async throws {
        let fixture = try await grid()
        let anchor = try centroidPhoto(fixture)
        fixture.controller.beginDensityZoom(at: anchor.contentPoint)
        let movedX: CGFloat = 385
        var movedY = anchor.viewportY + 40
        fixture.controller.updateDensityZoom(scale: 0.6,
            at: CGPoint(x: movedX, y: movedY + fixture.collection.contentOffset.y))
        fixture.collection.layoutIfNeeded()
        var actual = try frame(anchor.id, fixture)
        XCTAssertTrue(actual.contains(CGPoint(x: movedX, y: movedY + fixture.collection.contentOffset.y)),
            "The first changed event must choose its current column, rather than the begin location")
        movedY += 20
        fixture.controller.updateDensityZoom(scale: 0.6,
            at: CGPoint(x: movedX, y: movedY + fixture.collection.contentOffset.y))
        fixture.collection.layoutIfNeeded()
        actual = try frame(anchor.id, fixture)
        XCTAssertEqual(actual.minY + actual.height * anchor.fraction - fixture.collection.contentOffset.y, movedY, accuracy: 2)
        let transition = try XCTUnwrap(fixture.collection.collectionViewLayout as? UICollectionViewTransitionLayout)
        let targetOffset = transition.nextLayout.targetContentOffset(forProposedContentOffset:
            CGPoint(x: 0, y: fixture.collection.contentOffset.y + 100))
        XCTAssertEqual(targetOffset.y, actual.minY + actual.height * anchor.fraction - movedY, accuracy: 2,
            "UIKit's final animation target must use the latest centroid instead of returning to the begin Y")
        var settled: [Int] = []
        fixture.controller.onDensityChanged = { settled.append($0) }
        fixture.controller.finishDensityZoom(committing: true)
        try await waitUntil("Moved-centroid pinch settles") { settled == [5] }
        let final = try frame(anchor.id, fixture)
        XCTAssertEqual(final.minY + final.height * anchor.fraction - fixture.collection.contentOffset.y, movedY, accuracy: 2)
    }

    func testFocalSquareLayoutRetainsHeroHeadersAndAddTile() async throws {
        for (hero, headers) in [(false, true), (true, false), (true, true)] {
            let fixture = try await grid(hero: hero, headers: headers, addTile: true)
            let anchor = try centroidPhoto(fixture)
            let original = try frame(anchor.id, fixture)
            let originalCount = fixture.collection.numberOfItems(inSection: fixture.photoSection)
            fixture.controller.beginDensityZoom(at: anchor.contentPoint)
            fixture.controller.updateDensityZoom(scale: 0.6, at: anchor.contentPoint)
            fixture.collection.layoutIfNeeded()
            let during = try frame(anchor.id, fixture)
            XCTAssertTrue(during.contains(CGPoint(x: anchor.viewportX, y: anchor.viewportY + fixture.collection.contentOffset.y)))
            XCTAssertEqual(fixture.collection.numberOfItems(inSection: fixture.photoSection), originalCount,
                "Temporary alignment cannot insert real snapshot items or consume Add Photos")
            if hero { XCTAssertEqual(fixture.collection.numberOfItems(inSection: 0), 1) }
            if headers {
                XCTAssertNotNil(fixture.collection.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                    at: IndexPath(item: 0, section: fixture.photoSection)))
            }
            fixture.controller.finishDensityZoom(committing: false)
            try await waitUntil("Complex-layout cancellation restores its actual grid") {
                abs(((try? self.frame(anchor.id, fixture).width) ?? 0) - original.width) < 1
            }
            XCTAssertEqual(fixture.collection.numberOfItems(inSection: fixture.photoSection), originalCount)
        }
    }

    private struct Fixture {
        let controller: PhotoGridController
        let collection: UICollectionView
        let assets: [AssetLite]
        var photoSection = 0
        var addsTile = false
    }

    private struct Anchor {
        let id: String
        let fraction: CGFloat
        let fractionX: CGFloat
        let viewportX: CGFloat
        let viewportY: CGFloat
        let contentPoint: CGPoint
    }

    private func grid(columns: Int = 3, hero: Bool = false, headers: Bool = false,
                      addTile: Bool = false) async throws -> Fixture {
        let assets = (0..<241).map { index in
            AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: Double(index * 86_400)))
        }
        let controller = PhotoGridController(loader: DensityThumbnailLoader(), session: MockSessionManager())
        controller.apply(sections: [TimelineSection(id: "month", title: "Month", assets: assets)],
            configuration: .init(columns: columns, allowsDensityZoom: true, showsSectionHeaders: headers,
                heroHeight: hero ? 170 : 0, showsAddTile: addTile, padsFirstRow: true),
            hero: hero ? AnyView(Color.clear) : nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows.append(window)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let collection = try XCTUnwrap(controller.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
        let photoSection = hero ? 1 : 0
        let expectedItems = assets.count + (headers ? 0 : (columns - assets.count % columns) % columns) + (addTile ? 1 : 0)
        try await waitUntil("Actual collection snapshot has all fixtures") {
            collection.numberOfSections > photoSection && collection.numberOfItems(inSection: photoSection) == expectedItems
        }
        XCTAssertTrue(controller.scrollToAsset(id: assets[155].id, animated: false))
        controller.view.layoutIfNeeded()
        return Fixture(controller: controller, collection: collection, assets: assets,
            photoSection: photoSection, addsTile: addTile)
    }

    private func centroidPhoto(_ fixture: Fixture, viewportX: CGFloat? = nil) throws -> Anchor {
        let collection = fixture.collection
        let point = CGPoint(x: (viewportX ?? collection.bounds.width / 2) + collection.contentOffset.x,
            y: collection.bounds.midY)
        let path = try XCTUnwrap(collection.indexPathForItem(at: point))
        let cell = try XCTUnwrap(collection.cellForItem(at: path) as? PhotoGridCell)
        let id = try XCTUnwrap(fixture.assets.first { PhotoAssetAccessibility.label(for: $0) == cell.accessibilityLabel }?.id)
        let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: path)?.frame)
        return Anchor(id: id, fraction: (point.y - frame.minY) / frame.height,
            fractionX: (point.x - frame.minX) / frame.width,
            viewportX: point.x - collection.contentOffset.x,
            viewportY: point.y - collection.contentOffset.y, contentPoint: point)
    }

    private func frame(_ id: String, _ fixture: Fixture) throws -> CGRect {
        let index = try XCTUnwrap(fixture.assets.firstIndex { $0.id == id })
        let count = fixture.collection.numberOfItems(inSection: fixture.photoSection)
        let pad = count - fixture.assets.count - (fixture.addsTile ? 1 : 0)
        return try XCTUnwrap(fixture.collection.layoutAttributesForItem(at: IndexPath(item: index + pad, section: fixture.photoSection))?.frame)
    }
}

@MainActor
private final class DensityThumbnailLoader: PhotoThumbnailLoader {
    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { UIImage(systemName: "photo") }
}
