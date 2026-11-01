import Observation
import SwiftUI
import UIKit
import Vision
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
            if tool == "Aspect Ratio" {
                try await activateSearchMenuAction(named: tool, in: window)
            } else {
                try await activateAccessibilityButton(named: tool, in: window)
            }
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

    func testLargeToolCaptionsRenderCompletelyWithoutTouchingAdjacentLabels() async throws {
        let window = try await host(PhotoEditorToolPicker(selected: .constant(.filters))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .dynamicTypeSize(.xxxLarge)
            .environment(\.locale, Locale(identifier: "en_US"))
            .preferredColorScheme(.light))
        let snapshot = try await screenshot(window)
        let frames = try captionFrames(["Adjust", "Filters", "Crop"], in: snapshot, window: window)
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(right.minX - left.maxX, 4,
                "Large tool captions must retain visible space between adjacent words")
        }
    }

    func testFourToolsRemainVisibleAndReachableByScrollingAtLargestAccessibilitySize() async throws {
        let fixture = PhotoToolPickerSelection()
        let window = try await host(PhotoEditorToolPicker(
            selected: Binding(get: { fixture.selected }, set: { fixture.selected = $0 }),
            primaryTitle: "Video", primarySymbol: "video.fill")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .dynamicTypeSize(.accessibility5)
            .environment(\.locale, Locale(identifier: "en_US"))
            .preferredColorScheme(.light))
        var scrolling: UIScrollView?
        try await waitUntil("Oversized tool captions use a real horizontal scrolling viewport") {
            scrolling = self.views(window).compactMap { $0 as? UIScrollView }
                .first { !$0.isHidden && $0.bounds.width > 0 && $0.contentSize.width > $0.bounds.width + 1 }
            return scrolling != nil
        }
        let scroll = try XCTUnwrap(scrolling)
        let viewport = scroll.convert(scroll.bounds, to: window)
        XCTAssertTrue(window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(viewport),
            "The scrolling tool viewport must stay inside the visible screen")
        XCTAssertGreaterThanOrEqual(viewport.height, 44)
        _ = try captionFrames(["Video", "Adjust"], in: await screenshot(window), window: window)
        try await activateAccessibilityButton(named: "Video", in: window)
        try await waitUntil("The visible Video button selects the primary tool") { fixture.selected == nil }
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The visible Adjust button changes the bound tool") { fixture.selected == .adjust }

        let end = max(-scroll.adjustedContentInset.left,
            scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        scroll.setContentOffset(CGPoint(x: end, y: scroll.contentOffset.y), animated: false)
        _ = try captionFrames(["Filters", "Crop"], in: await screenshot(window), window: window)
        XCTAssertGreaterThan(scroll.contentOffset.x, 0, "The real scroll control must reveal the trailing tools")
        try await activateAccessibilityButton(named: "Filters", in: window)
        try await waitUntil("The revealed Filters button changes the bound tool") { fixture.selected == .filters }
        try await activateAccessibilityButton(named: "Crop", in: window)
        try await waitUntil("The revealed Crop button is usable at the largest text size") { fixture.selected == .crop }
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func captionFrames(_ titles: [String], in snapshot: UIImage, window: UIWindow) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot.cgImage)).perform([request])
        var frames: [CGRect] = []
        for title in titles {
            var label: CGRect?
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first,
                      let range = text.string.range(of: title, options: .caseInsensitive),
                      let recognized = try text.boundingBox(for: range) else { continue }
                let box = recognized.boundingBox
                label = CGRect(x: box.minX * window.bounds.width, y: (1 - box.maxY) * window.bounds.height,
                    width: box.width * window.bounds.width, height: box.height * window.bounds.height)
                break
            }
            let frame = try XCTUnwrap(label, "The complete \(title) caption must remain readable")
            XCTAssertTrue(window.bounds.contains(frame), "The \(title) caption must fit inside the visible window")
            frames.append(frame)
        }
        return frames
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

@MainActor @Observable
private final class PhotoToolPickerSelection {
    var selected: PhotoEditorTool? = .adjust
}
