import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoCollectionGridPresentationTests: SimulatorHostedTestCase {
    func testGlobalAspectPreferencePreservesSquareCellsAndHeadersAcrossMonthlySections() async throws {
        let defaults = UserDefaults.standard
        let key = "library.aspectRatioGrid"
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let assets = (0..<36).map { index in
            AssetLite(id: UUID().uuidString, isVideo: false,
                      ratio: index < 18 ? 0.5 : 2,
                      thumbhash: nil,
                      createdAt: Date(timeIntervalSince1970: index < 18 ? 1_767_225_600 : 1_769_904_000))
        }
        let window = try await host(NavigationStack {
            PhotoCollectionScreen(title: "Archived", layout: .monthly,
                assets: assets, phase: .loaded(()), onRetry: {}, onDelete: { _ in }, shareURLs: { _ in [] })
        })
        var grid: UICollectionView?
        try await waitUntil("Both actual monthly sections have their own snapshot") {
            grid = self.descendant(in: window)
            return grid?.numberOfSections == 2 && grid?.numberOfItems(inSection: 0) == 18
                && grid?.numberOfItems(inSection: 1) == 18
        }
        let collection = try XCTUnwrap(grid)
        collection.layoutIfNeeded()
        for section in 0..<2 {
            let cell = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: section)))
            XCTAssertEqual(cell.frame.width, cell.frame.height, accuracy: 1,
                "Library aspect mode must not corrupt the separate monthly layouts")
            let header = collection.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
            XCTAssertNotNil(header, "Archived, Trash and Locked Folder must keep their month headings")
        }
        XCTAssertLessThan(collection.contentSize.height, 2_500,
            "One month must not reserve the flattened asset geometry of every month")
    }

    private func descendant(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        for child in view.subviews {
            if let collection = descendant(in: child) { return collection }
        }
        return nil
    }
}
