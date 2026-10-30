import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class LibraryHeaderLayoutTests: SimulatorHostedTestCase {
    func testLibraryHeaderKeepsTitleCountSortAndSelectReadableAtCompactAccessibilitySizes() async throws {
        for width: CGFloat in [320, 390] {
            var selected = false
            let window = try await host(NavigationStack {
                Color(.systemBackground)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            TimelineLibraryHeader(count: "290 Photos, 10 Videos", itemCount: 300)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu { Button("All Items") {} } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                            }
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .accessibilityLabel("Sort and Filter")
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Select") { selected = true }
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }
                    }
            }.dynamicTypeSize(.accessibility5))
            window.frame.size.width = width
            window.rootViewController?.view.frame = window.bounds
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            let cgImage = try XCTUnwrap(image.cgImage)
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let rows = request.results ?? []
            let library = try XCTUnwrap(rows.first { $0.topCandidates(1).first?.string == "Library" },
                "The full Library title must render at \(width)pt AX5")
            let select = try XCTUnwrap(rows.first { $0.topCandidates(1).first?.string == "Select" })
            let counts = rows.filter {
                let text = $0.topCandidates(1).first?.string ?? ""
                return text.contains("290") || text.contains("300")
            }
            XCTAssertFalse(counts.isEmpty, "A full or compact item count must remain rendered")
            XCTAssertLessThan(library.boundingBox.maxX, select.boundingBox.minX)
            XCTAssertTrue(counts.allSatisfy { $0.boundingBox.maxX < select.boundingBox.minX })
            try await activateAccessibilityButton(named: "Select", in: window)
            XCTAssertTrue(selected)
            try await activateAccessibilityButton(named: "Sort and Filter", in: window)
            if let presented = window.rootViewController?.presentedViewController {
                await withCheckedContinuation { continuation in
                    presented.dismiss(animated: false) { continuation.resume() }
                }
            }
        }
    }
}
