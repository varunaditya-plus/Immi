import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class VideoControlsAccessibilityLayoutTests: ViewerAdaptiveLayoutTestCase {
    private var bars: [PhotoVideoControlsBar] = []
    private var pagers: [PhotoPagerController] = []

    override func tearDown() async throws {
        bars.forEach { $0.detach() }
        pagers.forEach { $0.stopAllPlayback() }
        try await super.tearDown()
        bars.removeAll()
        pagers.removeAll()
    }

    func testEnlargedScrubTimestampsAndSliderFitTheirActualBarWithoutClipping() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let pager = PhotoPagerController(loader: PhotoPreviewLoader(session: MockSessionManager()))
            pagers.append(pager)
            let window = try await host(VStack {
                Spacer()
                PhotoVideoControlsView(pager: pager).frame(minHeight: 48).padding(.horizontal, 28)
            }, style: style)
            try await waitUntil("The actual production video controls mount") {
                self.descendants(window).contains { $0 is PhotoVideoControlsBar }
            }
            let bar = try XCTUnwrap(descendants(window).compactMap { $0 as? PhotoVideoControlsBar }.first)
            bars.append(bar)
            XCTAssertEqual(bar.bounds.height, 48, accuracy: 1)
            window.rootViewController?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            resize(window, to: CGSize(width: 320, height: 568))
            bar.playbackDidUpdate(PhotoPlaybackState(isVideo: true, time: 3666, duration: 7200))
            let slider = try XCTUnwrap(descendants(bar).compactMap { $0 as? UISlider }.first)
            slider.sendActions(for: .touchDown)
            let snapshot = try await screenshot(window)
            XCTAssertLessThan(bar.bounds.height, window.bounds.height / 2,
                "The real playback bar must fit its controls rather than absorb spare window height")
            let labels = descendants(bar).compactMap { $0 as? UILabel }.filter { $0.text == "1:01:06" || $0.text == "−58:54" }
            XCTAssertEqual(labels.count, 2)
            for label in labels {
                XCTAssertGreaterThan(label.font.pointSize, 20, "The probe must use an enlarged timestamp font")
                XCTAssertGreaterThanOrEqual(label.bounds.height, label.font.lineHeight - 1)
                XCTAssertGreaterThanOrEqual(label.bounds.width, label.intrinsicContentSize.width - 1)
                XCTAssertTrue(bar.bounds.insetBy(dx: -1, dy: -1).contains(label.convert(label.bounds, to: bar)))
                XCTAssertFalse(label.convert(label.bounds, to: bar).intersects(slider.convert(slider.bounds, to: bar)))
            }
            XCTAssertGreaterThanOrEqual(slider.bounds.height, slider.intrinsicContentSize.height - 1)
            let strings = try renderedStrings(snapshot)
            XCTAssertTrue(strings.contains { $0.contains("1:01:06") }, "The elapsed timestamp must render completely: \(strings)")
            XCTAssertTrue(strings.contains { $0.contains("58:54") }, "The remaining timestamp must render completely: \(strings)")
            slider.sendActions(for: .touchUpInside)
            try await waitUntil("Ending the scrub restores the compact playback bar") { abs(bar.bounds.height - 48) < 1 }
        }
    }
}
