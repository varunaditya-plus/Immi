import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class SearchDiscoveryAccessibilityTests: ViewerAdaptiveLayoutTestCase {
    private var cacheKeys: [String] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        cacheKeys.removeAll()
        suites.removeAll()
    }

    func testLoadedDiscoveryNamesPlacesAndRecentsRemainCompleteAndTappableAtLargestText() async throws {
        for width in [CGFloat(320), 390] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let session = MockSessionManager()
                let names = ["Alexandra Catherine Johnson", "Leonardo Maximilian Chen"]
                let people = names.map { makePeopleStatePerson(UUID().uuidString, name: $0) }
                let cities = ["San Francisco Bay Area", "Reykjavík"]
                let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
                }
                for person in people {
                    cache(image, key: ImageCache.memoryKey("/people/\(person.id)/thumbnail", 600))
                }
                let detail = makeTestAsset(id: UUID().uuidString)
                cache(image, key: ImageCache.memoryKey(MediaEditingPipeline.shared.cacheKey("\(detail.id)-thumbnail",
                    assetID: detail.id, session: session), 600))
                let suite = "search-discovery-layout-\(UUID())"
                suites.append(suite)
                let store = RecentlyViewedStore(owner: BackupQueueOwner(server: "https://discovery.example/api", userID: "synthetic"),
                    defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
                store.record(detail)
                var suggestions: [String] = [], recentOpens = 0
                let window = try await host(SearchDiscoveryView(people: people, cities: cities, recentStore: store,
                    isLoading: false, error: nil, onSuggestion: { suggestions.append($0.title) },
                    onRecent: { recentOpens += 1 }, onRetry: {})
                    .dynamicTypeSize(.accessibility5).environment(session as SessionManager), style: style)
                resize(window, to: CGSize(width: width, height: 844))

                let recents = try await reveal("Recently Viewed", in: window)
                try await assertFullCaption("Recently Viewed", object: recents, in: window, imageOffset: 28)
                try await activateAccessibilityButton(named: "Recently Viewed", in: window)
                XCTAssertEqual(recentOpens, 1)
                for name in names {
                    let person = try await reveal(name, in: window, horizontal: true)
                    try await assertFullCaption(name, object: person, in: window, imageOffset: 40)
                    try await activateAccessibilityButton(named: name, in: window)
                }
                for city in cities {
                    let place = try await reveal(city, in: window)
                    try await assertFullCaption(city, object: place, in: window)
                    try await activateAccessibilityButton(named: city, in: window)
                }
                XCTAssertEqual(suggestions, names + cities)
                window.isHidden = true
            }
        }
    }

    private func cache(_ image: UIImage, key: String) {
        ImageMemoryCache.shared.insert(image, for: key)
        cacheKeys.append(key)
    }

    private func reveal(_ label: String, in window: UIWindow, horizontal: Bool = false) async throws -> NSObject {
        for _ in 0..<24 {
            if accessibilityObject(label, in: window) != nil { break }
            guard let scroll = descendants(window).compactMap({ $0 as? UIScrollView }).first(where: {
                $0.contentSize.height > $0.bounds.height + 1 && $0.bounds.width > window.bounds.width * 0.7
            }) else { break }
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            let next = min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.6)
            guard next > scroll.contentOffset.y + 1 else { break }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        try await waitUntil("The actual discovery button for \(label) is mounted") {
            self.accessibilityObject(label, in: window) != nil
        }
        var object = try XCTUnwrap(accessibilityObject(label, in: window))
        if horizontal, let scroll = descendants(window).compactMap({ $0 as? UIScrollView }).first(where: {
            $0.contentSize.width > $0.bounds.width + 1 && $0.bounds.width > window.bounds.width * 0.7
        }) {
            scroll.scrollRectToVisible(scroll.convert(window.convert(object.accessibilityFrame, from: nil), from: window), animated: false)
            window.layoutIfNeeded()
        }
        for _ in 0..<3 {
            object = accessibilityObject(label, in: window) ?? object
            if let scroll = descendants(window).compactMap({ $0 as? UIScrollView }).first(where: {
                $0.contentSize.height > $0.bounds.height + 1 && $0.bounds.width > window.bounds.width * 0.7
            }) {
                scroll.scrollRectToVisible(scroll.convert(window.convert(object.accessibilityFrame, from: nil), from: window)
                    .insetBy(dx: 0, dy: -8), animated: false)
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(accessibilityObject(label, in: window))
    }

    private func assertFullCaption(_ caption: String, object: NSObject, in window: UIWindow, imageOffset: CGFloat? = nil) async throws {
        let image = try await screenshot(window)
        let frame = window.convert(object.accessibilityFrame, from: nil)
        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(frame), "The complete button must be reachable: \(caption) \(frame)")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), orientation: .up).perform([request])
        let observations = (request.results ?? []).filter {
            frame.contains(CGPoint(x: $0.boundingBox.midX * window.bounds.width,
                y: (1 - $0.boundingBox.midY) * window.bounds.height))
        }.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(normalized(text).contains(normalized(caption)), "The actual caption must be complete, without ellipses: \(caption); OCR=\(text)")
        if let imageOffset {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: frame.midX * image.scale,
                y: (frame.minY + imageOffset) * image.scale, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertTrue(pixel[1] > 180 && pixel[0] < 80 && pixel[2] < 80,
                "The layout must be tested after the real AuthImage has loaded, not over a placeholder")
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
