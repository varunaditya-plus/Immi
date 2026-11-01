import SwiftUI
import UIKit
import Vision
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
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(MainTabView().environment(\.horizontalSizeClass, .compact), style: style)
            try await activateAccessibilityButton(named: "Collections", in: window)
            try await waitUntil("Collections is the selected native tab") {
                self.tabBar(in: window)?.selectedItem?.title == "Collections"
            }
            try await activateAccessibilityButton(named: "Albums", in: window)
            var navigation: UINavigationController?
            try await waitUntil("The production Albums screen is pushed") {
                navigation = self.navigationControllers(in: window.rootViewController).first {
                    $0.topViewController?.navigationItem.title == "Albums" && $0.transitionCoordinator == nil
                }
                return navigation != nil
            }
            XCTAssertFalse(try XCTUnwrap(tabBar(in: window)).isHidden,
                "Albums list retains the Photos tab bar")
            let bar = try XCTUnwrap(navigation?.navigationBar)
            let image = try await screenshot(window)
            let region = bar.convert(bar.bounds, to: window).intersection(window.bounds)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: region.minX * image.scale,
                y: region.minY * image.scale, width: region.width * image.scale, height: region.height * image.scale)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            XCTAssertTrue(text.contains("Albums"), "The navigation item alone is not enough; its title must render in \(style): \(text)")
            window.isHidden = true
        }
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
