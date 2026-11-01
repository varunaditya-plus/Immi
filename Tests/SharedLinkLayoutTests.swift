import SwiftUI
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class SharedLinkLayoutTests: SimulatorHostedTestCase {
    func testAllPermissionsRemainReadableInNarrowRowsAndBothAppearances() async throws {
        let data = Data("""
        {"id":"test","key":"test","type":"INDIVIDUAL","description":"Trip",
         "allowDownload":true,"allowUpload":true,"showMetadata":true}
        """.utf8)
        let link = try JSONDecoder().decode(SharedLinkDTO.self, from: data)
        for size in [DynamicTypeSize.large, .accessibility5] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let window = try await host(SharedLinkRow(link: link)
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(.systemBackground)).dynamicTypeSize(size), style: style)
                window.frame.size = CGSize(width: 320, height: 650)
                window.rootViewController?.view.frame = window.bounds
                let image = try await screenshot(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                var frames: [CGRect] = []
                for title in ["Download", "EXIF", "Upload"] {
                    let word = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string == title
                    }, "The complete permission \(title) must be rendered at \(size) in \(style)")
                    let box = word.boundingBox
                    let frame = CGRect(x: box.minX * window.bounds.width,
                        y: (1 - box.maxY) * window.bounds.height,
                        width: box.width * window.bounds.width, height: box.height * window.bounds.height)
                    XCTAssertTrue(window.bounds.insetBy(dx: 8, dy: 0).contains(frame))
                    for previous in frames { XCTAssertFalse(frame.intersects(previous), "Permission captions must not overlap") }
                    frames.append(frame)
                }
            }
        }
    }
}
