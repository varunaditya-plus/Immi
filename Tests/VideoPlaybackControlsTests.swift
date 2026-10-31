import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class VideoPlaybackSourceTests: XCTestCase {
    func testMappedDeviceVideoFallsBackToItsCanonicalServerWithoutDownloadingICloud() async throws {
        let session = MockSessionManager()
        try session.setServer("https://video-fallback.example")
        let id = "device:selected", serverID = UUID().uuidString
        var calls: [(String, Bool)] = []
        let loader = PhotoPreviewLoader(session: session, serverIDForLocalAsset: { _ in serverID }, localPlayback: { id, network in
            calls.append((id, network)); return nil
        })
        let result = await loader.playbackAsset(for: id)
        let asset = try XCTUnwrap(result as? AVURLAsset)
        XCTAssertEqual(asset.url.path, "/api/assets/\(serverID)/video/playback")
        XCTAssertFalse(asset.url.absoluteString.contains("device:"))
        XCTAssertEqual(calls.map(\.0), [id])
        XCTAssertEqual(calls.map(\.1), [false])
    }

    func testOnlyTheSelectedDeviceOnlyVideoMayRequestItsICloudOriginal() async throws {
        let id = "device:selected", local = AVMutableComposition()
        var calls: [(String, Bool)] = []
        let loader = PhotoPreviewLoader(session: MockSessionManager(), serverIDForLocalAsset: { _ in nil }, localPlayback: { id, network in
            calls.append((id, network)); return network ? local : nil
        })
        let result = await loader.playbackAsset(for: id)
        XCTAssertTrue(result === local)
        XCTAssertEqual(calls.map(\.0), [id, id])
        XCTAssertEqual(calls.map(\.1), [false, true])
    }

    func testChangedSessionRejectsAndCancelsAHeldICloudResult() async throws {
        let session = MockSessionManager()
        try session.setServer("https://video-before.example")
        let gate = PeopleStateGate<AVAsset?>(), asset = SourceCancellationAsset(url: URL(fileURLWithPath: "/synthetic.mov"))
        defer { gate.complete(.success(nil)) }
        let loader = PhotoPreviewLoader(session: session, serverIDForLocalAsset: { _ in nil }, localPlayback: { _, network in
            network ? try? await gate.value() : nil
        })
        let request = Task { await loader.playbackAsset(for: "device:selected") }
        await fulfillment(of: [gate.started], timeout: 2)
        try session.setServer("https://video-after.example")
        gate.complete(.success(asset))
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertTrue(asset.wasCanceled)
    }

    func testAMappedSourceCannotChangeWhileItsLocalMovieIsHeld() async throws {
        let gate = PeopleStateGate<AVAsset?>(), asset = SourceCancellationAsset(url: URL(fileURLWithPath: "/synthetic.mov"))
        let mapping = PlaybackSourceMapping()
        defer { gate.complete(.success(nil)) }
        let loader = PhotoPreviewLoader(session: MockSessionManager(), serverIDForLocalAsset: { _ in mapping.id }, localPlayback: { _, _ in
            try? await gate.value()
        })
        let request = Task { await loader.playbackAsset(for: "device:selected") }
        await fulfillment(of: [gate.started], timeout: 2)
        mapping.id = UUID().uuidString
        gate.complete(.success(asset))
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertTrue(asset.wasCanceled)
    }
}

@MainActor
private final class PlaybackSourceMapping { var id = UUID().uuidString }

private final class SourceCancellationAsset: AVURLAsset, @unchecked Sendable {
    var wasCanceled = false
    override func cancelLoading() { wasCanceled = true; super.cancelLoading() }
}

