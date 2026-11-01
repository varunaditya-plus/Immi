import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCardCaptionLayoutTests: SimulatorHostedTestCase {
    private var cacheKeys: [String] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        cacheKeys.removeAll()
        suites.removeAll()
    }

    func testLoadedWideAndTallPhotosKeepMemoryAndRecentlyViewedCaptionsInsideTheirCards() async throws {
        for size in [CGSize(width: 1200, height: 80), CGSize(width: 80, height: 1200)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let detail = makeTestAsset(id: UUID().uuidString)
                let session = MockSessionManager()
                let image = UIGraphicsImageRenderer(size: size).image { context in
                    UIColor.green.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
                for (name, pixels) in [("thumbnail", 600), ("preview", 800)] {
                    let key = ImageCache.memoryKey(MediaEditingPipeline.shared.cacheKey("\(detail.id)-\(name)",
                        assetID: detail.id, session: session), pixels)
                    ImageMemoryCache.shared.insert(image, for: key)
                    cacheKeys.append(key)
                }
                let suite = "photo-card-caption-\(UUID())"
                suites.append(suite)
                let store = RecentlyViewedStore(owner: BackupQueueOwner(server: "https://caption.example/api", userID: "synthetic"),
                    defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
                store.record(detail)
                let story = MemoryStory(id: UUID().uuidString, title: "2 years ago", subtitle: "November 1, 2024", assets: [AssetLite(detail)])
                var memoryOpens = 0, recentOpens = 0
                let window = try await host(VStack(alignment: .leading, spacing: 24) {
                    MemoryCard(story: story, width: 180, height: 240) { memoryOpens += 1 }
                    SearchRecentsView(store: store) { recentOpens += 1 }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(session as SessionManager), style: style)
                var memoryObject: NSObject?, recentsObject: NSObject?
                try await waitUntil("The actual cached-image cards expose their rendered buttons") {
                    memoryObject = self.accessibilityButton(named: story.title, in: window)
                    recentsObject = self.accessibilityButton(named: "Recently Viewed", in: window)
                    return memoryObject != nil && recentsObject != nil
                }
                let memory = try XCTUnwrap(memoryObject)
                let recents = try XCTUnwrap(recentsObject)
                XCTAssertEqual(memory.accessibilityValue, story.subtitle)
                try await activateAccessibilityButton(named: story.title, in: window)
                try await activateAccessibilityButton(named: "Recently Viewed", in: window)
                XCTAssertEqual(memoryOpens, 1)
                XCTAssertEqual(recentOpens, 1)
                let snapshot = try await screenshot(window)
                let memoryFrame = window.convert(memory.accessibilityFrame, from: nil)
                let recentsFrame = window.convert(recents.accessibilityFrame, from: nil)
                XCTAssertEqual(memoryFrame.width, 180, accuracy: 1)
                XCTAssertEqual(memoryFrame.height, 240, accuracy: 1)
                XCTAssertEqual(recentsFrame.width, 112, accuracy: 1)
                XCTAssertEqual(recentsFrame.height, 112, accuracy: 1)
                try assertGreenPixel(in: snapshot, at: CGPoint(x: memoryFrame.midX, y: memoryFrame.minY + 60))
                try assertGreenPixel(in: snapshot, at: CGPoint(x: recentsFrame.midX, y: recentsFrame.minY + 28))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot.cgImage), orientation: .up).perform([request])
                for (caption, frame) in [("2 years ago", memoryFrame), ("November 1, 2024", memoryFrame),
                                         ("Recently", recentsFrame), ("Viewed", recentsFrame)] {
                    let observation = try XCTUnwrap(request.results?.first {
                        normalized($0.topCandidates(1).first?.string ?? "").contains(normalized(caption))
                    }, "The actual loaded \(size) photo must not hide \(caption) in \(style)")
                    let box = observation.boundingBox
                    let textFrame = CGRect(x: box.minX * window.bounds.width, y: (1 - box.maxY) * window.bounds.height,
                        width: box.width * window.bounds.width, height: box.height * window.bounds.height)
                    XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(textFrame),
                        "\(caption) must remain inside its card: text=\(textFrame), card=\(frame)")
                }
                window.isHidden = true
            }
        }
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func assertGreenPixel(in image: UIImage, at point: CGPoint) throws {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: point.x * image.scale,
            y: point.y * image.scale, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(pixel[1] > 180 && pixel[0] < 80 && pixel[2] < 80,
            "Caption geometry must be checked over the actual cached photo, not a placeholder")
    }

}
