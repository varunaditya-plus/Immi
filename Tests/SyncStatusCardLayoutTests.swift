import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class SyncStatusCardLayoutTests: ViewerAdaptiveLayoutTestCase {
    func testAccessibilityCardsRenderFullLabelsAndCountsOnNarrowScreensInBothAppearances() async throws {
        for width in [CGFloat(320), CGFloat(390)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for labels in [("Local", "Remote"), ("Memories", "Hashed Assets")] {
                    let window = try await host(cards(labels: labels)
                        .dynamicTypeSize(.accessibility5), style: style)
                    resize(window, to: CGSize(width: width, height: 760))
                    let first = try await labelFrame(labels.0, window: window)
                    let second = try await labelFrame(labels.1, window: window)
                    let firstValue = try await labelFrame(12_345.formatted(), window: window)
                    let secondValue = try await labelFrame(67_890.formatted(), window: window)
                    XCTAssertGreaterThanOrEqual(second.minY, firstValue.maxY,
                        "Accessibility cards must stack instead of squeezing both labels into half the viewport")
                    XCTAssertGreaterThan(first.height, 30, "Labels must retain accessibility text sizing")
                    XCTAssertGreaterThan(firstValue.height, 35,
                        "The original fixed 28pt value box clipped enlarged counts")
                    XCTAssertGreaterThanOrEqual(firstValue.minY, first.maxY)
                    XCTAssertGreaterThanOrEqual(secondValue.minY, second.maxY)
                    for frame in [first, second, firstValue, secondValue] {
                        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                            "Complete labels and values must remain inside the narrow viewport: \(frame)")
                    }
                    let snapshot = try await screenshot(window)
                    let text = try renderedStrings(snapshot).joined(separator: " ")
                    for label in [labels.0, labels.1] {
                        XCTAssertTrue(letters(text).contains(letters(label)),
                            "The actual card must render the complete \(label) label, rather than an ellipsis: \(text)")
                    }
                    for digits in ["12345", "67890"] {
                        XCTAssertTrue(text.filter(\.isNumber).contains(digits),
                            "The full count must render without clipping or abbreviation: \(text)")
                    }
                    window.isHidden = true
                }
            }
        }
    }

    func testOrdinaryCardsKeepTwoColumnsAndFullCountsInBothAppearances() async throws {
        for width in [CGFloat(320), CGFloat(390)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let window = try await host(cards(labels: ("Memories", "Hashed Assets"))
                    .dynamicTypeSize(.large), style: style)
                resize(window, to: CGSize(width: width, height: 760))
                let first = try await labelFrame("Memories", window: window)
                let second = try await labelFrame("Hashed Assets", window: window)
                XCTAssertEqual(first.midY, second.midY, accuracy: 1)
                XCTAssertGreaterThan(second.minX, first.maxX,
                    "Ordinary text sizes must retain the existing two-column summary")
                let snapshot = try await screenshot(window)
                let text = try renderedStrings(snapshot).joined(separator: " ")
                for value in ["Memories", "Hashed Assets"] {
                    XCTAssertTrue(letters(text).contains(letters(value)), "Missing ordinary label: \(text)")
                }
                for digits in ["12345", "67890"] {
                    XCTAssertTrue(text.filter(\.isNumber).contains(digits), "Missing ordinary count: \(text)")
                }
                window.isHidden = true
            }
        }
    }

    func testRefreshingShowsANativeSpinnerOnlyForTheMissingCountAndKeepsTheExistingCountVisible() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(SyncStatusCards(
                leading: ("Local", "iphone", nil), trailing: ("Remote", "icloud.fill", 12_345), isRefreshing: true)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemBackground)).dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 320, height: 760))
            let local = try await labelFrame("Local", window: window)
            let remote = try await labelFrame("Remote", window: window)
            let value = try await labelFrame(12_345.formatted(), window: window)
            try await waitUntil("The missing count displays its actual animated native indicator") {
                self.descendants(window).compactMap { $0 as? UIActivityIndicatorView }.filter(\.isAnimating).count == 1
            }
            let indicators = descendants(window).compactMap { $0 as? UIActivityIndicatorView }.filter(\.isAnimating)
            XCTAssertEqual(indicators.count, 1, "Refreshing must not replace an existing count with another spinner")
            let indicator = try XCTUnwrap(indicators.first)
            let indicatorFrame = indicator.convert(indicator.bounds, to: window)
            XCTAssertFalse(indicatorFrame.isEmpty)
            XCTAssertTrue(window.bounds.contains(indicatorFrame), "The animated indicator must be visible")
            XCTAssertGreaterThanOrEqual(indicatorFrame.minY, local.maxY)
            XCTAssertLessThanOrEqual(indicatorFrame.maxY, remote.minY,
                "Only the missing Local value should show the progress indicator")
            XCTAssertTrue(window.bounds.contains(value), "The existing Remote count must remain visible while refreshing")
            XCTAssertNil(accessibilityObject("—", in: window), "Loading must not masquerade as an unavailable count")
            let snapshot = try await screenshot(window)
            let text = try renderedStrings(snapshot).joined(separator: " ")
            XCTAssertTrue(text.filter(\.isNumber).contains("12345"),
                "Refreshing must retain the complete rendered existing count: \(text)")
            window.isHidden = true
        }
    }

    func testUnavailableCountsRemainDistinctFromZeroAtLargestTextSize() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = try await host(SyncStatusCards(
                leading: ("Local", "iphone", nil), trailing: ("Remote", "icloud.fill", 0), isRefreshing: false)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemBackground)).dynamicTypeSize(.accessibility5), style: style)
            _ = try await labelFrame("—", window: window)
            let zero = try await labelFrame("0", window: window)
            XCTAssertGreaterThan(zero.height, 35)
            let snapshot = try await screenshot(window)
            let glyph = try XCTUnwrap(snapshot.cgImage?.cropping(to: zero.applying(
                CGAffineTransform(scaleX: snapshot.scale, y: snapshot.scale))))
            var pixels = [UInt8](repeating: 0, count: glyph.width * glyph.height * 4)
            try pixels.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: glyph.width, height: glyph.height,
                    bitsPerComponent: 8, bytesPerRow: glyph.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(glyph, in: CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height))
            }
            let ink = stride(from: 0, to: pixels.count, by: 4).filter {
                style == .dark ? pixels[$0] > 220 : pixels[$0] < 40
            }.count
            XCTAssertGreaterThan(ink, glyph.width * glyph.height / 10,
                "The actual zero glyph must render against its card, rather than remain an accessibility-only value")
            window.isHidden = true
        }
    }

    private func cards(labels: (String, String)) -> some View {
        SyncStatusCards(leading: (LocalizedStringKey(labels.0), "calendar", 12_345),
            trailing: (LocalizedStringKey(labels.1), "number", 67_890), isRefreshing: false)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
    }

    private func labelFrame(_ text: String, window: UIWindow) async throws -> CGRect {
        try await waitUntil("The actual status card exposes \(text)") {
            self.accessibilityObject(text, in: window) != nil
        }
        let object = try XCTUnwrap(accessibilityObject(text, in: window))
        return window.convert(object.accessibilityFrame, from: nil)
    }

    private func letters(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }
}
