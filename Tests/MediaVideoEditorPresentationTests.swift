import AVFoundation
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class MediaVideoEditorPresentationTests: SimulatorHostedTestCase {
    private var fixtures: [VideoEditorTestFixture] = []
    private var directories: [URL] = []
    private weak var retainedFixture: VideoEditorTestFixture?

    override func tearDown() async throws {
        fixtures.forEach { $0.allowed = false; $0.isPresented = false; $0.gate?.complete(.success(false)) }
        try await waitUntil("Any held video editor saves return before cleanup") { self.fixtures.allSatisfy { $0.saveReturns == $0.saves.count } }
        try await super.tearDown()
        fixtures.removeAll()
        try await waitUntil("Closing the video editor releases its callbacks") { self.retainedFixture == nil }
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    func testActualMuteUndoRedoAndDoneSaveTheVideoAndPhotoDraftTogether() async throws {
        var photo = PhotoEditRecipe(); photo.filter = .mono
        let (fixture, window) = try await show(photo: photo)
        try await activateAccessibilityButton(named: "Mute", in: window)
        try await waitUntil("Mute changes the real editor button") { self.searchContainsText("Unmute", in: window) }
        try await activateMenuAction("Undo", menu: "More", in: window)
        try await waitUntil("Undo restores the original audio choice") { self.searchContainsText("Mute", in: window) }
        try await activateMenuAction("Redo", menu: "More", in: window)
        try await waitUntil("Redo restores the muted draft") { self.searchContainsText("Unmute", in: window) }

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("Done saves once and closes the actual video editor") { fixture.saves.count == 1 && !fixture.isPresented }
        let value = try XCTUnwrap(fixture.saves.first)
        XCTAssertTrue(value.video.isMuted)
        XCTAssertEqual(value.photo, photo)
        XCTAssertEqual(value.live, LivePhotoEditRecipe())
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testSharedAdjustControlsReallyUpdateTheSavedVideoPhotoRecipe() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await activateAccessibilityButton(named: "Exposure", in: window)
        try await waitUntil("The actual slider is bound to Exposure before editing") {
            self.views(window).compactMap { $0 as? UISlider }.contains { $0.isEnabled && !$0.isHidden && $0.accessibilityLabel == "Exposure" }
        }
        let slider = try XCTUnwrap(views(window).compactMap { $0 as? UISlider }.first { $0.isEnabled && !$0.isHidden && $0.accessibilityLabel == "Exposure" })
        slider.sendActions(for: .touchDown)
        slider.value = slider.minimumValue + (slider.maximumValue - slider.minimumValue) * 0.8
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        try await waitUntil("The actual adjustment value is rendered before Done") { self.searchContainsText("60", in: window) }

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("The video editor saves the actual shared adjustment controls") { fixture.saves.count == 1 && !fixture.isPresented }
        XCTAssertEqual(try XCTUnwrap(fixture.saves.first).photo[.exposure], 0.6, accuracy: 0.02)
        XCTAssertTrue(try XCTUnwrap(fixture.saves.first).video.isIdentity)
    }

    func testDirtyCancelPresentsRealDiscardChoicesWithoutSavingTheDraft() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Mute", in: window)
        try await activateAccessibilityButton(named: "Cancel", in: window)
        let confirmation = try await alert(in: window)
        XCTAssertTrue(fixture.isPresented)
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(confirmation.title, "Discard Changes?")
        let discard = try XCTUnwrap(confirmation.actions.first { $0.title == "Discard Changes" })
        XCTAssertEqual(discard.style, .destructive)
        XCTAssertTrue(discard.isEnabled)
        let keep = try XCTUnwrap(confirmation.actions.first { $0.title == "Keep Editing" })
        XCTAssertEqual(keep.style, .cancel)
        XCTAssertTrue(keep.isEnabled)
        _ = try await screenshot(window)
        XCTAssertTrue(fixture.isPresented)
        XCTAssertTrue(fixture.saves.isEmpty)
        XCTAssertEqual(fixture.reverts, 0)
    }

    func testChoosingTheOriginalLiveKeyPhotoRetainsItsDefaultSelectionWhileSavingMute() async throws {
        let (fixture, window) = try await show(isLive: true)
        try await activateAccessibilityButton(named: "Make Key Photo", in: window)
        try await activateAccessibilityButton(named: "Mute", in: window)

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("The Live editor saves its real source-time selection") { fixture.saves.count == 1 && !fixture.isPresented }
        let value = try XCTUnwrap(fixture.saves.first)
        XCTAssertNil(value.live.keyPhotoTime)
        XCTAssertTrue(value.video.isMuted)
        XCTAssertEqual(value.live.mode, .live)
    }

    func testTheLiveKeyPhotoAndAdjustmentPreviewUseTheSelectedBlueSecondInsteadOfAnEarlierRedFrame() async throws {
        let (fixture, window) = try await show(isLive: true, live: LivePhotoEditRecipe(keyPhotoTime: 2.25))
        try await activateAccessibilityButton(named: "Make Key Photo", in: window)
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The actual selected key image is available to adjustment tools") {
            self.searchContainsText("Edited Photo", in: window)
        }
        let image = try await screenshot(window)
        XCTAssertGreaterThan(try dominantPixelCount(image, channel: 2), 1000,
            "The chosen 2.25s key must show the source's blue 2–3s frame, not an earlier red thumbnail")
        XCTAssertLessThan(try dominantPixelCount(image, channel: 0), 50)

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("The actual key photo preview and saved source time agree") { fixture.saves.count == 1 && !fixture.isPresented }
        XCTAssertEqual(try XCTUnwrap(fixture.saves.first).live.keyPhotoTime, 2.25)
    }

    func testRevokingAHeldSaveCancelsTheEditorAndStopsItsActualPlayer() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Play", in: window)
        try await waitUntil("The editor plays the generated movie") { self.player(in: window)?.timeControlStatus == .playing }
        let player = try XCTUnwrap(player(in: window))
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await activateAccessibilityButton(named: "Exposure", in: window)
        try await waitUntil("The actual Exposure slider is enabled before saving") {
            self.views(window).compactMap { $0 as? UISlider }.contains { $0.accessibilityLabel == "Exposure" && $0.isEnabled && !$0.isHidden }
        }
        let gate = PeopleStateGate<Bool>(); fixture.gate = gate
        try await activateAccessibilityButton(named: "Done", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        try await waitUntil("Saving disables the actual mounted slider while the callback is held") {
            let sliders = self.views(window).compactMap { $0 as? UISlider }.filter { $0.accessibilityLabel == "Exposure" && !$0.isHidden }
            return !sliders.isEmpty && sliders.allSatisfy { !$0.isEnabled }
        }
        let heldSlider = try XCTUnwrap(views(window).compactMap { $0 as? UISlider }.first { $0.accessibilityLabel == "Exposure" && !$0.isHidden })
        XCTAssertFalse(heldSlider.isEnabled)
        XCTAssertEqual(player.timeControlStatus, .paused)

        fixture.allowed = false

        try await waitUntil("Losing the captured authorization closes the actual video editor") { !fixture.isPresented }
        gate.complete(.success(true))
        try await waitUntil("The canceled late save returns through cleanup") { fixture.saveReturns == 1 }
        XCTAssertTrue(fixture.cancelledSave)
        XCTAssertNil(player.currentItem)
    }

    func testChoosingLiveOffStopsTheActualPlayingMotionBeforeSavingTheStillEffect() async throws {
        let (fixture, window) = try await show(isLive: true)
        try await activateAccessibilityButton(named: "Play", in: window)
        try await waitUntil("The Live draft actually plays") { self.player(in: window)?.timeControlStatus == .playing }
        let player = try XCTUnwrap(player(in: window))
        try await activateLiveMode("Live Off", in: window)
        try await waitUntil("Live Off stops audio and removes motion controls") {
            player.timeControlStatus == .paused && !self.searchContainsText("Play", in: window)
        }

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("The actual effect menu saves Live Off") { fixture.saves.count == 1 && !fixture.isPresented }
        XCTAssertEqual(try XCTUnwrap(fixture.saves.first).live.mode, .off)
    }

    func testRevokingTheEditorRemovesRenderedPhotoPixelsDuringDismissal() async throws {
        let (fixture, window) = try await show()
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The actual photo adjustment canvas is present") { self.searchContainsText("Edited Photo", in: window) }
        let before = try await screenshot(window)
        XCTAssertGreaterThan(try dominantPixelCount(before, channel: 0), 1000)

        fixture.allowed = false
        await Task.yield()
        let after = try await screenshot(window)

        XCTAssertLessThan(try dominantPixelCount(after, channel: 0), 50, "Authorization loss must remove media pixels during dismissal, not only after it finishes")
        XCTAssertTrue(fixture.saves.isEmpty)
    }

    func testActualFramePrecisionTrimAccessibilitySavesTheSelectedRangeWithoutChangingItsSource() async throws {
        let (fixture, window) = try await show(makeMovie: makeTrimMovie)
        let original = try Data(contentsOf: fixture.url)
        let source = AVURLAsset(url: fixture.url)
        let sourceDuration = try await source.load(.duration).seconds
        let tracks = try await source.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(fps, 30, accuracy: 0.01)
        let start = try XCTUnwrap(trimControl("Start Time", in: window))
        let oldStart = try XCTUnwrap(start.accessibilityValue)

        start.accessibilityIncrement()
        try await waitUntil("One source frame changes the actual Start Time announcement") {
            guard let value = self.trimControl("Start Time", in: window)?.accessibilityValue else { return false }
            return value != oldStart
        }
        let end = try XCTUnwrap(trimControl("End Time", in: window))
        let oldEnd = try XCTUnwrap(end.accessibilityValue)
        end.accessibilityDecrement()
        try await waitUntil("One source frame changes the actual End Time announcement") {
            guard let value = self.trimControl("End Time", in: window)?.accessibilityValue else { return false }
            return value != oldEnd
        }
        try await activateAccessibilityButton(named: "Done", in: window)
        try await waitUntil("The actual Done action saves the accessible trim selection") { fixture.saves.count == 1 && !fixture.isPresented }
        let saved = try XCTUnwrap(fixture.saves.first)
        XCTAssertEqual(saved.video.trimStart, 1 / Double(fps), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(saved.video.trimEnd), sourceDuration - 1 / Double(fps), accuracy: 0.0001)
        let output = try await MediaVideoRenderer.shared.renderVideo(sourceURL: fixture.url, video: saved.video, photo: saved.photo)
        defer { TemporaryMediaStore.remove(output) }
        let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(exportedDuration, sourceDuration - 2 / Double(fps), accuracy: 0.04)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
    }

    func testAccessiblePlaybackPositionPausesAndSelectsTheActualLiveKeyFrame() async throws {
        let (fixture, window) = try await show(isLive: true, makeMovie: makeTrimMovie)
        let source = AVURLAsset(url: fixture.url)
        let originalTime = try await MediaLiveRenderer.shared.photoTime(motionURL: fixture.url)
        let tracks = try await source.loadTracks(withMediaType: .video)
        let fps = Double(try await XCTUnwrap(tracks.first).load(.nominalFrameRate))
        let position = try XCTUnwrap(trimControl("Playback Position", in: window))
        let initialValue = try XCTUnwrap(position.accessibilityValue)

        position.accessibilityIncrement()

        try await waitUntil("One source frame updates the actual playback position announcement") {
            self.trimControl("Playback Position", in: window)?.accessibilityValue != initialValue
        }
        try await activateAccessibilityButton(named: "Make Key Photo", in: window)
        try await activateAccessibilityButton(named: "Play", in: window)
        try await waitUntil("The Live draft plays before accessible scrubbing") { self.player(in: window)?.timeControlStatus == .playing }
        try XCTUnwrap(trimControl("Playback Position", in: window)).accessibilityDecrement()
        try await waitUntil("Accessible scrubbing pauses the actual motion player") { self.player(in: window)?.timeControlStatus == .paused }

        try await activateAccessibilityButton(named: "Done", in: window)

        try await waitUntil("Done saves the frame chosen with the real adjustable control") { fixture.saves.count == 1 && !fixture.isPresented }
        XCTAssertEqual(try XCTUnwrap(fixture.saves.first?.live.keyPhotoTime), originalTime + 1 / fps, accuracy: 0.0001)
        XCTAssertTrue(try XCTUnwrap(fixture.saves.first).video.isIdentity)
    }

    private func show(isLive: Bool = false, live: LivePhotoEditRecipe = .init(), photo: PhotoEditRecipe = .init(),
                      makeMovie: @MainActor (URL) async throws -> URL = { try await makeVideoEditingFixture(in: $0) }) async throws -> (VideoEditorTestFixture, UIWindow) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-editor-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let fixture = VideoEditorTestFixture(url: try await makeMovie(directory), isLive: isLive, live: live, photo: photo)
        fixtures.append(fixture); retainedFixture = fixture
        let window = try await host(VideoEditorTestPresenter(fixture: fixture))
        if let scene = window.windowScene { window.frame = scene.effectiveGeometry.coordinateSpace.bounds }
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
        try await waitUntil("The actual generated media loads and exposes video editor tools") {
            self.searchContainsText("Adjust", in: window) && self.searchContainsText("Start Time", in: window)
                && self.player(in: window)?.currentItem?.status == .readyToPlay
        }
        return (fixture, window)
    }
    private func alert(in window: UIWindow) async throws -> UIAlertController {
        try await waitUntil("The editor presents its real confirmation") { self.searchPresentedControllers(in: window.rootViewController).contains { $0 is UIAlertController } }
        let alert = try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).compactMap { $0 as? UIAlertController }.first)
        if let transition = alert.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let scheduled = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                if !scheduled { continuation.resume() }
            }
        }
        try await waitUntil("The real confirmation has finished its native presentation") {
            !alert.isBeingPresented && alert.view.window != nil && alert.view.isUserInteractionEnabled
        }
        return alert
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func trimControl(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if object.accessibilityLabel == label, object.accessibilityTraits.contains(.adjustable) { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            for case let child as NSObject in object.accessibilityElements ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private func makeTrimMovie(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("trim-frames.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<90 {
            let deadline = Date().addingTimeInterval(4)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var raw: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &raw), kCVReturnSuccess)
            let buffer = try XCTUnwrap(raw)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), 255, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
    private func dominantPixelCount(_ image: UIImage, channel: Int) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let region = try XCTUnwrap(cg.cropping(to: CGRect(x: CGFloat(cg.width) * 0.15, y: CGFloat(cg.height) * 0.2,
            width: CGFloat(cg.width) * 0.7, height: CGFloat(cg.height) * 0.5)))
        let width = 80, height = 120
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(region, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let selected = Int(bytes[index + channel])
            let first = Int(bytes[index + (channel + 1) % 3]), second = Int(bytes[index + (channel + 2) % 3])
            if selected > 150 && selected > first + 70 && selected > second + 70 { count += 1 }
        }
        return count
    }
    private func activateLiveMode(_ title: String, in window: UIWindow) async throws {
        try await activateMenuAction(title, menu: "Live Photo Effect", in: window)
    }

    private func activateMenuAction(_ title: String, menu: String, in window: UIWindow) async throws {
        try await activateAccessibilityButton(named: menu, in: window)
        var source: (UIControl, UIAction, UIContextMenuInteraction)?
        func action(in menu: UIMenu) -> UIAction? {
            for child in menu.children {
                if let action = child as? UIAction, action.title == title { return action }
                if let nested = child as? UIMenu, let found = action(in: nested) { return found }
            }
            return nil
        }
        try await waitUntil("The actual \(menu) menu contains its enabled \(title) action") {
            for view in self.views(window) {
                for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                    interaction.updateVisibleMenu { menu in
                        if let control = interaction.view as? UIControl, let item = action(in: menu) { source = (control, item, interaction) }
                        return menu
                    }
                }
            }
            return source != nil
        }
        let (control, action, interaction) = try XCTUnwrap(source)
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(action.attributes.contains(.disabled))
        interaction.dismissMenu()
        control.sendAction(action)
    }
    private func player(in view: UIView) -> AVPlayer? {
        func find(_ layer: CALayer) -> AVPlayer? {
            if let player = (layer as? AVPlayerLayer)?.player { return player }
            return layer.sublayers?.lazy.compactMap(find).first
        }
        return find(view.layer) ?? view.subviews.lazy.compactMap { self.player(in: $0) }.first
    }
}

