import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCropContrastTests: SimulatorHostedTestCase {
    func testUnselectedCropRatiosRemainReadableInLightAndDarkApps() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
                UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            let window = try await host(PhotoCropEditor(initialRecipe: PhotoEditRecipe(), loadImage: { image },
                isAllowed: { true }, onSave: { _ in true }, onRevert: { true }), style: style)
            try await activateAccessibilityButton(named: "Crop", in: window)
            try await activateAccessibilityButton(named: "Aspect Ratio", in: window)
            try assertTextContrast("FREEFORM", image: await screenshot(window))
            try assertTextContrast("SQUARE", image: await screenshot(window))
        }
    }
}
