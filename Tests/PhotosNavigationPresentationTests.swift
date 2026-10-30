import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotosNavigationPresentationTests: SimulatorHostedTestCase {
    func testNativeCompactTabsExposeLibraryCollectionsAndSearch() async throws {
        let window = try await host(MainTabView().environment(\.horizontalSizeClass, .compact))
        var bar: UITabBar?
        try await waitUntil("All three native tabs are mounted") {
            bar = self.tabBar(in: window)
            return bar?.items?.count == 3
        }
        let items = try XCTUnwrap(bar?.items)
        XCTAssertEqual(items.map(\.title), ["Library", "Collections", "Search"])
        XCTAssertEqual(bar?.selectedItem, items.first)
        _ = try await screenshot(window)
    }

    func testCollectionTabAndAlbumsHeadingNavigateThroughTheRealControls() async throws {
        let window = try await host(MainTabView().environment(\.horizontalSizeClass, .compact))
        try await activateAccessibilityButton(named: "Collections", in: window)
        try await waitUntil("Collections is the selected native tab") {
            self.tabBar(in: window)?.selectedItem?.title == "Collections"
        }
        _ = try await screenshot(window)
        try await activateAccessibilityButton(named: "Albums", in: window)
        try await waitUntil("The production Albums screen is pushed") {
            self.navigationControllers(in: window.rootViewController).contains {
                $0.topViewController?.navigationItem.title == "Albums" && $0.transitionCoordinator == nil
            }
        }
        XCTAssertFalse(try XCTUnwrap(tabBar(in: window)).isHidden,
            "Albums list retains the Photos tab bar")
        _ = try await screenshot(window)
    }

    private func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        return view.subviews.compactMap { tabBar(in: $0) }.first
    }

    private func navigationControllers(in controller: UIViewController?) -> [UINavigationController] {
        guard let controller else { return [] }
        return (controller as? UINavigationController).map { [$0] } ?? controller.children.flatMap {
            navigationControllers(in: $0)
        }
    }
}
