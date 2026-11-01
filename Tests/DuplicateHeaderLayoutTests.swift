import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateHeaderLayoutTests: ViewerAdaptiveLayoutTestCase {
    private var cacheKeys: [String] = []

    override func tearDown() async throws {
        try await super.tearDown()
        cacheKeys.forEach { ImageMemoryCache.shared.remove(for: $0) }
        cacheKeys.removeAll()
    }

    func testAccessibilityHeaderKeepsWholeWordsInsideTheActualNarrowCardInBothAppearances() async throws {
        let summary = "3 items · tap to keep or trash"
        for style in [UIUserInterfaceStyle.light, .dark] {
            let group = makeGroup()
            let geometry = DuplicateHeaderGeometry()
            let window = try await host(ScrollView {
                DuplicateGroupCard(group: group, isWorking: false,
                    onResolve: { _ in XCTFail("Inspecting the header cannot resolve a group") },
                    onKeepAll: { XCTFail("Inspecting the header cannot dismiss a group") })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.frame = $0 }
                    .padding(16)
            }.dynamicTypeSize(.accessibility5).background(Color(.systemBackground)), style: style)
            resize(window, to: CGSize(width: 320, height: 650))
            try await waitUntil("The actual group has its final narrow layout and loaded metadata") {
                abs(geometry.frame.width - 288) < 1 && self.accessibilityObject(summary, in: window) != nil
            }
            let title = try XCTUnwrap(accessibilityObject("Similar Items", in: window))
            let metadata = try XCTUnwrap(accessibilityObject(summary, in: window))
            let suggested = try XCTUnwrap(accessibilityObject("Suggested", in: window))
            let titleFrame = window.convert(title.accessibilityFrame, from: nil)
            let metadataFrame = window.convert(metadata.accessibilityFrame, from: nil)
            let suggestedFrame = window.convert(suggested.accessibilityFrame, from: nil)
            XCTAssertGreaterThan(titleFrame.height, 40, "The header must retain accessibility text sizing")
            XCTAssertGreaterThanOrEqual(suggestedFrame.minY, metadataFrame.maxY,
                "The suggestion belongs below the full-width group metadata instead of crushing a second column")
            for frame in [titleFrame, metadataFrame, suggestedFrame] {
                XCTAssertGreaterThanOrEqual(frame.minX, geometry.frame.minX)
                XCTAssertLessThanOrEqual(frame.maxX, geometry.frame.maxX)
            }
            let text = try renderedStrings(await screenshot(window)).joined(separator: " ")
            for word in ["Similar", "Items", "Suggested"] {
                XCTAssertTrue(text.split(whereSeparator: { !$0.isLetter }).contains(Substring(word)),
                    "The actual header must render complete words without internal hyphenation: \(text)")
            }

            try scrollVertically(to: try XCTUnwrap(accessibilityObject("A.jpg", in: window)), in: window)
            let loadedSnapshot = try await screenshot(window)
            XCTAssertTrue(try containsLoadedPhoto(loadedSnapshot),
                "The card must retain its actual loaded thumbnail below the reflowed header")
        }
    }

    func testDuplicateActionsKeepFullCaptionsAndRemainReachableInBothTextSizesAndAppearances() async throws {
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let group = makeGroup()
                let geometry = DuplicateHeaderGeometry()
                var keptAll = 0
                var resolutions: [Set<String>] = []
                let window = try await host(ScrollView {
                    DuplicateGroupCard(group: group, isWorking: false,
                        onResolve: { resolutions.append($0) }, onKeepAll: { keptAll += 1 })
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.frame = $0 }
                        .padding(16)
                }.dynamicTypeSize(textSize).background(Color(.systemBackground)), style: style)
                resize(window, to: CGSize(width: 320, height: 650))
                try await waitUntil("The actual narrow duplicate card exposes both actions") {
                    abs(geometry.frame.width - 288) < 1
                        && self.accessibilityObject("Keep All", in: window) != nil
                        && self.accessibilityObject("Trash 2", in: window) != nil
                }
                try scrollVertically(to: try XCTUnwrap(accessibilityObject("Trash 2", in: window)), in: window)
                let snapshot = try await screenshot(window)
                let keep = try XCTUnwrap(accessibilityObject("Keep All", in: window))
                let trash = try XCTUnwrap(accessibilityObject("Trash 2", in: window))
                let keepFrame = window.convert(keep.accessibilityFrame, from: nil)
                let trashFrame = window.convert(trash.accessibilityFrame, from: nil)
                for (object, frame) in [(keep, keepFrame), (trash, trashFrame)] {
                    XCTAssertTrue(object.accessibilityTraits.contains(.button))
                    XCTAssertFalse(object.accessibilityTraits.contains(.notEnabled))
                    XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(frame))
                    XCTAssertGreaterThanOrEqual(frame.minX, geometry.frame.minX)
                    XCTAssertLessThanOrEqual(frame.maxX, geometry.frame.maxX)
                }
                if textSize.isAccessibilitySize {
                    XCTAssertGreaterThan(trashFrame.minY, keepFrame.maxY,
                        "Large action captions must stack into full-width controls")
                } else {
                    XCTAssertEqual(keepFrame.midY, trashFrame.midY, accuracy: 1)
                    XCTAssertGreaterThan(trashFrame.minX, keepFrame.maxX,
                        "Ordinary text must retain the existing horizontal actions")
                }
                try assertActionWords(["Keep", "All"], in: keepFrame, image: snapshot, enlarged: textSize.isAccessibilitySize)
                try assertActionWords(["Trash", "2"], in: trashFrame, image: snapshot, enlarged: textSize.isAccessibilitySize)
                XCTAssertEqual(keptAll, 0)
                XCTAssertTrue(resolutions.isEmpty)
                window.isHidden = true
            }
        }
    }

    func testEnlargedDuplicateActionsPresentTheirNativeConfirmationsWithoutResolving() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for action in ["Keep All", "Trash 2"] {
                let group = makeGroup()
                var keptAll = 0
                var resolutions: [Set<String>] = []
                let window = try await host(ScrollView {
                    DuplicateGroupCard(group: group, isWorking: false,
                        onResolve: { resolutions.append($0) }, onKeepAll: { keptAll += 1 })
                        .padding(16)
                }.dynamicTypeSize(.accessibility5).background(Color(.systemBackground)), style: style)
                resize(window, to: CGSize(width: 320, height: 650))
                try await waitUntil("The actual enlarged \(action) button is mounted") {
                    self.accessibilityObject(action, in: window) != nil
                }
                try scrollVertically(to: try XCTUnwrap(accessibilityObject(action, in: window)), in: window)
                try await activateAccessibilityButton(named: action, in: window)
                let alert = try await presentedNativeAlert(in: window)
                XCTAssertEqual(alert.title, action == "Keep All" ? "Keep every item?" : "Move 2 items to Trash?")
                let confirm = try XCTUnwrap(alert.actions.first { $0.title == (action == "Keep All" ? "Keep All" : "Move to Trash") })
                XCTAssertTrue(confirm.isEnabled)
                XCTAssertEqual(confirm.style, action == "Keep All" ? .default : .destructive)
                let cancel = try XCTUnwrap(alert.actions.first { $0.title == "Cancel" })
                XCTAssertEqual(cancel.style, .cancel)
                XCTAssertTrue(cancel.isEnabled)
                XCTAssertEqual(keptAll, 0, "Opening the native confirmation cannot dismiss the duplicate group")
                XCTAssertTrue(resolutions.isEmpty, "Opening a confirmation cannot resolve the duplicate group")
                await withCheckedContinuation { continuation in
                    alert.dismiss(animated: false) { continuation.resume() }
                }
                window.isHidden = true
            }
        }
    }

    private func makeGroup() -> DuplicateGroupDTO {
        let photos = ["A.jpg", "B.jpg", "C.jpg"].map {
            makeTestAsset(id: UUID().uuidString, originalFileName: $0)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        for photo in photos {
            let key = ImageCache.memoryKey("\(photo.id)-thumbnail", 600)
            cacheKeys.append(key)
            ImageMemoryCache.shared.insert(image, for: key)
        }
        return DuplicateGroupDTO(duplicateId: UUID().uuidString, assets: photos,
            suggestedKeepAssetIds: [photos[0].id])
    }

    private func assertActionWords(_ words: [String], in frame: CGRect, image: UIImage, enlarged: Bool) throws {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: frame.minX * image.scale,
            y: frame.minY * image.scale, width: frame.width * image.scale, height: frame.height * image.scale)))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words {
            XCTAssertTrue(tokens.contains(word),
                "The actual action must show its whole caption inside its control without hyphenation: \(words), OCR=\(text)")
        }
        if enlarged {
            let textHeight = (request.results ?? []).map { $0.boundingBox.height * frame.height }.max() ?? 0
            XCTAssertGreaterThan(textHeight, 28, "Action text must retain accessibility sizing while its icon stays compact")
        }
    }

    private func containsLoadedPhoto(_ image: UIImage) throws -> Bool {
        let source = try XCTUnwrap(image.cgImage)
        let width = 160, height = 325
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset] > 220, pixels[offset + 1] < 30, pixels[offset + 2] > 220 { count += 1 }
        }
        return count > 1_000
    }
}

@MainActor
@Observable
private final class DuplicateHeaderGeometry {
    var frame = CGRect.zero
}
