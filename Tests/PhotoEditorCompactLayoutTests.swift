import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditorCompactLayoutTests: ViewerAdaptiveLayoutTestCase {
    func testShortLandscapePhotoEditorKeepsItsPreviewAndAdjustmentReachableAtAccessibilitySize() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            var saves: [PhotoEditRecipe] = []
            let window = try await host(PhotoCropEditor(initialRecipe: .init(), loadImage: { image },
                isAllowed: { true }, onSave: { saves.append($0); return true }, onRevert: { true })
                .dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 568, height: 320))
            var preview: NSObject?
            try await waitUntil("The photo editor exposes its actual preview") {
                preview = self.accessibilityObject("Edited Photo", in: window)
                return preview != nil
            }
            let photo = try XCTUnwrap(preview)
            let frame = window.convert(photo.accessibilityFrame, from: nil)
            XCTAssertGreaterThanOrEqual(frame.intersection(window.bounds).height, 80,
                "Large controls cannot collapse the photo preview in a short landscape window")
            try scrollVertically(to: try XCTUnwrap(accessibilityObject("Exposure", in: window)), in: window)
            try await activateAccessibilityButton(named: "Exposure", in: window)
            let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }
                .first { $0.accessibilityLabel == "Exposure" })
            try scrollVertically(to: slider, in: window)
            XCTAssertTrue(window.bounds.contains(slider.convert(slider.bounds, to: window)))
            slider.sendActions(for: .touchDown)
            slider.value = slider.maximumValue
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
            try await activateAccessibilityButton(named: "Done", in: window)
            try await waitUntil("The reachable adjustment saves through the actual editor") { saves.count == 1 }
            XCTAssertEqual(try XCTUnwrap(saves.first)[.exposure], 1, accuracy: 0.001)
        }
    }
}