@MainActor
final class VideoPlaybackControlsTests: SimulatorHostedTestCase {
    private var cells: [PhotoPagerCell] = []
    private var controllers: [PhotoPagerController] = []
    private var files: [URL] = []
    private var directories: [URL] = []
    override func tearDown() async throws {
        controllers.forEach { $0.stopAllPlayback() }
        cells.forEach { $0.stopPlayback() }
        try await super.tearDown()
        controllers.removeAll(); cells.removeAll()
        for file in files { try FileManager.default.removeItem(at: file) }
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    func testActualSliderLoadsAPausedVideoBeforePlayAndSeeksToTheChosenFrame() async throws {
        let (window, controller, cell, _) = try await show()
        let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }.first)
        XCTAssertTrue(slider.isEnabled)
        slider.sendActions(for: .touchDown)
        slider.value = 0.6
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        try await waitUntil("The pre-Play scrub creates the actual player and reaches its selected time") {
            abs(cell.playbackState.time - 1.8) < 0.12 && self.player(in: cell)?.currentItem?.status == .readyToPlay
                && abs((self.player(in: cell)?.currentTime().seconds ?? 0) - 1.8) < 0.12
        }
        XCTAssertFalse(cell.playbackState.isPlaying)
        XCTAssertEqual(player(in: cell)?.timeControlStatus, .paused)
        XCTAssertEqual(slider.accessibilityLabel, "Playback Position")
        XCTAssertTrue(slider.accessibilityValue?.contains("of") == true)
        XCTAssertTrue(descendants(window).contains { $0.accessibilityLabel == "Play" })
        controller.stopAllPlayback()
    }

    func testPrePlayControlsUseTheEditedDurationWithoutStartingTheOriginalMovie() async throws {
        var document = MediaEditDocument()
        document.kind = .video
        document.video = VideoEditRecipe(trimStart: 1, trimEnd: 2, rate: 0.5)
        let (window, _, cell, _) = try await show(displayDocument: document)
        XCTAssertEqual(cell.playbackState.duration, 2, accuracy: 0.001)
        let slider = try XCTUnwrap(descendants(window).compactMap { $0 as? UISlider }.first)
        XCTAssertTrue(slider.isEnabled)
        XCTAssertEqual(slider.accessibilityValue, "0:00 of 0:02")
        XCTAssertNil(player(in: cell))
    }

    func testDraggingPausesThePlayerCoalescesToTheLastSeekAndResumesOnlyPlayIntent() async throws {
        let (window, controller, cell, _) = try await show()
        let play = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "video.playPause" })
        play.sendActions(for: .touchUpInside)
        try await waitUntil("The generated movie actually starts") { self.player(in: cell)?.timeControlStatus == .playing }
        controller.beginScrubbing()
        XCTAssertEqual(player(in: cell)?.timeControlStatus, .paused)
        for fraction in [0.1, 0.9, 0.2, 0.8] { controller.seek(toFraction: fraction) }
        controller.endScrubbing()
        try await waitUntil("The latest target wins and playback resumes after scrubbing") {
            let time = self.player(in: cell)?.currentTime().seconds ?? 0
            return time >= 2.35 && time < 2.9 && self.player(in: cell)?.timeControlStatus == .playing
        }
        XCTAssertTrue(cell.playbackState.isPlaying)
        controller.seek(toFraction: .nan)
        XCTAssertTrue(cell.playbackState.time.isFinite)
    }

    func testHeldVideoCannotStartUnderANewSessionAndTheSameCellCanRetry() async throws {
        let (_, _, cell, loader) = try await show()
        let gate = PeopleStateGate<AVAsset?>()
        defer { gate.complete(.success(nil)) }
        loader.operation = { _ in try? await gate.value() }
        cell.togglePlayPause()
        await fulfillment(of: [gate.started], timeout: 2)
        try loader.sessionForTest.setServer("https://playback-replacement.example")
        gate.complete(.success(AVURLAsset(url: loader.movie)))
        try await waitUntil("The obsolete source finishes without installing a player") { loader.completed == 1 }
        XCTAssertNil(player(in: cell))
        XCTAssertFalse(cell.playbackState.isPlaying)
        loader.operation = { [movie = loader.movie] _ in AVURLAsset(url: movie) }
        cell.togglePlayPause()
        try await waitUntil("The current session can retry the selected video") { self.player(in: cell)?.currentItem?.status == .readyToPlay }
    }

    func testAnAudibleMovieKeepsItsActualMuteControlEnabledAndTogglesThePlayer() async throws {
        let movie = try await audibleMovie()
        let (window, _, cell, _) = try await show(sourceMovie: movie)
        let mute = try audioButton(in: window)
        XCTAssertTrue(mute.isEnabled)
        cell.togglePlayPause()
        try await waitUntil("The selected real movie reports its actual audio track") { cell.playbackState.hasAudio == true }
        let player = try XCTUnwrap(player(in: cell)), original = player.isMuted
        XCTAssertTrue(mute.isEnabled)
        mute.sendActions(for: .touchUpInside)
        XCTAssertEqual(player.isMuted, !original)
        mute.sendActions(for: .touchUpInside)
        XCTAssertEqual(player.isMuted, original)
    }

    func testAMutedEditShowsNoAudioBeforePlayAndCannotPretendToRestoreARemovedTrack() async throws {
        var document = MediaEditDocument()
        document.kind = .video
        document.video = VideoEditRecipe(rate: 2, isMuted: true)
        let movie = try await audibleMovie()
        let (window, controller, cell, _) = try await show(displayDocument: document, sourceMovie: movie)
        let mute = try audioButton(in: window)
        XCTAssertEqual(mute.accessibilityLabel, "No Audio")
        XCTAssertFalse(mute.isEnabled)
        cell.togglePlayPause()
        try await waitUntil("The real muted composition is installed") { self.player(in: cell)?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(player(in: cell)), item = try XCTUnwrap(player.currentItem)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
        let before = player.isMuted
        cell.toggleMute()
        XCTAssertEqual(player.isMuted, before)
        XCTAssertTrue(cell.playbackState.isMuted)
        XCTAssertFalse(mute.isEnabled)
        controller.stopAllPlayback()
        XCTAssertFalse(mute.isEnabled)
        XCTAssertEqual(mute.accessibilityLabel, "No Audio")
    }

    func testAnUneditedSilentMovieDisablesItsSpeakerAfterItsActualTracksLoad() async throws {
        let (window, _, cell, _) = try await show()
        let mute = try audioButton(in: window)
        cell.togglePlayPause()
        try await waitUntil("The selected silent movie finishes checking its actual tracks") { cell.playbackState.hasAudio == false }
        XCTAssertFalse(mute.isEnabled)
        XCTAssertEqual(mute.accessibilityLabel, "No Audio")
        XCTAssertTrue(cell.playbackState.isMuted)
    }

    private func audibleMovie() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audible-pager-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return try await makeVideoEditingFixture(in: directory)
    }

    private func audioButton(in window: UIWindow) throws -> UIButton {
        try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "video.mute" })
    }

    private func show(displayDocument: MediaEditDocument? = nil, sourceMovie: URL? = nil) async throws -> (UIWindow, PhotoPagerController, PhotoPagerCell, ControlsPlaybackLoader) {
        let movie: URL
        if let sourceMovie { movie = sourceMovie } else { movie = try await makePagerPlaybackMovie() }
        files.append(movie)
        let loader = ControlsPlaybackLoader(movie: movie)
        loader.displayDocument = displayDocument
        let asset = AssetLite(id: UUID().uuidString, isVideo: true, ratio: 1, thumbhash: nil, createdAt: .now, duration: 3)
        let controller = PhotoPagerController(loader: loader)
        controllers.append(controller)
        controller.apply(assets: [asset], currentAssetID: asset.id)
        let window = try await host(VStack {
            ControlsPagerHost(controller: controller)
            PhotoVideoControlsView(pager: controller).frame(height: 46)
        })
        try await waitUntil("The actual pager exposes the selected video") { self.descendants(window).contains { $0 is PhotoPagerCell } }
        let cell = try XCTUnwrap(descendants(window).compactMap { $0 as? PhotoPagerCell }.first)
        cells.append(cell)
        return (window, controller, cell, loader)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func player(in view: UIView) -> AVPlayer? {
        func find(_ layer: CALayer) -> AVPlayer? {
            if let player = (layer as? AVPlayerLayer)?.player { return player }
            return layer.sublayers?.lazy.compactMap(find).first
        }
        return find(view.layer)
    }
}

