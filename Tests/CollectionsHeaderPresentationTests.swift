import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class CollectionsHeaderPresentationTests: SimulatorHostedTestCase {
    func testCollectionsHeaderIsCompleteAtPhoneWidth() async throws {
        try await assertHeader(width: 390, size: .large)
    }

    func testCollectionsHeaderIsCompleteAtLargestAccessibilitySize() async throws {
        try await assertHeader(width: 390, size: .accessibility5)
    }

    func testCollectionsHeaderFitsCompactPhoneAtLargestAccessibilitySize() async throws {
        try await assertHeader(width: 320, size: .accessibility5)
    }

    private func assertHeader(width: CGFloat, size: DynamicTypeSize) async throws {
        let api = APIClient(session: MockSessionManager())
        let model = LibraryViewModel(memoriesRepo: MemoriesRepository(api: api), albumRepo: AlbumRepository(api: api),
            peopleRepo: PeopleRepository(api: api), searchRepo: SearchRepository(api: api),
            assetRepo: AssetDetailRepository(api: api), localPhotos: { [] })
        let window = try await host(LibraryView(isActive: false, viewModel: model)
            .environment(\.dynamicTypeSize, size))
        window.frame.size.width = width
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        let image = try await screenshot(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        // Keep full-image coordinates when measuring point spacing; a cropped ROI changes Vision’s normalization.
        let headerObservations = (request.results ?? []).filter { $0.boundingBox.midY >= 0.75 }
        let headerText = headerObservations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")

        XCTAssertTrue(headerText.contains("Collections"), "The top header must show its full title, independently of tab labels: \(headerText)")
        XCTAssertFalse(headerText.contains("C…"), headerText)
        if width == 390, size == .large {
            let title = try XCTUnwrap(headerObservations.first { $0.topCandidates(1).first?.string == "Collections" },
                "The actual top title must be fully rendered: \(headerText)")
            let edgeMarks = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            let memories = try XCTUnwrap(headerObservations.first {
                $0.topCandidates(1).first?.string.trimmingCharacters(in: edgeMarks) == "Memories"
            }, "The actual Memories heading must be visible below the title: \(headerText)")
            let titleTop = (1 - title.boundingBox.maxY) * window.bounds.height
            let memoriesTop = (1 - memories.boundingBox.maxY) * window.bounds.height
            XCTAssertGreaterThan(memoriesTop, titleTop)
            XCTAssertLessThanOrEqual(memoriesTop - titleTop, 70,
                "An invisible large-title area must not add an extra blank row below the Collections toolbar")
        }
    }
}
