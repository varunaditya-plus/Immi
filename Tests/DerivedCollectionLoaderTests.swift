import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class DerivedCollectionLoaderTests: SimulatorHostedTestCase {
    func testCanceledMetadataSourceRetriesOnceAndPublishesTheNewCurrentResult() async throws {
        let photo = asset()
        var calls = 0
        let window = try await host(NavigationStack {
            DerivedCollectionView(title: "Map", assets: { [] }, assetLoader: {
                calls += 1
                if calls == 1 { throw CancellationError() }
                return [photo]
            }, layout: .monthly)
        })

        try await waitUntil("The current collection recovers from an invalidated metadata request") {
            self.count(in: window) == 1
        }
        XCTAssertEqual(calls, 2)
    }

    func testRepeatedSourceCancellationSettlesIntoARecoverableErrorAndActualRetryWorks() async throws {
        let photo = asset()
        var calls = 0
        var available = false
        let window = try await host(NavigationStack {
            DerivedCollectionView(title: "Map", assets: { [] }, assetLoader: {
                calls += 1
                if !available { throw CancellationError() }
                return [photo]
            }, layout: .monthly)
        })
        try await waitUntil("The bounded retry completes instead of spinning or repeatedly fetching") { calls == 2 }
        available = true

        try await activateAccessibilityButton(named: "Retry", in: window)

        try await waitUntil("The actual error action restores the collection") { self.count(in: window) == 1 }
        XCTAssertEqual(calls, 3)
    }

    private func asset() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: Date(timeIntervalSince1970: 1_793_188_800))
    }
    private func count(in view: UIView) -> Int {
        if let grid = view as? UICollectionView {
            return (0..<grid.numberOfSections).reduce(0) { $0 + grid.numberOfItems(inSection: $1) }
        }
        return view.subviews.map { count(in: $0) }.max() ?? 0
    }
}