private struct ControlsPagerHost: UIViewControllerRepresentable {
    let controller: PhotoPagerController
    func makeUIViewController(context: Context) -> PhotoPagerController { controller }
    func updateUIViewController(_ controller: PhotoPagerController, context: Context) {}
}

@MainActor
private final class ControlsPlaybackLoader: PhotoPreviewLoader {
    let movie: URL
    let sessionForTest: MockSessionManager
    var operation: (String) async -> AVAsset?
    var completed = 0
    var displayDocument: MediaEditDocument?
    init(movie: URL) {
        self.movie = movie
        sessionForTest = MockSessionManager()
        operation = { _ in AVURLAsset(url: movie) }
        super.init(session: sessionForTest)
    }
    override func cachedImage(for assetId: String) -> UIImage? { UIImage(systemName: "video") }
    override func hasPreview(for assetId: String) -> Bool { true }
    override func displayAsset(_ asset: AssetLite) -> AssetLite {
        displayDocument.map { MediaEditingPipeline.displayAsset(asset, document: $0) } ?? super.displayAsset(asset)
    }
    override func isAudioRemovedByEdit(for assetID: String) -> Bool {
        displayDocument?.video.isMuted == true || super.isAudioRemovedByEdit(for: assetID)
    }
    override func playbackAsset(for assetId: String) async -> AVAsset? {
        defer { completed += 1 }
        guard let asset = await operation(assetId) else { return nil }
        guard let document = displayDocument else { return asset }
        return try? await MediaVideoRenderer.composition(source: asset, recipe: document.video)
    }
}
