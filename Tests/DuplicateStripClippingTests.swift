import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateStripClippingTests: SimulatorHostedTestCase {
    private var cacheKeys: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        cacheKeys.removeAll()
    }

    func testLoadedPhotosStayInsideTheNarrowGroupWhilePartiallyVisibleItemsStillScrollInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let photos = (0..<3).map { makeTestAsset(id: UUID().uuidString, originalFileName: "Choice \($0).jpg") }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                UIColor.magenta.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            }
            for photo in photos {
                let key = ImageCache.memoryKey("\(photo.id)-thumbnail", 600)
                cacheKeys.append(key)
                ImageMemoryCache.shared.insert(image, for: key)
            }
            let geometry = DuplicateStripGeometry()
            let window = try await host(DuplicateGroupCard(group: DuplicateGroupDTO(duplicateId: UUID().uuidString,
                assets: photos, suggestedKeepAssetIds: [photos[0].id]), isWorking: false,
                onResolve: { _ in XCTFail("Scrolling cannot resolve a group") },
                onKeepAll: { XCTFail("Scrolling cannot dismiss a group") })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.frame = $0 }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(.systemBackground)), style: style)
            window.frame.size = CGSize(width: 320, height: 568)
            window.rootViewController?.view.frame = window.bounds
            try await waitUntil("The actual narrow group card has its final width") {
                abs(geometry.frame.width - 288) < 1
            }
            let before = try magentaColumnRuns(in: await screenshot(window))
            try assertContained(before, in: geometry.frame)
            XCTAssertGreaterThan(before[0].upperBound - before[0].lowerBound, 120)
            XCTAssertGreaterThan(before[1].upperBound - before[1].lowerBound, 20)
            XCTAssertLessThan(before[1].upperBound - before[1].lowerBound,
                before[0].upperBound - before[0].lowerBound, "The next loaded item remains partially visible")
            let strip = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
                $0.isScrollEnabled && $0.contentSize.width > $0.bounds.width + 10
            })

            strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)

            let after = try magentaColumnRuns(in: await screenshot(window))
            try assertContained(after, in: geometry.frame)
            XCTAssertLessThan(after[0].upperBound - after[0].lowerBound,
                before[0].upperBound - before[0].lowerBound, "The real horizontal strip must scroll to its last photo")
        }
    }

    private func assertContained(_ runs: [ClosedRange<CGFloat>], in card: CGRect) throws {
        XCTAssertEqual(runs.count, 2, "Two loaded photos, including one partial item, must actually render")
        guard runs.count == 2 else { throw URLError(.cannotDecodeContentData) }
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.lowerBound, card.minX)
            XCTAssertLessThanOrEqual(run.upperBound, card.maxX,
                "Photo pixels cannot escape the enclosing rounded group card")
        }
    }

    private func magentaColumnRuns(in image: UIImage) throws -> [ClosedRange<CGFloat>] {
        let source = try XCTUnwrap(image.cgImage)
        let width = Int(image.size.width), height = Int(image.size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var columns = [Bool](repeating: false, count: width)
        for x in 0..<width {
            var count = 0
            for y in 0..<height {
                let offset = (y * width + x) * 4
                if pixels[offset] > 220, pixels[offset + 1] < 30, pixels[offset + 2] > 220 { count += 1 }
            }
            columns[x] = count > 20
        }
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...width {
            if x < width, columns[x] {
                if start == nil { start = x }
            } else if let first = start {
                runs.append(CGFloat(first)...CGFloat(x - 1))
                start = nil
            }
        }
        return runs
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor
@Observable
private final class DuplicateStripGeometry {
    var frame = CGRect.zero
}
