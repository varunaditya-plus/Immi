import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditorLayoutTests: SimulatorHostedTestCase {
    func testChangingToolsAndOpeningRatiosKeepsTheRenderedPhotoInPlace() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let window = try await host(PhotoCropEditor(initialRecipe: PhotoEditRecipe(), loadImage: { image },
            isAllowed: { true }, onSave: { _ in true }, onRevert: { true }))
        try await activateAccessibilityButton(named: "Exposure", in: window)
        let initial = try photoFrame(in: await screenshot(window))
        XCTAssertGreaterThan(initial.width, window.bounds.width / 2)
        for tool in ["Filters", "Crop", "Aspect Ratio"] {
            try await activateAccessibilityButton(named: tool, in: window)
            let frame = try photoFrame(in: await screenshot(window))
            XCTAssertEqual(frame.minX, initial.minX, accuracy: 1, "\(tool) must not shift the photo horizontally")
            XCTAssertEqual(frame.minY, initial.minY, accuracy: 1, "\(tool) must not shift the photo vertically")
            XCTAssertEqual(frame.midX, initial.midX, accuracy: 0.5, "\(tool) must keep the photo centered")
            XCTAssertEqual(frame.midY, initial.midY, accuracy: 0.5, "\(tool) must keep the photo centered")
            // The crop outline covers the image's outer pixel rows without resizing its stage.
            XCTAssertEqual(frame.width, initial.width, accuracy: 2, "\(tool) must not resize the photo")
            XCTAssertEqual(frame.height, initial.height, accuracy: 2, "\(tool) must not resize the photo")
        }
    }

    func testEveryEditingSymbolExistsInTheCurrentRuntime() {
        for adjustment in PhotoAdjustment.allCases {
            XCTAssertNotNil(UIImage(systemName: adjustment.symbol), adjustment.title)
        }
        for tool in PhotoEditorTool.allCases {
            XCTAssertNotNil(UIImage(systemName: tool.symbol), tool.title)
        }
    }

    private func photoFrame(in image: UIImage) throws -> CGRect {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rows: [(left: Int, right: Int)?] = []
        for y in 0..<height {
            var left = width, right = -1, count = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset + 1] > 220, pixels[offset] < 30, pixels[offset + 2] < 30 {
                    left = min(left, x); right = max(right, x); count += 1
                }
            }
            rows.append(count > width / 2 ? (left, right) : nil)
        }
        var longest = 0..<0, start = 0
        for y in 0...height {
            if y < height, rows[y] != nil { continue }
            if y - start > longest.count { longest = start..<y }
            start = y + 1
        }
        XCTAssertGreaterThan(longest.count, 30, "A real rendered photo must be present; small filter thumbnails do not qualify")
        let selected = longest.compactMap { rows[$0] }
        let left = try XCTUnwrap(selected.map(\.left).min())
        let right = try XCTUnwrap(selected.map(\.right).max())
        return CGRect(x: CGFloat(left) / image.scale, y: CGFloat(longest.lowerBound) / image.scale,
            width: CGFloat(right - left + 1) / image.scale, height: CGFloat(longest.count) / image.scale)
    }
}
