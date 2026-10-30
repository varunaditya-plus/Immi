import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCropContrastTests: SimulatorHostedTestCase {
    func testUnselectedCropRatiosRemainReadableInLightAndDarkApps() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(PhotoCropEditor(assetID: UUID().uuidString,
                originalPixelSize: CGSize(width: 600, height: 400), existingEdits: [], onSave: { _ in true }),
                style: style)
            try assertTextContrast("FREEFORM", image: await screenshot(window))
            try assertTextContrast("SQUARE", image: await screenshot(window))
        }
    }
}
