import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsEmptyCardTests: SimulatorHostedTestCase {
    func testEmptyCardKeepsItsTitleAndExplanationAtSmallWidthsAndLargestTextInBothAppearances() async throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            var heights: [CGFloat] = []
            for size: DynamicTypeSize in [.large, .accessibility5] {
                let geometry = EmptyCardGeometry()
                let window = try await host(CollectionEmptyCard(state: state)
                    .environment(\.dynamicTypeSize, size)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { geometry.height = $0 }
                    .padding(20), style: style)
                window.frame.size = CGSize(width: 320, height: 1400)
                window.rootViewController?.view.frame = window.bounds
                try await waitUntil("The intrinsic empty card has been measured") { geometry.height > 0 }
                let image = try await screenshot(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains("No Memories Available"), text)
                XCTAssertTrue(text.contains("Memories will appear here"), text)
                XCTAssertTrue(text.contains("added to the library"), "The explanation must remain complete at the card's bottom: \(text)")
                heights.append(geometry.height)
            }
            XCTAssertGreaterThanOrEqual(heights[0], 156)
            XCTAssertGreaterThan(heights[1], heights[0] + 100,
                "Accessibility text must grow the card intrinsically instead of clipping inside the default height")
        }
        for symbol in ["memories", "rectangle.stack.fill", "person.fill", "person.2.fill", "photo.fill", "calendar"] {
            XCTAssertNotNil(UIImage(systemName: symbol), "The empty card must use a real SF Symbol: \(symbol)")
        }
    }

    func testEmptyCardCanCollapseAndExpandThroughTheRealSectionControl() async throws {
        let expansion = EmptyCardExpansion()
        let window = try await host(NavigationStack {
            CollectionSection(title: "Memories",
                isExpanded: Binding(get: { expansion.expanded }, set: { expansion.expanded = $0 }),
                isEmpty: true, contentHeight: 120, emptyState: state,
                destination: { Text("Memory directory") }, content: { EmptyView() })
        })
        try await activateAccessibilityButton(named: "Collapse Memories", in: window)
        XCTAssertFalse(expansion.expanded)
        try await activateAccessibilityButton(named: "Expand Memories", in: window)
        XCTAssertTrue(expansion.expanded)
    }

    private var state: CollectionSectionEmptyState {
        .init(title: "No Memories Available", systemImage: "memories",
            description: "Memories will appear here when more photos and videos are added to the library.")
    }
}

@MainActor
@Observable
private final class EmptyCardGeometry {
    var height: CGFloat = 0
}

@MainActor
@Observable
private final class EmptyCardExpansion {
    var expanded = true
}
