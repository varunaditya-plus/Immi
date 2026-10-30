import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class LibraryHeaderLayoutTests: SimulatorHostedTestCase {
    func testLibraryHeaderKeepsTitleCountSortAndSelectReadableAtCompactAccessibilitySizes() async throws {
        try await verifyHeader(widths: [320, 390], size: .accessibility5, expectsFullCount: false)
    }

    func testNormalLibraryHeaderUsesFullCountsAtEverySupportedPhoneWidth() async throws {
        try await verifyHeader(widths: [375, 390, 420], size: .large, expectsFullCount: true)
    }

    func testFrenchLibraryHeaderKeepsCompleteLabelsInsideCompactAccessibilityWidth() async throws {
        try await verifyHeader(widths: [320], size: .accessibility5, expectsFullCount: false, language: "fr")
    }

    func testRightToLeftLibraryHeaderMirrorsControlsInsideCompactAccessibilityWidth() async throws {
        try await verifyHeader(widths: [320], size: .accessibility5, expectsFullCount: false,
            layoutDirection: .rightToLeft)
    }

    private func verifyHeader(widths: [CGFloat], size: DynamicTypeSize, expectsFullCount: Bool,
                              language: String = "en", layoutDirection: LayoutDirection = .leftToRight) async throws {
        let locale = Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
        let bundlePath = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: bundlePath))
        let libraryTitle = bundle.localizedString(forKey: "Library", value: nil, table: nil)
        let selectTitle = bundle.localizedString(forKey: "Select", value: nil, table: nil)
        let sortTitle = bundle.localizedString(forKey: "Sort and Filter", value: nil, table: nil)
        let fullCount = SettingsView.assetCounts(images: 290, videos: 10, bundle: bundle, locale: locale)
        let compactCount = String(localized: "\(300) items", bundle: bundle, locale: locale)
        for width in widths {
            var selected = false
            let window = try await host(NavigationStack {
                Color(.systemBackground)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TimelineLibraryToolbar(width: width, count: fullCount, itemCount: 300,
                                sort: {
                                    Menu { Button("All Items") {} } label: {
                                        Image(systemName: "line.3.horizontal.decrease")
                                    }
                                    .accessibilityLabel("Sort and Filter")
                                }, select: {
                                    Button("Select") { selected = true }
                                })
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            }
            .dynamicTypeSize(size)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection))
            window.frame.size.width = width
            window.rootViewController?.view.frame = window.bounds
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            let image = try await screenshot(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = language == "fr" ? ["fr-FR", "en-US"] : ["en-US"]
            let cgImage = try XCTUnwrap(image.cgImage)
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let rows = request.results ?? []
            let edgeMarks = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            let library = try XCTUnwrap(rows.first {
                $0.topCandidates(1).first?.string.trimmingCharacters(in: edgeMarks) == libraryTitle
            }, "The full \(libraryTitle) title must render at \(width)pt with \(size)")
            let select = try XCTUnwrap(rows.first {
                $0.topCandidates(1).first?.string.trimmingCharacters(in: edgeMarks) == selectTitle
            }, "The full \(selectTitle) control must render")
            let counts = rows.filter {
                let text = $0.topCandidates(1).first?.string ?? ""
                return text.contains("290") || text.contains("300")
            }
            XCTAssertFalse(counts.isEmpty, "A full or compact item count must remain rendered")
            let text = rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let normalizedText = normalizedCaption(text)
            let hasFullCount = normalizedText.contains(normalizedCaption(fullCount))
            let hasCompactCount = normalizedText.contains(normalizedCaption(compactCount))
            if expectsFullCount {
                XCTAssertTrue(hasFullCount, "Normal-width chrome must preserve the full photo and video counts: \(text)")
                XCTAssertFalse(hasCompactCount, "Compact fallback must not replace a full count that fits")
            } else {
                XCTAssertTrue(hasFullCount || hasCompactCount,
                    "The count must remain complete at accessibility sizes: \(text)")
            }
            let selectFrame = try controlFrame(named: selectTitle, in: window)
            let sortFrame = try controlFrame(named: sortTitle, in: window)
            let libraryFrame = frame(of: library, in: window)
            let countFrames = counts.map { frame(of: $0, in: window) }
            let viewport = window.bounds.insetBy(dx: -0.5, dy: -0.5)
            for frame in [libraryFrame, frame(of: select, in: window), selectFrame, sortFrame] + countFrames {
                XCTAssertTrue(viewport.contains(frame), "The complete header and controls must fit inside the \(width)pt viewport: \(frame)")
            }
            if layoutDirection == .rightToLeft {
                XCTAssertLessThan(selectFrame.maxX, libraryFrame.minX)
                XCTAssertTrue(countFrames.allSatisfy { selectFrame.maxX < $0.minX })
            } else {
                XCTAssertLessThan(libraryFrame.maxX, selectFrame.minX)
                XCTAssertTrue(countFrames.allSatisfy { $0.maxX < selectFrame.minX })
            }
            try await activateAccessibilityButton(named: selectTitle, in: window)
            XCTAssertTrue(selected)
            try await activateAccessibilityButton(named: sortTitle, in: window)
            if let presented = window.rootViewController?.presentedViewController {
                await withCheckedContinuation { continuation in
                    presented.dismiss(animated: false) { continuation.resume() }
                }
            }
        }
    }

    private func normalizedCaption(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
    }

    private func frame(of observation: VNRecognizedTextObservation, in window: UIWindow) -> CGRect {
        let box = observation.boundingBox
        return CGRect(x: box.minX * window.bounds.width, y: (1 - box.maxY) * window.bounds.height,
            width: box.width * window.bounds.width, height: box.height * window.bounds.height)
    }

    private func controlFrame(named title: String, in window: UIWindow) throws -> CGRect {
        var visited = Set<ObjectIdentifier>()
        func frames(in object: NSObject, depth: Int) -> [CGRect] {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return [] }
            if let control = object as? UIControl, !control.isEnabled { return [] }
            var found: [CGRect] = []
            if object.accessibilityLabel == title, object.accessibilityTraits.contains(.button),
               !object.accessibilityTraits.contains(.notEnabled) {
                let frame: CGRect
                if let view = object as? UIView {
                    frame = view.window === window ? view.convert(view.bounds, to: window) : .zero
                } else {
                    frame = window.convert(object.accessibilityFrame, from: nil)
                }
                if !frame.isEmpty, window.bounds.intersects(frame) { found.append(frame) }
            }
            if let view = object as? UIView {
                for child in view.subviews { found += frames(in: child, depth: depth + 1) }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { found += frames(in: child, depth: depth + 1) }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        found += frames(in: child, depth: depth + 1)
                    }
                }
            }
            return found
        }
        return try XCTUnwrap(frames(in: window, depth: 0).min { $0.minY < $1.minY },
            "The actual enabled \(title) control must expose its visible frame")
    }
}
