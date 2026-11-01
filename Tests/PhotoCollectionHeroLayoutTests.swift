import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCollectionHeroLayoutTests: ViewerAdaptiveLayoutTestCase {
    private var cacheKeys: [String] = []
    private var preferences: [String: Any] = [:]
    private let preferenceKeys = [SettingsViewModel.gridColumnsKey, "library.aspectRatioGrid"]

    override func setUp() {
        super.setUp()
        for key in preferenceKeys { preferences[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(3, forKey: SettingsViewModel.gridColumnsKey)
        UserDefaults.standard.set(false, forKey: "library.aspectRatioGrid")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        cacheKeys.removeAll()
        for key in preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        preferences.removeAll()
    }

    func testLoadedHeroResizesWithTheViewportAndKeepsItsTitleCountAndFirstGridRowVisibleInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let photos = cachedPhotos()
            let window = try await host(collection(title: "Holidays", photos: photos), style: style)
            for size in [CGSize(width: 390, height: 844), CGSize(width: 568, height: 320),
                         CGSize(width: 900, height: 420),
                         CGSize(width: 390, height: 844)] {
                resize(window, to: size)
                let grid = try await actualGrid(in: window, photoCount: photos.count)
                try await waitUntil("The real collection hero reaches its viewport height") {
                    let height = grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height ?? 0
                    return size.width < size.height ? abs(height - 420) < 1
                        : height > size.height * 0.5 && height < size.height * 0.8
                }
                grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
                let hero = try XCTUnwrap(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
                let first = try XCTUnwrap(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
                XCTAssertEqual(first.frame.minY - hero.frame.maxY, 2, accuracy: 0.5,
                    "The hero and first row must keep the same two-point gap as the photo grid")
                let heroFrame = grid.convert(hero.frame, to: window)
                let firstFrame = grid.convert(first.frame, to: window)
                for label in ["Holidays", "12 items"] {
                    let object = try XCTUnwrap(accessibilityObject(label, in: window))
                    let frame = window.convert(object.accessibilityFrame, from: nil)
                    XCTAssertTrue(window.bounds.contains(frame), "The actual \(label) must be visible at entry in \(size)")
                    XCTAssertTrue(heroFrame.insetBy(dx: -1, dy: -1).contains(frame))
                }
                XCTAssertLessThan(firstFrame.minY, window.bounds.maxY - 20,
                    "The first loaded grid row must be visible below the collection title")
                let image = try await screenshot(window)
                try assertGreenPhoto(in: image, frame: heroFrame.intersection(window.bounds))
                try assertGreenPhoto(in: image, frame: firstFrame.intersection(window.bounds))
            }
            window.isHidden = true
        }
    }

    func testActualToolbarTitleDocksAfterScrollingAndUndocksOnReturnInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for size in [CGSize(width: 390, height: 844), CGSize(width: 568, height: 320)] {
                let photos = cachedPhotos(count: 64)
                let window = try await host(collection(title: "Holidays", photos: photos), style: style)
                resize(window, to: size)
                let grid = try await actualGrid(in: window, photoCount: photos.count)
                let controller = try XCTUnwrap(gridController(in: window.rootViewController))
                try await waitUntil("The actual hero reports a usable title location") {
                    controller.titleDockContentY.isFinite
                }
                let bar = try XCTUnwrap(descendants(window).compactMap { $0 as? UINavigationBar }.first)
                grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                let initialTitle = try await renderedBarTitle(in: bar, window: window)
                XCTAssertFalse(initialTitle.contains("Holidays"),
                    "The native toolbar must leave the visible hero title unduplicated at entry")

                grid.setContentOffset(CGPoint(x: 0,
                    y: grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.bottom), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                let dockedTitle = try await renderedBarTitle(in: bar, window: window)
                XCTAssertTrue(dockedTitle.contains("Holidays"),
                    "The actual toolbar must visibly show the collection title after its hero scrolls away: \(dockedTitle)")

                grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                let returnedTitle = try await renderedBarTitle(in: bar, window: window)
                XCTAssertFalse(returnedTitle.contains("Holidays"),
                    "Returning to the loaded hero must hide the duplicate toolbar title")
                window.isHidden = true
            }
        }
    }

    private func gridController(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        for child in controller.children {
            if let grid = gridController(in: child) { return grid }
        }
        return nil
    }

    private func renderedBarTitle(in bar: UINavigationBar, window: UIWindow) async throws -> String {
        let snapshot = try await screenshot(window)
        let frame = bar.convert(bar.bounds, to: window).intersection(window.bounds)
        XCTAssertGreaterThan(frame.height, 20)
        let crop = try XCTUnwrap(snapshot.cgImage?.cropping(to: frame.applying(
            CGAffineTransform(scaleX: snapshot.scale, y: snapshot.scale))))
        return try renderedStrings(UIImage(cgImage: crop)).joined(separator: " ")
    }

    func testLongAccessibilityTitleAndCountGrowTheActualHeroAndRemainReachableWithoutOverlappingTheGrid() async throws {
        let title = "Holidays with family through all the years"
        for style in [UIUserInterfaceStyle.light, .dark] {
            let photos = cachedPhotos()
            let window = try await host(collection(title: title, photos: photos)
                .dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 320, height: 568))
            let grid = try await actualGrid(in: window, photoCount: photos.count)
            try await waitUntil("The real hero grows to contain the long preferred-size caption") {
                guard let titleObject = self.accessibilityObject(title, in: window),
                      let count = self.accessibilityObject("12 items", in: window),
                      let hero = grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else { return false }
                let titleFrame = window.convert(titleObject.accessibilityFrame, from: nil)
                let countFrame = window.convert(count.accessibilityFrame, from: nil)
                let heroFrame = grid.convert(hero.frame, to: window)
                return titleFrame.height > 200 && hero.frame.height > 420
                    && titleFrame.minY >= heroFrame.minY && countFrame.maxY <= heroFrame.maxY + 1
            }
            let controller = try XCTUnwrap(gridController(in: window.rootViewController))
            XCTAssertTrue(controller.titleDockContentY.isFinite,
                "A long accessibility caption must retain a real toolbar docking threshold, even when it starts at the top of the hero")
            let titleObject = try XCTUnwrap(accessibilityObject(title, in: window))
            let count = try XCTUnwrap(accessibilityObject("12 items", in: window))
            let titleFrame = window.convert(titleObject.accessibilityFrame, from: nil)
            let countFrame = window.convert(count.accessibilityFrame, from: nil)
            let first = try XCTUnwrap(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
            XCTAssertGreaterThanOrEqual(countFrame.minY, titleFrame.maxY)
            XCTAssertGreaterThanOrEqual(grid.convert(first.frame, to: window).minY, countFrame.maxY)
            grid.scrollRectToVisible(grid.convert(countFrame, from: window).insetBy(dx: 0, dy: -8), animated: false)
            let text = try renderedStrings(await screenshot(window)).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("items"), "The actual count must render when the long caption is scrolled into view: \(text)")
            grid.scrollToItem(at: IndexPath(item: 0, section: 1), at: .top, animated: false)
            let image = try await screenshot(window)
            let firstFrame = grid.convert(first.frame, to: window).intersection(window.bounds)
            XCTAssertGreaterThan(firstFrame.height, 20)
            try assertGreenPhoto(in: image, frame: firstFrame)
            window.isHidden = true
        }
    }

    func testLongAccessibilityHeroKeepsItsMeasuredHeightAndDockingWhenScrolledOffscreenAndBack() async throws {
        let title = "Our holidays with family through all the years"
        let heroPath = IndexPath(item: 0, section: 0)
        let firstPhotoPath = IndexPath(item: 0, section: 1)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let photos = cachedPhotos(count: 64)
            let window = try await host(collection(title: title, photos: photos)
                .dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 320, height: 568))
            let grid = try await actualGrid(in: window, photoCount: photos.count)
            let controller = try XCTUnwrap(gridController(in: window.rootViewController))
            let bar = try XCTUnwrap(descendants(window).compactMap { $0 as? UINavigationBar }.first)
            try await waitUntil("The loaded accessibility hero contains its natural long caption before recycling") {
                guard let titleObject = self.accessibilityObject(title, in: window),
                      let count = self.accessibilityObject("64 items", in: window),
                      let hero = grid.layoutAttributesForItem(at: heroPath) else { return false }
                let heroFrame = grid.convert(hero.frame, to: window)
                let titleFrame = window.convert(titleObject.accessibilityFrame, from: nil)
                let countFrame = window.convert(count.accessibilityFrame, from: nil)
                return hero.frame.height > 420 && titleFrame.height > 200
                    && heroFrame.insetBy(dx: -1, dy: -1).contains(titleFrame)
                    && heroFrame.insetBy(dx: -1, dy: -1).contains(countFrame)
                    && controller.titleDockContentY.isFinite
            }
            grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
            let initialBarText = try await renderedPrincipalTitle(in: bar, window: window)
            let height = try XCTUnwrap(grid.layoutAttributesForItem(at: heroPath)).frame.height
            let firstRowY = try XCTUnwrap(grid.layoutAttributesForItem(at: firstPhotoPath)).frame.minY
            let contentHeight = grid.contentSize.height
            let dockingThreshold = controller.titleDockContentY
            XCTAssertGreaterThan(height, 420)
            XCTAssertGreaterThan(dockingThreshold, 0)

            let bottom = grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.bottom
            XCTAssertGreaterThan(bottom, height,
                "The fixture must scroll farther than the entire hero to exercise its offscreen lifecycle")
            grid.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await waitUntil("The final rows are visible while the long hero is entirely outside the viewport") {
                grid.layoutIfNeeded()
                guard let hero = grid.layoutAttributesForItem(at: heroPath) else { return false }
                return !hero.frame.intersects(grid.bounds)
                    && !grid.indexPathsForVisibleItems.contains(heroPath)
                    && !grid.visibleCells.contains { $0 is PhotoGridHostCell }
                    && grid.indexPathsForVisibleItems.contains { $0.section == 1 && $0.item >= 60 }
            }
            attachHeroScrollState(grid, controller: controller, name: "Long hero outside the viewport")
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(50))
                grid.layoutIfNeeded()
                XCTAssertEqual(try XCTUnwrap(grid.layoutAttributesForItem(at: heroPath)).frame.height, height, accuracy: 1,
                    "Recycled zero geometry must not collapse the measured accessibility hero")
                XCTAssertEqual(try XCTUnwrap(grid.layoutAttributesForItem(at: firstPhotoPath)).frame.minY, firstRowY, accuracy: 1,
                    "Culling the hero must not shift every photo row")
                XCTAssertEqual(grid.contentSize.height, contentHeight, accuracy: 1)
                XCTAssertEqual(grid.contentOffset.y, bottom, accuracy: 1,
                    "The grid must not jump while the offscreen hero is recycled")
                XCTAssertEqual(controller.titleDockContentY, dockingThreshold, accuracy: 1,
                    "Recycling must retain the measured title docking threshold")
            }
            let dockedText = try await renderedPrincipalTitle(in: bar, window: window)
            XCTAssertTrue(dockedText.contains("Our"),
                "The actual toolbar must keep the long collection title docked above the final photo rows: \(dockedText)")
            let visiblePhotoFrame = try XCTUnwrap(grid.indexPathsForVisibleItems.filter { $0.section == 1 }
                .compactMap { path -> CGRect? in
                    guard let attributes = grid.layoutAttributesForItem(at: path) else { return nil }
                    let frame = grid.convert(attributes.frame, to: window).intersection(window.bounds)
                    return frame.width > 20 && frame.height > 20 ? frame : nil
                }.max { $0.width * $0.height < $1.width * $1.height })
            let bottomSnapshot = try await screenshot(window)
            try assertGreenPhoto(in: bottomSnapshot, frame: visiblePhotoFrame)

            grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
            try await waitUntil("Returning to the top remounts the full long hero and its count") {
                grid.indexPathsForVisibleItems.contains(heroPath)
                    && grid.visibleCells.contains { $0 is PhotoGridHostCell }
                    && self.accessibilityObject(title, in: window) != nil
                    && self.accessibilityObject("64 items", in: window) != nil
            }
            let returnedBarText = try await renderedPrincipalTitle(in: bar, window: window)
            attachHeroScrollState(grid, controller: controller, name: "Long hero returned to the viewport")
            XCTAssertEqual(returnedBarText.contains("Our"), initialBarText.contains("Our"),
                "Returning to the same long caption must restore its original toolbar docking state")
            let hero = try XCTUnwrap(grid.layoutAttributesForItem(at: heroPath))
            XCTAssertEqual(hero.frame.height, height, accuracy: 1)
            let heroFrame = grid.convert(hero.frame, to: window)
            let titleFrame = window.convert(try XCTUnwrap(accessibilityObject(title, in: window)).accessibilityFrame, from: nil)
            let countFrame = window.convert(try XCTUnwrap(accessibilityObject("64 items", in: window)).accessibilityFrame, from: nil)
            XCTAssertTrue(heroFrame.insetBy(dx: -1, dy: -1).contains(titleFrame))
            XCTAssertTrue(heroFrame.insetBy(dx: -1, dy: -1).contains(countFrame))
            XCTAssertGreaterThanOrEqual(countFrame.minY, titleFrame.maxY)
            XCTAssertGreaterThanOrEqual(grid.convert(try XCTUnwrap(grid.layoutAttributesForItem(at: firstPhotoPath)).frame,
                to: window).minY, countFrame.maxY)
            grid.scrollRectToVisible(grid.convert(countFrame, from: window).insetBy(dx: 0, dy: -8), animated: false)
            let returnedSnapshot = try await screenshot(window)
            let returnedText = try renderedStrings(returnedSnapshot).joined(separator: " ")
            XCTAssertTrue(returnedText.contains("64 items"),
                "The remounted caption must render its full count when scrolled into view: \(returnedText)")
            window.isHidden = true
        }
    }

    private func renderedPrincipalTitle(in bar: UINavigationBar, window: UIWindow) async throws -> String {
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let titleView = try XCTUnwrap(bar.topItem?.titleView,
            "The principal toolbar title must be mounted in the actual navigation item")
        XCTAssertTrue(titleView.window === window)
        XCTAssertFalse(titleView.bounds.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: titleView.bounds).image { context in
            titleView.traitCollection.performAsCurrent {
                UIColor.systemBackground.setFill()
                context.fill(titleView.bounds)
                titleView.drawHierarchy(in: titleView.bounds, afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Actual principal title without the hero behind it"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try renderedStrings(image).joined(separator: " ")
    }

    private func attachHeroScrollState(_ grid: UICollectionView, controller: PhotoGridController, name: String) {
        let heroPath = IndexPath(item: 0, section: 0)
        let frame = grid.layoutAttributesForItem(at: heroPath)?.frame ?? .zero
        let paths = grid.indexPathsForVisibleItems.sorted {
            $0.section == $1.section ? $0.item < $1.item : $0.section < $1.section
        }
        let text = "bounds=\(grid.bounds) content=\(grid.contentSize) offset=\(grid.contentOffset) "
            + "insets=\(grid.adjustedContentInset) hero=\(frame) docking=\(controller.titleDockContentY) "
            + "retainedPreparedHero=\(grid.cellForItem(at: heroPath) != nil) visiblePaths=\(paths) "
            + "visibleHostCount=\(grid.visibleCells.filter { $0 is PhotoGridHostCell }.count)"
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func collection(title: String, photos: [AssetLite]) -> some View {
        NavigationStack {
            PhotoCollectionScreen(title: LocalizedStringKey(title), heroAssetID: photos[0].id,
                assets: photos, phase: .loaded(()), onRetry: {}, onDelete: { _ in
                    XCTFail("Inspecting a collection cannot delete photos")
                }, shareURLs: { _ in [] })
        }
    }

    private func cachedPhotos(count: Int = 12) -> [AssetLite] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        return (0..<count).map { _ in
            let photo = AssetLite(makeTestAsset(id: UUID().uuidString))
            for (name, pixels) in [("thumbnail", 600), ("preview", 1400)] {
                let key = ImageCache.memoryKey("\(photo.id)-\(name)", pixels)
                cacheKeys.append(key)
                ImageMemoryCache.shared.insert(image, for: key)
            }
            return photo
        }
    }

    private func actualGrid(in window: UIWindow, photoCount: Int) async throws -> UICollectionView {
        var result: UICollectionView?
        try await waitUntil("The actual collection contains its hero and all loaded photos") {
            result = self.descendants(window).compactMap { $0 as? UICollectionView }.first
            return result?.numberOfSections == 2 && result?.numberOfItems(inSection: 1) == photoCount
        }
        let grid = try XCTUnwrap(result)
        grid.layoutIfNeeded()
        return grid
    }

    private func assertGreenPhoto(in image: UIImage, frame: CGRect) throws {
        XCTAssertGreaterThan(frame.width, 20)
        XCTAssertGreaterThan(frame.height, 20)
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: frame.applying(
            CGAffineTransform(scaleX: image.scale, y: image.scale))))
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var green = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let channel = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if channel > 80, channel - red > 20, channel - blue > 20 { green += 1 }
        }
        XCTAssertGreaterThan(green, side * side / 2,
            "Most of the visible photo must contain the synthetic image, including beneath caption scrims")
    }
}