@MainActor @Observable
private final class VideoEditorTestFixture {
    let url: URL
    let isLive: Bool
    let live: LivePhotoEditRecipe
    let photo: PhotoEditRecipe
    var isPresented = true
    var allowed = true
    var saves: [MediaVideoEditValues] = []
    var saveReturns = 0
    var reverts = 0
    var cancelledSave = false
    var gate: PeopleStateGate<Bool>?
    init(url: URL, isLive: Bool, live: LivePhotoEditRecipe, photo: PhotoEditRecipe) {
        self.url = url; self.isLive = isLive; self.live = live; self.photo = photo
    }
    func save(_ video: VideoEditRecipe, _ live: LivePhotoEditRecipe, _ photo: PhotoEditRecipe) async -> Bool {
        saves.append(.init(video: video, live: live, photo: photo))
        let result = if let gate { (try? await gate.value()) == true } else { true }
        cancelledSave = Task.isCancelled; saveReturns += 1
        return result
    }
}

private struct VideoEditorTestPresenter: View {
    @Bindable var fixture: VideoEditorTestFixture
    var body: some View {
        Color.clear.fullScreenCover(isPresented: $fixture.isPresented) {
            MediaVideoEditor(sourceURL: fixture.url, isLivePhoto: fixture.isLive, live: fixture.live, photo: fixture.photo, isAllowed: { fixture.allowed },
                onSave: { await fixture.save($0, $1, $2) }, onRevert: { fixture.reverts += 1; return true })
        }
    }
}
