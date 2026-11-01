import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoMapStyleLayoutTests: SimulatorHostedTestCase {
    func testAccessibilityMapChoicesRemainReachableInAShortWindowInBothAppearances() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            var selection = PhotoMapStyle.explore
            let window = try await host(PhotoMapStylePicker(selection: Binding(
                get: { selection }, set: { selection = $0 }), bounds: bounds)
                .environment(\.dynamicTypeSize, .accessibility5), style: style)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
            window.rootViewController?.view.frame = window.bounds
            window.layoutIfNeeded()

            var scroll: UIScrollView?
            try await waitUntil("Map options scroll instead of extending below the short window") {
                scroll = self.descendants(window).compactMap { $0 as? UIScrollView }.first {
                    $0.isScrollEnabled && $0.bounds.width > 200 && $0.contentSize.height > $0.bounds.height
                }
                return scroll != nil
            }
            let options = try XCTUnwrap(scroll)
            options.setContentOffset(CGPoint(x: 0, y: options.contentSize.height - options.bounds.height), animated: false)
            window.layoutIfNeeded()
            try await activateAccessibilityButton(named: "Satellite", in: window)
            XCTAssertEqual(selection, .satellite)
            let close = try XCTUnwrap(accessibilityButton(named: "Close", in: window))
            XCTAssertTrue(window.bounds.contains(window.convert(close.accessibilityFrame, from: nil)),
                "The pinned Close control must remain on screen while the choices scroll")
            _ = try await screenshot(window)
            window.isHidden = true
        }
    }

    private var bounds: PhotoMapBounds {
        PhotoMapBounds(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

}
