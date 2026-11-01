import AVFoundation
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class MemoryStoryPlaybackTests: SimulatorHostedTestCase {
    private var files: [URL] = []
    private var shareFiles: [URL] = []

    override func tearDown() async throws {
        try await super.tearDown()
        TemporaryMediaStore.remove(shareFiles)
        for file in files { try? FileManager.default.removeItem(at: file) }
        files.removeAll()
        shareFiles.removeAll()
    }

    func testHeldPhotoCannotFinishItsMemoryBeforeTheImageAppears() async throws {
        let session = MockSessionManager(), gate = PeopleStateGate<UIImage?>()
        defer { gate.complete(.success(nil)) }
        let loader = MemoryStoryFixtureLoader(session: session)
        loader.loadImage = { _ in try? await gate.value() }
        let presentation = MemoryStoryTestPresentation()
        let window = try await show(photo(), loader: loader, session: session, presentation: presentation)
        await fulfillment(of: [gate.started], timeout: 2)

        try await Task.sleep(for: .milliseconds(5300))
        XCTAssertTrue(presentation.isPresented, "A five-second still must not disappear while its image is held")
        gate.complete(.success(loader.preview))
        try await waitUntil("The held preview finishes loading") { loader.completedImages == 1 }
        let image = try await screenshot(window)
        XCTAssertTrue(try centerIsGreen(image), "The generated preview must actually reach the visible story")
        try await activateAccessibilityButton(named: "Close", in: window)
        try await waitUntil("The actual Close button dismisses the memory") { !presentation.isPresented }
    }

    func testHeldVideoGetsItsFullPlaybackIntervalAfterLoading() async throws {
        let movie = try await makePagerPlaybackMovie()
        files.append(movie)
        let session = MockSessionManager(), gate = PeopleStateGate<AVAsset?>()
        defer { gate.complete(.success(nil)) }
        let loader = MemoryStoryFixtureLoader(session: session)
        loader.loadVideo = { _ in try? await gate.value() }
        let presentation = MemoryStoryTestPresentation()
        let window = try await show(photo(videoDuration: 3), loader: loader, session: session, presentation: presentation)
        await fulfillment(of: [gate.started], timeout: 2)

        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertTrue(presentation.isPresented, "Waiting longer than the clip must not consume its playing interval")
        gate.complete(.success(AVURLAsset(url: movie)))
        try await waitUntil("The generated clip really starts playing") { (self.player(in: window)?.rate ?? 0) > 0 }
        XCTAssertTrue(presentation.isPresented)
        try await waitUntil("The memory closes after the complete playing interval") { !presentation.isPresented }
    }

    func testVideoPausesDuringSharePreparationItsSheetAndSceneInactivityThenResumes() async throws {
        let movie = try await makePagerPlaybackMovie()
        files.append(movie)
        let shareSource = FileManager.default.temporaryDirectory.appendingPathComponent("memory-share-\(UUID()).mov")
        try FileManager.default.copyItem(at: movie, to: shareSource)
        let shareFile = try TemporaryMediaStore.adoptShareFile(at: shareSource, suggestedFilename: shareSource.lastPathComponent)
        shareFiles.append(shareFile)
        let session = MockSessionManager(), gate = PeopleStateGate<URL?>()
        try session.setServer("https://memory-playback.example")
        defer { gate.complete(.success(nil)) }
        let loader = MemoryStoryFixtureLoader(session: session)
        loader.loadVideo = { _ in AVURLAsset(url: movie) }
        let presentation = MemoryStoryTestPresentation()
        let window = try await show(photo(videoDuration: 30), loader: loader, session: session, presentation: presentation,
            prepare: { _ in try? await gate.value() })
        try await waitUntil("The actual memory video is playing before sharing") { (self.player(in: window)?.rate ?? 0) > 0 }
        let player = try XCTUnwrap(player(in: window))

        try await activateAccessibilityButton(named: "Share", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        try await waitUntil("Preparing the share pauses actual AVPlayer playback") { player.rate == 0 }
        gate.complete(.success(shareFile))
        try await waitUntil("The actual share sheet is presented") { self.shareController(in: window.rootViewController) != nil }
        XCTAssertEqual(player.rate, 0, "The sheet must keep the same playback paused")
        let sheet = try XCTUnwrap(shareController(in: window.rootViewController))
        let close = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "photoShare.close" })
        close.sendActions(for: .touchUpInside)
        try await waitUntil("Closing the share resumes the existing memory player") {
            self.shareController(in: window.rootViewController) == nil && player.rate > 0
        }

        presentation.scenePhase = .inactive
        try await waitUntil("An inactive scene pauses the same memory player") { player.rate == 0 }
        presentation.scenePhase = .active
        try await waitUntil("Returning to the scene resumes playback") { player.rate > 0 }
        XCTAssertTrue(presentation.isPresented)
        try await activateAccessibilityButton(named: "Close", in: window)
    }

    func testReturningToAVideoReportsLoadingUntilItsNewPlayerIsReady() async throws {
        let movie = try await makePagerPlaybackMovie()
        files.append(movie)
        let session = MockSessionManager(), gate = PeopleStateGate<AVAsset?>()
        defer { gate.complete(.success(nil)) }
        let loader = MemoryStoryFixtureLoader(session: session)
        var requests = 0
        loader.loadVideo = { _ in
            requests += 1
            if requests == 1 { return AVURLAsset(url: movie) }
            return try? await gate.value()
        }
        let activity = MemoryStorySlideActivity()
        var states: [PhotoStoryMediaState] = []
        let window = try await host(MemoryStoryActiveSlide(asset: photo(videoDuration: 3), loader: loader,
            activity: activity, onMediaStateChanged: { states.append($0) }).environment(session as SessionManager))
        try await waitUntil("The initial generated movie starts") { states.last == .ready && (self.player(in: window)?.rate ?? 0) > 0 }

        activity.isActive = false
        try await waitUntil("Deactivating a video invalidates its ready state and releases its player") {
            states.last == .loading && self.player(in: window) == nil
        }
        activity.isActive = true
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(states.last, .loading, "The next visit cannot reuse the previous player's readiness")
        XCTAssertNil(player(in: window))
        gate.complete(.success(AVURLAsset(url: movie)))
        try await waitUntil("Only the second loaded player makes the revisited slide ready") {
            states.last == .ready && (self.player(in: window)?.rate ?? 0) > 0
        }
        XCTAssertEqual(requests, 2)
    }

    private func show(_ asset: AssetLite, loader: PhotoPreviewLoader, session: SessionManager,
                      presentation: MemoryStoryTestPresentation,
                      prepare: @escaping (AssetLite) async -> URL? = { _ in nil }) async throws -> UIWindow {
        let story = MemoryStory(id: UUID().uuidString, title: "Synthetic Memory", subtitle: "Generated Media", assets: [asset])
        return try await host(MemoryStoryTestPresenter(story: story, loader: loader, presentation: presentation,
            prepare: prepare).environment(session))
    }

    private func photo(videoDuration: Double? = nil) -> AssetLite {
        AssetLite(id: "device:\(UUID())", isVideo: videoDuration != nil, ratio: 1, thumbhash: nil,
            createdAt: .now, duration: videoDuration, origin: .device)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func player(in view: UIView) -> AVPlayer? {
        if let video = view as? MemoryStoryVideoView { return (video.layer as? AVPlayerLayer)?.player }
        return view.subviews.lazy.compactMap { self.player(in: $0) }.first
    }

    private func shareController(in controller: UIViewController?) -> PhotoShareViewController? {
        guard let controller else { return nil }
        if let share = controller as? PhotoShareViewController { return share }
        if let found = shareController(in: controller.presentedViewController) { return found }
        return controller.children.lazy.compactMap { self.shareController(in: $0) }.first
    }

    private func centerIsGreen(_ image: UIImage) throws -> Bool {
        let source = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2, width: source.width, height: source.height))
        }
        return pixel[1] > 180 && pixel[0] < 80 && pixel[2] < 80
    }
}

