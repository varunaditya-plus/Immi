import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoCameraHeaderLayoutTests: ViewerAdaptiveLayoutTestCase {
    func testCameraHeaderHasItsOwnSemanticFillAndKeepsTheFormatAndMetadataInBothAppearances() async throws {
        let exif = ExifDTO(make: "Canon", model: "EOS R5", exifImageWidth: 6000, exifImageHeight: 4000,
            orientation: nil, fileSizeInByte: nil, dateTimeOriginal: nil, latitude: nil, longitude: nil,
            city: nil, state: nil, country: nil, lensModel: "Portrait lens", fNumber: 1.2,
            focalLength: 85, iso: 25600, exposureTime: "1/8000", description: nil)
        let detail = AssetResponseDTO(id: UUID().uuidString, type: "IMAGE", originalFileName: "camera.jpeg",
            fileCreatedAt: Date(timeIntervalSince1970: 1_600_000_000), isFavorite: false,
            isArchived: false, isTrashed: false, duration: nil, thumbhash: nil,
            localDateTime: Date(timeIntervalSince1970: 1_600_000_000), exifInfo: exif, people: nil)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(CameraHeaderProbe(detail: detail), style: style)
            resize(window, to: CGSize(width: 320, height: 650))
            try await waitUntil("The real camera card renders") {
                self.accessibilityObject("Canon EOS R5", in: window) != nil
            }
            let camera = try XCTUnwrap(accessibilityObject("Canon EOS R5", in: window))
            let lens = try XCTUnwrap(accessibilityObject("Portrait lens — 85 mm ƒ1.2", in: window))
            try scrollVertically(to: lens, in: window)
            let snapshot = try await screenshot(window)
            let headerFrame = window.convert(camera.accessibilityFrame, from: nil)
            let lensFrame = window.convert(lens.accessibilityFrame, from: nil)
            let headerFill = try luminance(snapshot, at: CGPoint(x: 22, y: headerFrame.midY), in: window)
            let bodyFill = try luminance(snapshot, at: CGPoint(x: 22, y: lensFrame.midY), in: window)
            XCTAssertGreaterThan(abs(headerFill - bodyFill), 0.025,
                "The camera-name and format header must remain distinct from the metadata body")
            XCTAssertNotNil(accessibilityObject("JPEG", in: window), "The actual file format must remain available")
            let strings = try renderedStrings(snapshot).map { $0.replacingOccurrences(of: " ", with: "") }
            for value in ["CanonEOSR5", "JPEG", "Portraitlens", "6000", "4000", "25600", "1/8000"] {
                XCTAssertTrue(strings.contains { $0.contains(value) }, "Camera metadata must remain readable: \(value)")
            }
        }
    }

    private func luminance(_ image: UIImage, at point: CGPoint, in window: UIWindow) throws -> Double {
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / window.bounds.width
        let sample = try XCTUnwrap(source.cropping(to: CGRect(x: point.x * scale,
            y: point.y * scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(bytes[0]) + Double(bytes[1]) + Double(bytes[2])) / (255 * 3)
    }
}

private struct CameraHeaderProbe: View {
    let detail: AssetResponseDTO
    @State private var description = ""
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        AssetInfoPanel(detail: detail, descriptionDraft: $description, descriptionFocus: $descriptionFocused)
    }
}
