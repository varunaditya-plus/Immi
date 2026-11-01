import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoPanelAccessibilityTests: ViewerAdaptiveLayoutTestCase {
    func testExifValuesRemainCompleteAtAccessibilitySizeInNarrowLightAndDarkPanels() async throws {
        let exif = ExifDTO(make: "Canon", model: "EOS R5", exifImageWidth: 6000, exifImageHeight: 4000,
            orientation: nil, fileSizeInByte: nil, dateTimeOriginal: nil, latitude: nil, longitude: nil,
            city: nil, state: nil, country: nil, lensModel: "Portrait lens", fNumber: 1.2,
            focalLength: 85, iso: 25600, exposureTime: "1/8000", description: nil)
        let detail = makeTestAsset(id: UUID().uuidString, exifInfo: exif)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(InfoPanelLayoutProbe(detail: detail).dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 320, height: 650))
            try await waitUntil("The actual metadata panel exposes its EXIF values") {
                self.accessibilityObject("ISO 25600", in: window) != nil
            }
            let iso = try XCTUnwrap(accessibilityObject("ISO 25600", in: window))
            try scrollVertically(to: iso, in: window)
            let snapshot = try await screenshot(window)
            let strings = try renderedStrings(snapshot).map { $0.replacingOccurrences(of: " ", with: "") }
            for value in ["25600", "85", "1.2", "1/8000"] {
                XCTAssertTrue(strings.contains { $0.contains(value) },
                    "The complete EXIF value \(value) must be readable without splitting its digits: \(strings)")
            }
        }
    }
}

private struct InfoPanelLayoutProbe: View {
    let detail: AssetResponseDTO
    @State private var description = ""
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        AssetInfoPanel(detail: detail, descriptionDraft: $description, descriptionFocus: $descriptionFocused)
    }
}

