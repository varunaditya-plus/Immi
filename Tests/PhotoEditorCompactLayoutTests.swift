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

    func testNarrowCropToolbarsKeepCancelAndDoneVisibleAndSaveTheActualPhotoVideoAndLiveDrafts() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 120)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
        }
        let movie = try await makePagerPlaybackMovie()
        files.append(movie)
        for width: CGFloat in [320, 375, 390, 414] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for kind in [MediaEditDocument.Kind.photo, .video, .livePhoto] {
                    var saved: [PhotoEditRecipe] = []
                    let editor: AnyView
                    if kind == .photo {
                        editor = AnyView(PhotoCropEditor(initialRecipe: .init(), loadImage: { image },
                            isAllowed: { true }, onSave: { saved.append($0); return true }, onRevert: { true }))
                    } else {
                        editor = AnyView(MediaVideoEditor(sourceURL: movie, isLivePhoto: kind == .livePhoto,
                            isAllowed: { true }, onSave: { _, _, photo in saved.append(photo); return true }, onRevert: { true }))
                    }
                    let window = try await host(editor.dynamicTypeSize(.large), style: style)
                    resize(window, to: CGSize(width: width, height: 667))
                    for tool in ["Adjust", "Filters"] {
                        try await activateAccessibilityButton(named: tool, in: window)
                        try await assertVisibleToolbarCommands(["Cancel", "Done", "More"], in: window,
                            context: "\(kind) \(tool) at \(width) points")
                        if tool == "Adjust", width < 350 {
                            try await activateAccessibilityButton(named: "Exposure", in: window)
                            var slider: UISlider?
                            try await waitUntil("The actual Exposure slider is ready before testing menu history") {
                                slider = self.descendants(window).compactMap { $0 as? UISlider }
                                    .first { $0.accessibilityLabel == "Exposure" && $0.isEnabled }
                                return slider != nil
                            }
                            let control = try XCTUnwrap(slider)
                            control.sendActions(for: .touchDown)
                            control.value = 0.75
                            control.sendActions(for: .valueChanged)
                            control.sendActions(for: .touchUpInside)
                            try await activateSearchMenuAction(named: "Undo", in: window)
                            try await waitUntil("The real narrow-menu Undo restores the original adjustment") {
                                abs(control.value - 0.5) < 0.001
                            }
                            try await activateSearchMenuAction(named: "Redo", in: window)
                            try await waitUntil("The real narrow-menu Redo restores the edited adjustment") {
                                abs(control.value - 0.75) < 0.001
                            }
                        }
                    }
                    try await activateAccessibilityButton(named: "Crop", in: window)
                    let commands = ["Cancel", "Done", "More"]
                        + (width >= 350 ? ["Flip", "Rotate Left"] : [])
                        + (width >= 400 ? ["Aspect Ratio"] : [])
                    try await assertVisibleToolbarCommands(commands, in: window,
                        context: "\(kind) Crop at \(width) points")
                    if width < 400 {
                        try await activateSearchMenuAction(named: "Aspect Ratio", in: window)
                    } else {
                        try await activateAccessibilityButton(named: "Aspect Ratio", in: window)
                    }
                    try await activateAccessibilityButton(named: "SQUARE", in: window)
                    for title in ["Flip", "Rotate Left"] {
                        if width < 350 {
                            try await activateSearchMenuAction(named: title, in: window)
                        } else {
                            try await activateAccessibilityButton(named: title, in: window)
                        }
                    }
                    try await assertVisibleToolbarCommands(commands, in: window,
                        context: "\(kind) Save after crop changes at \(width) points")
                    try await activateAccessibilityButton(named: "Done", in: window)
                    try await waitUntil("The actual narrow \(kind) editor saves its flipped draft") { saved.count == 1 }
                    let recipe = try XCTUnwrap(saved.first)
                    XCTAssertTrue(recipe.flipHorizontal)
                    XCTAssertEqual(recipe.quarterTurns, 3)
                    XCTAssertEqual(recipe.cropAspectRatio, 1)
                    XCTAssertEqual(recipe[.exposure], width < 350 ? 0.5 : 0, accuracy: 0.001)
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
        }
    }

    private func assertVisibleToolbarCommands(_ titles: [String], in window: UIWindow, context: String) async throws {
        var frames: [String: CGRect] = [:]
        for title in titles {
            var control: NSObject?
            try await waitUntil("The \(context) toolbar retains enabled \(title)") {
                control = self.accessibilityButton(named: title, in: window)
                return control != nil
            }
            if control == nil { _ = try await screenshot(window) }
            let button = try XCTUnwrap(control)
            let frame = if let view = button as? UIView {
                view.convert(view.bounds, to: window)
            } else { window.convert(button.accessibilityFrame, from: nil) }
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(window.bounds.contains(frame), "The \(context) \(title) control must fit inside the viewport")
            frames[title] = frame
        }
        if let cancel = frames["Cancel"], let flip = frames["Flip"] {
            XCTAssertLessThan(cancel.minX, flip.minX, "The \(context) Cancel action must remain before the crop transforms")
        }
        if let done = frames["Done"], let more = frames["More"] {
            XCTAssertGreaterThan(done.maxX, more.maxX, "The \(context) Done action must remain after More")
        }
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
                _ = try XCTUnwrap(preview)
                let frame = try renderedGreenPhotoFrame(in: await screenshot(window))
                XCTAssertGreaterThan(frame.width, size.width * 0.9,
                    "The scrolling fallback cannot collapse a normal editor into its minimum preview")
                XCTAssertEqual(frame.width / frame.height, 1.5, accuracy: 0.01)
                XCTAssertTrue(window.bounds.contains(frame))
                let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }
                    .first { $0.bounds.width > size.width * 0.9 })
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
            }
        }
    }

    private func renderedGreenPhotoFrame(in image: UIImage) throws -> CGRect {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset + 1] > 220, pixels[offset] < 30, pixels[offset + 2] < 30 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        XCTAssertGreaterThan(right - left, width / 2, "Only the actually rendered full photo can satisfy the geometry check")
        guard right >= left, bottom >= top else { throw URLError(.cannotDecodeContentData) }
        return CGRect(x: CGFloat(left) / image.scale, y: CGFloat(top) / image.scale,
            width: CGFloat(right - left + 1) / image.scale, height: CGFloat(bottom - top + 1) / image.scale)
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