@MainActor
@Observable
private final class MemoryStoryTestPresentation {
    var isPresented = true
    var scenePhase = ScenePhase.active
}

private struct MemoryStoryTestPresenter: View {
    let story: MemoryStory
    let loader: PhotoPreviewLoader
    @Bindable var presentation: MemoryStoryTestPresentation
    let prepare: (AssetLite) async -> URL?

    var body: some View {
        Color.clear.fullScreenCover(isPresented: $presentation.isPresented) {
            MemoryStoryView(stories: [story], prepareShare: prepare, previewLoader: loader)
                .environment(\.scenePhase, presentation.scenePhase)
        }
    }
}

@MainActor
@Observable
private final class MemoryStorySlideActivity { var isActive = true }

private struct MemoryStoryActiveSlide: View {
    let asset: AssetLite
    let loader: PhotoPreviewLoader
    @Bindable var activity: MemoryStorySlideActivity
    let onMediaStateChanged: (PhotoStoryMediaState) -> Void

    var body: some View {
        MemoryStorySlide(asset: asset, isActive: activity.isActive, isPaused: false,
            previewLoader: loader, onMediaStateChanged: onMediaStateChanged)
    }
}

@MainActor
private final class MemoryStoryFixtureLoader: PhotoPreviewLoader {
    let preview = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
        UIColor.green.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
    }
    var loadImage: (String) async -> UIImage? = { _ in nil }
    var loadVideo: (String) async -> AVAsset? = { _ in nil }
    private(set) var completedImages = 0

    override func cachedImage(for assetId: String) -> UIImage? { nil }
    override func image(for assetId: String) async -> UIImage? {
        defer { completedImages += 1 }
        return await loadImage(assetId) ?? preview
    }
    override func playbackAsset(for assetId: String) async -> AVAsset? { await loadVideo(assetId) }
}
