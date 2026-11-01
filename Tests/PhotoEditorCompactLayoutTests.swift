import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoEditorCompactLayoutTests: ViewerAdaptiveLayoutTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        try await super.tearDown()
        for file in files { try FileManager.default.removeItem(at: file) }
        files.removeAll()
    }

    func testShortLandscapePhotoEditorKeepsItsPreviewAndAdjustmentReachableAtAccessibilitySize() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            var saves: [PhotoEditRecipe] = []
            let window = try await host(PhotoCropEditor(initialRecipe: .init(), loadImage: { image },
                isAllowed: { true }, onSave: { saves.append($0); return true }, onRevert: { true })
                .dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 568, height: 320))
            var preview: NSObject?
            try await waitUntil("The photo editor exposes its actual preview") {
                preview = self.accessibilityObject("Edited Photo", in: window)
                return preview != nil
            }
            let photo = try XCTUnwrap(preview)
            let frame = window.convert(photo.accessibilityFrame, from: nil)
            XCTAssertGreaterThanOrEqual(frame.intersection(window.bounds).height, 80,
                "Large controls cannot collapse the photo preview in a short landscape window")
            try scrollVertically(to: try XCTUnwrap(accessibilityObject("Exposure", in: window)), in: window)
            try await activateAccessibilityButton(named: "Exposure", in: window)
            let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }
                .first { $0.accessibilityLabel == "Exposure" })
            try scrollVertically(to: slider, in: window)
            XCTAssertTrue(window.bounds.contains(slider.convert(slider.bounds, to: window)))
            slider.sendActions(for: .touchDown)
            slider.value = slider.maximumValue
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
            try await activateAccessibilityButton(named: "Done", in: window)
            try await waitUntil("The reachable adjustment saves through the actual editor") { saves.count == 1 }
            XCTAssertEqual(try XCTUnwrap(saves.first)[.exposure], 1, accuracy: 0.001)
        }
    }

    func testShortLandscapeLiveEditorKeepsItsPhotoToolsAndSaveReachableAtAccessibilitySize() async throws {
        let movie = try await makePagerPlaybackMovie()
        files.append(movie)
        for style in [UIUserInterfaceStyle.light, .dark] {
            var saved: [PhotoEditRecipe] = []
            let window = try await host(MediaVideoEditor(sourceURL: movie, isLivePhoto: true,
                isAllowed: { true }, onSave: { _, _, photo in saved.append(photo); return true }, onRevert: { true })
                .dynamicTypeSize(.accessibility5), style: style)
            resize(window, to: CGSize(width: 568, height: 320))
            try await waitUntil("The actual generated Live motion loads its editor tools") {
                self.accessibilityObject("Adjust", in: window) != nil
            }
            try scrollVertically(to: try XCTUnwrap(accessibilityObject("Adjust", in: window)), in: window)
            try await activateAccessibilityButton(named: "Adjust", in: window)
            var preview: NSObject?
            try await waitUntil("The Live editor displays its shared photo adjustment preview") {
                preview = self.accessibilityObject("Edited Photo", in: window)
                return preview != nil
            }
            let photo = try XCTUnwrap(preview)
            try scrollVertically(to: photo, in: window)
            XCTAssertGreaterThanOrEqual(window.convert(photo.accessibilityFrame, from: nil).intersection(window.bounds).height, 80)
            try scrollVertically(to: try XCTUnwrap(accessibilityObject("Exposure", in: window)), in: window)
            try await activateAccessibilityButton(named: "Exposure", in: window)
            let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }
                .first { $0.accessibilityLabel == "Exposure" })
            try scrollVertically(to: slider, in: window)
            XCTAssertTrue(window.bounds.contains(slider.convert(slider.bounds, to: window)))
            slider.sendActions(for: .touchDown)
            slider.value = slider.maximumValue
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
            try await activateAccessibilityButton(named: "Done", in: window)
            try await waitUntil("The reachable Live adjustment saves through its actual editor") { saved.count == 1 }
            XCTAssertEqual(try XCTUnwrap(saved.first)[.exposure], 1, accuracy: 0.001)
        }
    }

    func testSceneInterruptionReleasesActualEditingScrollLockWithoutATouchEnd() async throws {
        let scene = EditorSceneProbeState()
        let window = try await host(EditorSceneProbe(state: scene).dynamicTypeSize(.accessibility5))
        resize(window, to: CGSize(width: 568, height: 320))
        try await waitUntil("The interrupted editor has loaded its actual adjustment controls") {
            self.accessibilityObject("Exposure", in: window) != nil
        }
        try scrollVertically(to: try XCTUnwrap(accessibilityObject("Exposure", in: window)), in: window)
        try await activateAccessibilityButton(named: "Exposure", in: window)
        let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }
            .first { $0.accessibilityLabel == "Exposure" })
        try scrollVertically(to: slider, in: window)
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > window.bounds.width * 0.9 && $0.contentSize.height > $0.bounds.height + 1
        })
        XCTAssertTrue(scroll.isScrollEnabled)

        slider.sendActions(for: .touchDown)
        try await waitUntil("An actual editing gesture locks its enclosing vertical scrolling") { !scroll.isScrollEnabled }
        scene.phase = .inactive

        try await waitUntil("Scene interruption releases the lock before the missing touch-end arrives") { scroll.isScrollEnabled }
        scene.phase = .active
        try await waitUntil("The editor is scrollable after resuming from the interrupted gesture") { scroll.isScrollEnabled }
        slider.sendActions(for: .touchCancel)
    }

    func testNormalTallAndRegularWindowsKeepTheActualPhotoAtFullAvailableWidth() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let layouts: [(CGSize, UserInterfaceSizeClass)] = [
            (CGSize(width: 390, height: 844), .compact), (CGSize(width: 768, height: 1024), .regular)
        ]
        for (size, sizeClass) in layouts {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let window = try await host(PhotoCropEditor(initialRecipe: .init(), loadImage: { image },
                    isAllowed: { true }, onSave: { _ in true }, onRevert: { true })
                    .dynamicTypeSize(.large).environment(\.horizontalSizeClass, sizeClass), style: style)
                resize(window, to: size)
                var preview: NSObject?
                try await waitUntil("The normal editor renders its actual full-width image") {
                    preview = self.accessibilityObject("Edited Photo", in: window)
                    return preview != nil
                }
                let frame = window.convert(try XCTUnwrap(preview).accessibilityFrame, from: nil)
                XCTAssertGreaterThan(frame.width, size.width * 0.9,
                    "The scrolling fallback cannot collapse a normal editor into its minimum preview")
                XCTAssertEqual(frame.width / frame.height, 1.5, accuracy: 0.01)
                XCTAssertTrue(window.bounds.contains(frame))
                let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }
                    .first { $0.bounds.width > size.width * 0.9 })
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                _ = try await screenshot(window)
            }
        }
    }
}

@MainActor @Observable
private final class EditorSceneProbeState { var phase = ScenePhase.active }

private struct EditorSceneProbe: View {
    let state: EditorSceneProbeState
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
        UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    }
    var body: some View {
        PhotoCropEditor(initialRecipe: .init(), loadImage: { image }, isAllowed: { true },
            onSave: { _ in true }, onRevert: { true }).environment(\.scenePhase, state.phase)
    }
}

