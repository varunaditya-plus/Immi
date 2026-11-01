import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapPinAccessibilityTests: ViewerAdaptiveLayoutTestCase {
    func testLargestTextKeepsActualMapCountsCompleteAndPinsTappableInBothAppearances() async throws {
        for count in [49, 10_000] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let markers = (0..<count).map { MapMarkerDTO(id: "synthetic-\($0)", lat: 0, lon: 0, city: "Synthetic Place", state: nil, country: nil) }
                let cluster = try XCTUnwrap(PhotoMapClustering.clusters(in: markers,
                    bounds: PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1),
                    viewportWidth: 320, viewportHeight: 568).first)
                var opened = 0
                let window = try await host(PhotoMapPin(cluster: cluster) { opened += 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground)).dynamicTypeSize(.accessibility5), style: style)
                let image = try await screenshot(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.005
                let pinFrame = try XCTUnwrap(accessibilityObject("Synthetic Place", in: window)).accessibilityFrame
                let region = window.convert(pinFrame, from: nil).insetBy(dx: -12, dy: -12)
                    .intersection(window.bounds).applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: region))
                try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.filter(\.isNumber).contains(String(count)), "The actual \(count) count must render instead of an ellipsis: \(text)")
                try await activateAccessibilityButton(named: "Synthetic Place", in: window)
                XCTAssertEqual(opened, 1)
                window.isHidden = true
            }
        }
    }

}
