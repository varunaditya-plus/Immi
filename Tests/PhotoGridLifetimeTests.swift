import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoGridLifetimeTests: SimulatorHostedTestCase {
    private weak var owner: GridLifetimeOwner?
    private weak var controller: PhotoGridController?

    func testDismantledMonthlyGridReleasesItsControllerAndCapturedOwner() async throws {
        try await verifyRelease(layout: .monthly, scrollHeroOffscreen: false)
    }

    func testDismantledHeroGridReleasesOwnersEvenWhenTheHeroIsInTheReusePool() async throws {
        try await verifyRelease(layout: .hero, scrollHeroOffscreen: true)
    }

    private func verifyRelease(layout: PhotoCollectionLayout, scrollHeroOffscreen: Bool) async throws {
        let window = try await hostedCollection(layout: layout)
        try await waitUntil("The production collection has installed its UIKit controller") {
            self.grid(in: window.rootViewController) != nil
        }
        controller = grid(in: window.rootViewController)
        XCTAssertNotNil(owner, "The mounted view must retain its real action owner")
        if scrollHeroOffscreen {
            try await waitUntil("The real hero has rendered before being moved into the reuse pool") {
                guard let grid = self.grid(in: window.rootViewController),
                      let collection = grid.view.subviews.first(where: { $0 is UICollectionView }) as? UICollectionView else { return false }
                collection.layoutIfNeeded()
                return collection.visibleCells.contains { $0 is PhotoGridHostCell }
            }
            try await waitUntil("The hero and all photo rows have completed their actual snapshot") {
                guard let grid = self.grid(in: window.rootViewController) else { return false }
                return grid.revealCell(for: "lifetime-199") != nil
            }
            let collection = try XCTUnwrap(controller?.view.subviews.first(where: { $0 is UICollectionView }) as? UICollectionView)
            collection.layoutIfNeeded()
            XCTAssertFalse(collection.visibleCells.contains { $0 is PhotoGridHostCell },
                "The old hero must be offscreen so visible-cell cleanup alone cannot satisfy this regression")
        }

        window.isHidden = true
        window.rootViewController = nil

        try await waitUntil("Dismantling the representable releases its controller and all captured owner actions") {
            self.controller == nil && self.owner == nil
        }
    }

    private func hostedCollection(layout: PhotoCollectionLayout) async throws -> UIWindow {
        let owner = GridLifetimeOwner()
        self.owner = owner
        let photos = (0..<200).map {
            AssetLite(id: "lifetime-\($0)", isVideo: false, ratio: 1, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_793_188_800))
        }
        return try await host(NavigationStack {
            PhotoCollectionScreen(title: "Collection", layout: layout, assets: photos, phase: .loaded(()),
                onRetry: { owner.operations += 1 }, onDelete: { _ in owner.operations += 1 }, shareURLs: { _ in [] })
        })
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.grid(in: $0) }.first
    }
}

private final class GridLifetimeOwner {
    var operations = 0
}
