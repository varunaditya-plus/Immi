import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class MemoryProgressLayoutTests: SimulatorHostedTestCase {
    func testDenseMemoryProgressStaysInsideItsActualNarrowAndWideViewport() async throws {
        for (width, count) in [(CGFloat(240), 100), (CGFloat(700), 1_000)] {
            let window = try await host(ZStack {
                Color.black.ignoresSafeArea()
                MemoryStoryProgress(storyID: "dense", count: count, index: 0, isPaused: true, duration: 5, onFinish: {})
                    .frame(width: width)
            })
            window.frame = CGRect(x: 0, y: 0, width: width + 40, height: 200)
            window.rootViewController?.view.frame = window.bounds
            let image = try await screenshot(window)
            let bounds = try paintedBounds(in: image)

            XCTAssertGreaterThanOrEqual(bounds.minX, 27, "Every progress segment must stay inside the leading content inset")
            XCTAssertLessThanOrEqual(bounds.maxX, width + 13, "Even hundreds of gaps must fit the trailing content inset")
            XCTAssertGreaterThan(bounds.width, width - 20, "The progress track must remain visible across its available width")
            XCTAssertLessThanOrEqual(bounds.height, 4, "Dense memories keep the same three-point progress track")
            window.isHidden = true
        }
    }

    func testOrdinaryMemoryKeepsItsThreeSegmentsAndFourPointGaps() async throws {
        let window = try await host(ZStack {
            Color.black.ignoresSafeArea()
            MemoryStoryProgress(storyID: "ordinary", count: 3, index: 0, isPaused: true, duration: 5, onFinish: {})
                .frame(width: 240)
        })
        let image = try await screenshot(window)
        let painted = try paintedBounds(in: image)
        let runs = try horizontalRuns(in: image, y: painted.midY)
        XCTAssertEqual(runs.count, 3, "The rendered row must still show three distinct segments")
        for index in 1..<runs.count {
            XCTAssertEqual(runs[index].lowerBound - runs[index - 1].upperBound, 4, accuracy: 1)
        }
    }

    private func paintedBounds(in image: UIImage) throws -> CGRect {
        let (pixels, width, height) = try pixels(image)
        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 30 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertLessThan(left, right, "The real rendered progress row must contain visible segments")
        return CGRect(x: CGFloat(left) / image.scale, y: CGFloat(top) / image.scale,
            width: CGFloat(right - left + 1) / image.scale, height: CGFloat(bottom - top + 1) / image.scale)
    }

    private func horizontalRuns(in image: UIImage, y: CGFloat) throws -> [ClosedRange<CGFloat>] {
        let (pixels, width, _) = try pixels(image)
        let row = Int(y * image.scale)
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...width {
            let isPainted = x < width && pixels[(row * width + x) * 4] > 30
            if isPainted, start == nil { start = x }
            else if !isPainted, let first = start {
                runs.append((CGFloat(first) / image.scale)...(CGFloat(x - 1) / image.scale))
                start = nil
            }
        }
        return runs
    }

    private func pixels(_ image: UIImage) throws -> ([UInt8], Int, Int) {
        let source = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        return (pixels, source.width, source.height)
    }
}
