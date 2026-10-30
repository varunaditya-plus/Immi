import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class DerivedCollectionPresentationTests: SimulatorHostedTestCase {
    func testFailedDayRefreshKeepsCachedPhotosAndOffersAWorkingVisibleRetry() async throws {
        let cached = photo()
        let remote = photo()
        let driver = DerivedDayLoadDriver(result: [cached, remote])
        let view = DerivedCollectionView(title: "Recent Days", assets: { [cached] },
            dateInterval: DateInterval(start: .distantPast, end: .distantFuture), dayLoader: { _ in try await driver.load() })
        let window = try await host(view)
        await fulfillment(of: [driver.started], timeout: 3)
        addTeardownBlock { await driver.finish(.failure(CancellationError())) }
        try await waitUntil("The cached photo stays in the real collection during the held refresh") {
            self.photoCellCount(in: window) > 0
        }
        driver.finish(.failure(APIError.server(status: 503, message: "Date sync unavailable")))
        var text = try await recognizedText(in: window)
        XCTAssertTrue(text.contains("Date sync unavailable"), text)
        XCTAssertTrue(text.contains("Retry"), text)
        XCTAssertGreaterThan(photoCellCount(in: window), 0)

        try await activateAccessibilityButton(named: "Retry", in: window)
        try await waitUntil("Retry requests the full day again") { driver.calls == 2 }
        text = try await recognizedText(in: window)
        XCTAssertFalse(text.contains("Date sync unavailable"), text)
        XCTAssertFalse(text.contains("Retry"), text)
        XCTAssertGreaterThanOrEqual(photoCellCount(in: window), 2)
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1.5, thumbhash: nil, createdAt: Date(timeIntervalSince1970: 10))
    }

    private func photoCellCount(in view: UIView) -> Int {
        (view is PhotoGridCell ? 1 : 0) + view.subviews.reduce(0) { $0 + photoCellCount(in: $1) }
    }

    private func recognizedText(in window: UIWindow) async throws -> String {
        let image = try await screenshot(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

@MainActor
private final class DerivedDayLoadDriver {
    let started = XCTestExpectation(description: "Full day request started")
    private(set) var calls = 0
    private let result: [AssetLite]
    private var continuation: CheckedContinuation<[AssetLite], Error>?

    init(result: [AssetLite]) { self.result = result }

    func load() async throws -> [AssetLite] {
        calls += 1
        if calls > 1 { return result }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ result: Result<[AssetLite], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
