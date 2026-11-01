import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class VideoControlsAccessibilityLayoutTests: ViewerAdaptiveLayoutTestCase {
    private var bars: [PhotoVideoControlsBar] = []

    override func tearDown() async throws {
        bars.forEach { $0.detach() }
        try await super.tearDown()
        bars.removeAll()
    }

    func testEnlargedScrubTimestampsAndSliderFitTheirActualBarWithoutClipping() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let bar = PhotoVideoControlsBar()
            bars.append(bar)
            let window = try await host(VideoBarLayoutProbe(bar: bar)
                .frame(minHeight: 48).padding(.horizontal, 28), style: style)
            window.rootViewController?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            resize(window, to: CGSize(width: 320, height: 568))
            bar.playbackDidUpdate(PhotoPlaybackState(isVideo: true, time: 3666, duration: 7200))
            let slider = try XCTUnwrap(descendants(bar).compactMap { $0 as? UISlider }.first)
            slider.sendActions(for: .touchDown)
            let snapshot = try await screenshot(window)
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
        }
    }
}

private struct VideoBarLayoutProbe: UIViewRepresentable {
    let bar: PhotoVideoControlsBar
    func makeUIView(context: Context) -> PhotoVideoControlsBar { bar }
    func updateUIView(_ view: PhotoVideoControlsBar, context: Context) {}
}
