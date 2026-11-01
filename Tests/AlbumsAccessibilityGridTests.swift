import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumsAccessibilityGridTests: ViewerAdaptiveLayoutTestCase {
    private var previousAlbums: [AlbumResponseDTO]?
    private var preferences: [String: Any] = [:]
    private var cacheKeys: [String] = []
    private var suites: [String] = []
    private let preferenceKeys = ["albumsLayout", "albumsSort", "albumsCustomOrder"]

    override func setUp() {
        previousAlbums = LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList)
        for key in preferenceKeys { preferences[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set("grid", forKey: "albumsLayout")
        UserDefaults.standard.set(true, forKey: "albumsCustomOrder")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let previousAlbums { LocalSnapshot.save(previousAlbums, for: LocalSnapshot.Key.albumsList) }
        else { LocalSnapshot.remove(LocalSnapshot.Key.albumsList) }
        for key in preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        cacheKeys.removeAll()
        suites.removeAll()
    }

    func testAccessibilityGridUsesWideLoadedCardsAndKeepsOrdinaryNamesCompleteInBothAppearances() async throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844),
                     CGSize(width: 900, height: 420)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let (window, albums) = try await fixture(size: size, textSize: .accessibility5, style: style)
                let first = try XCTUnwrap(accessibilityObject(albums[0].albumName, in: window))
                let second = try XCTUnwrap(accessibilityObject(albums[1].albumName, in: window))
                let firstFrame = window.convert(first.accessibilityFrame, from: nil)
                let secondFrame = window.convert(second.accessibilityFrame, from: nil)
                XCTAssertEqual(firstFrame.width, firstFrame.height, accuracy: 1)
                XCTAssertGreaterThan(firstFrame.width, 280,
                    "Large captions require wider cards, without reducing the preferred font size")
                if size.width < 400 {
                    XCTAssertGreaterThan(secondFrame.minY, firstFrame.maxY,
                        "Compact accessibility layouts must use one readable column")
                } else {
                    XCTAssertEqual(firstFrame.minY, secondFrame.minY, accuracy: 1)
                    XCTAssertGreaterThan(secondFrame.minX, firstFrame.maxX,
                        "A wide accessibility layout should retain two cards per row")
                }
                for album in albums {
                    try await assertLoadedCaption(album.albumName, in: window, expectsAccessibilityText: true)
                }
                window.isHidden = true
            }
        }
    }

    func testOrdinaryTextKeepsTheExistingCompactAndWideColumnCountsInBothAppearances() async throws {
        for width: CGFloat in [320, 390, 900] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let (window, albums) = try await fixture(size: CGSize(width: width, height: 844), textSize: .large, style: style)
                let frames = try albums.map { album in
                    window.convert(try XCTUnwrap(accessibilityObject(album.albumName, in: window)).accessibilityFrame, from: nil)
                }
                let rowCount = frames.filter { abs($0.minY - frames[0].minY) < 1 }.count
                XCTAssertEqual(rowCount, width < 400 ? 2 : 4,
                    "The accessibility adaptation must preserve the normal grid's density")
                try await assertLoadedCaption(albums[0].albumName, in: window, expectsAccessibilityText: false)
                window.isHidden = true
            }
        }
    }

    private func fixture(size: CGSize, textSize: DynamicTypeSize, style: UIUserInterfaceStyle) async throws -> (UIWindow, [AlbumResponseDTO]) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let albums = ["Barcelona", "Every Season", "Summer", "Holidays"].map { name in
            let photoID = UUID().uuidString
            let key = ImageCache.memoryKey("\(photoID)-thumbnail", 600)
            cacheKeys.append(key)
            ImageMemoryCache.shared.insert(image, for: key)
            return AlbumResponseDTO(id: UUID().uuidString, albumName: name, description: nil,
                assetCount: 12, albumThumbnailAssetId: photoID, shared: false, createdAt: .distantPast, assets: nil)
        }
        let repository = AccessibilityGridAlbumRepository(api: makeStubAPIClient())
        repository.albums = albums
        let model = AlbumListViewModel(repo: repository)
        let suite = "albums-grid-accessibility-\(UUID())"
        suites.append(suite)
        let organization = AlbumsOrganizationStore(owner: BackupQueueOwner(server: "https://layout.example/api", userID: "synthetic"),
            defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        organization.setContainerOrder(albums.map { AlbumOrganization.albumEntry($0.id) }, in: nil)
        let window = try await host(NavigationStack {
            AlbumsListView(viewModel: model, organizationStore: organization)
        }.dynamicTypeSize(textSize), style: style)
        resize(window, to: size)
        try await waitUntil("The actual album browser loads and lays out its warm photo cards") {
            guard model.hasLoadedAlbums, let card = self.accessibilityObject(albums[0].albumName, in: window) else { return false }
            let frame = window.convert(card.accessibilityFrame, from: nil)
            return frame.width > 0 && frame.maxX <= size.width
        }
        return (window, albums)
    }

    private func assertLoadedCaption(_ caption: String, in window: UIWindow, expectsAccessibilityText: Bool) async throws {
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > window.bounds.width * 0.7
        })
        var object = accessibilityObject(caption, in: window)
        for _ in 0..<24 where object == nil {
            let maximumOffset = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let nextOffset = min(maximumOffset, scroll.contentOffset.y + max(1, scroll.bounds.height * 0.6))
            guard nextOffset > scroll.contentOffset.y + 0.5 else { break }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: nextOffset), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            object = accessibilityObject(caption, in: window)
        }
        var card = try XCTUnwrap(object,
            "The actual lazy album grid must reveal \(caption) by scrolling its mounted viewport")
        for _ in 0..<2 {
            let frame = window.convert(card.accessibilityFrame, from: nil)
            let captionArea = CGRect(x: frame.minX, y: frame.maxY - min(170, frame.height),
                width: frame.width, height: min(170, frame.height))
            scroll.scrollRectToVisible(scroll.convert(captionArea, from: window), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            try await waitUntil("The revealed \(caption) card finishes its mounted layout") {
                self.accessibilityObject(caption, in: window) != nil
            }
            card = try XCTUnwrap(accessibilityObject(caption, in: window))
        }
        let image = try await screenshot(window)
        let frame = window.convert(card.accessibilityFrame, from: nil)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let observations = (request.results ?? []).filter {
            frame.contains(CGPoint(x: $0.boundingBox.midX * window.bounds.width,
                y: (1 - $0.boundingBox.midY) * window.bounds.height))
        }
        let text = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.filter { !$0.isWhitespace }.contains(caption.filter { !$0.isWhitespace }),
            "The actual caption must render completely without internal hyphenation or truncation: \(caption); OCR=\(text)")
        if expectsAccessibilityText {
            XCTAssertGreaterThan((observations.map { $0.boundingBox.height }.max() ?? 0) * window.bounds.height, 28,
                "Wider cards must preserve the actual accessibility caption font size")
        }
        let visible = frame.intersection(window.bounds)
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: visible.minX * image.scale,
            y: visible.minY * image.scale, width: visible.width * image.scale, height: visible.height * image.scale)))
        var bytes = [UInt8](repeating: 0, count: 40 * 40 * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 40, height: 40, bitsPerComponent: 8,
                bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let greenPixels = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0 + 1] > 180 && bytes[$0] < 80 && bytes[$0 + 2] < 80
        }.count
        XCTAssertGreaterThan(greenPixels, 100,
            "Caption layout must be checked over the actual loaded cover rather than its placeholder")
    }
}

private final class AccessibilityGridAlbumRepository: AlbumRepository {
    var albums: [AlbumResponseDTO] = []
    override func all() async throws -> [AlbumResponseDTO] { albums }
}
