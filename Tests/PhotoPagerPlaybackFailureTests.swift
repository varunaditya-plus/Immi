import AVFoundation
import PhotosUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoPagerPlaybackFailureTests: XCTestCase {
    func testFailedItemStopsLoadingAndRetryCreatesAPlayableReplacement() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let failedAsset = TrackingPagerAsset(url: URL(fileURLWithPath: "/missing-pager-video.mov"))
        let loader = PlaybackFailureLoader(sources: [failedAsset, AVURLAsset(url: movieURL)])
        let notifications = PagerPlaybackNotifications()
        let cell = makeCell(loader: loader, notifications: notifications)
        let failure = try failureView(in: cell)
        let spinner = try loadingIndicator(in: cell)
        cell.togglePlayPause()

        try await waitUntil { !failure.isHidden }
        let failedItem = try XCTUnwrap(notifications.registrations.first?.item)
        XCTAssertEqual(failedItem.status, .failed, "The failure must come from a real AVPlayerItem status change")
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertFalse(cell.playbackState.isPlaying)
        XCTAssertNil(videoPlayer(in: cell))
        XCTAssertGreaterThanOrEqual(failedAsset.cancellationCount, 1)
        XCTAssertTrue(notifications.registrations.allSatisfy { notifications.removed.contains($0.token) })
        XCTAssertEqual(try failureLabel(in: cell).text, "Unable to play video. Try again.")

        try retryButton(in: cell).sendActions(for: .touchUpInside)
        try await waitUntil { self.videoPlayer(in: cell)?.timeControlStatus == .playing }
        let replacement = try XCTUnwrap(videoPlayer(in: cell))
        XCTAssertEqual(replacement.currentItem?.status, .readyToPlay)
        XCTAssertFalse(replacement.currentItem === failedItem)
        XCTAssertEqual(loader.requestedIDs, ["A", "A"])
        XCTAssertTrue(failure.isHidden)
        XCTAssertFalse(spinner.isAnimating)
        cell.stopPlayback()
        XCTAssertNil(replacement.currentItem)
    }

    func testUnavailableSourceShowsFailureAndToolbarCanRetry() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let loader = PlaybackFailureLoader(sources: [nil, AVURLAsset(url: movieURL)])
        let cell = makeCell(loader: loader)
        let failure = try failureView(in: cell)
        cell.togglePlayPause()
        try await waitUntil { !failure.isHidden }
        XCTAssertFalse(try loadingIndicator(in: cell).isAnimating)
        XCTAssertFalse(cell.playbackState.isPlaying)
        cell.togglePlayPause()
        try await waitUntil { self.videoPlayer(in: cell)?.currentItem?.status == .readyToPlay }
        XCTAssertEqual(loader.requestedIDs, ["A", "A"])
        XCTAssertTrue(failure.isHidden)
        cell.stopPlayback()
    }

    func testLongPressOnVideoPreservesLoadingWhileItsSourceIsPending() async throws {
        let loader = PlaybackFailureLoader(sources: [])
        loader.holdsPlayback = true
        let cell = makeCell(loader: loader)
        defer {
            cell.stopPlayback()
            loader.pending.forEach { $0.resume(returning: nil) }
        }
        let spinner = try loadingIndicator(in: cell)
        cell.togglePlayPause()
        try await waitUntil { loader.pending.count == 1 }
        XCTAssertTrue(spinner.isAnimating)

        hold(.began, on: cell)
        hold(.ended, on: cell)

        XCTAssertTrue(spinner.isAnimating, "Releasing a hold on a video must not hide its pending playback load")
        XCTAssertEqual(loader.returnedRequests, 0)
        XCTAssertTrue(try failureView(in: cell).isHidden)
    }

    func testQueuedFailureFromReplacedItemCannotFailTheCurrentVideo() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let loader = PlaybackFailureLoader(sources: [AVURLAsset(url: movieURL), AVURLAsset(url: movieURL)])
        let notifications = PagerPlaybackNotifications()
        let cell = makeCell(loader: loader, notifications: notifications)
        cell.togglePlayPause()
        try await waitUntil { self.videoPlayer(in: cell)?.currentItem?.status == .readyToPlay }
        let oldPlayer = try XCTUnwrap(videoPlayer(in: cell))
        let oldFailure = try XCTUnwrap(notifications.registrations.first { $0.name == .AVPlayerItemFailedToPlayToEndTime })
        cell.configure(with: asset("B"), loader: loader)
        cell.togglePlayPause()
        try await waitUntil { self.videoPlayer(in: cell)?.currentItem?.status == .readyToPlay }
        let currentPlayer = try XCTUnwrap(videoPlayer(in: cell))
        let currentFailure = try XCTUnwrap(notifications.registrations.last { $0.name == .AVPlayerItemFailedToPlayToEndTime })
        XCTAssertNil(oldPlayer.currentItem)
        XCTAssertTrue(notifications.removed.contains(oldFailure.token))

        oldFailure.deliver()
        XCTAssertTrue(videoPlayer(in: cell) === currentPlayer)
        XCTAssertTrue(try failureView(in: cell).isHidden)
        XCTAssertTrue(cell.playbackState.isPlaying)
        currentFailure.deliver()
        XCTAssertNil(currentPlayer.currentItem)
        XCTAssertFalse(try failureView(in: cell).isHidden)
        XCTAssertFalse(cell.playbackState.isPlaying)
        cell.prepareForReuse()
        XCTAssertTrue(try failureView(in: cell).isHidden)
    }

    func testCancelledSourceCannotReplaceSameAssetFromANewLoader() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let previousLoader = PlaybackFailureLoader(sources: [])
        previousLoader.holdsPlayback = true
        let cell = makeCell(loader: previousLoader)
        cell.togglePlayPause()
        try await waitUntil { previousLoader.pending.count == 1 }
        let loader = PlaybackFailureLoader(sources: [AVURLAsset(url: movieURL)])
        cell.configure(with: asset("A"), loader: loader)
        cell.togglePlayPause()
        try await waitUntil { self.videoPlayer(in: cell)?.currentItem?.status == .readyToPlay }
        let replacement = try XCTUnwrap(videoPlayer(in: cell))
        let discarded = TrackingPagerAsset(url: movieURL)
        previousLoader.pending[0].resume(returning: discarded)
        try await waitUntil { discarded.cancellationCount > 0 }
        XCTAssertTrue(videoPlayer(in: cell) === replacement)
        XCTAssertTrue(try failureView(in: cell).isHidden)
        XCTAssertGreaterThanOrEqual(discarded.cancellationCount, 1)
        cell.stopPlayback()
    }

    func testReleasedLivePhotoSourceCannotShowFailureOrStartAfterTheNextHold() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let loader = PlaybackFailureLoader(sources: [])
        loader.holdsPlayback = true
        let cell = makeCell(loader: loader, isVideo: false, motionID: "motion-A")
        hold(.began, on: cell)
        try await waitUntil { loader.pending.count == 1 }
        hold(.ended, on: cell)
        hold(.began, on: cell)
        try await waitUntil { loader.pending.count == 2 }
        loader.pending[0].resume(returning: nil)
        try await waitUntil { loader.returnedRequests == 1 }
        await fence()
        XCTAssertTrue(try loadingIndicator(in: cell).isAnimating)
        XCTAssertTrue(try failureView(in: cell).isHidden)
        loader.pending[1].resume(returning: AVURLAsset(url: movieURL))
        try await waitUntil { self.livePlayer(in: cell)?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(livePlayer(in: cell))
        hold(.ended, on: cell)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(try loadingIndicator(in: cell).isAnimating)
    }

    func testFailedLivePhotoItemShowsHoldToRetryAndUsesFreshServerFallback() async throws {
        let movieURL = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let failedAsset = TrackingPagerAsset(url: URL(fileURLWithPath: "/missing-live-photo.mov"))
        let loader = PlaybackFailureLoader(sources: [failedAsset, AVURLAsset(url: movieURL)])
        loader.nativeLivePhotoID = "native-live-photo"
        let notifications = PagerPlaybackNotifications()
        let cell = makeCell(loader: loader, notifications: notifications, isVideo: false, motionID: "motion-A")
        let failure = try failureView(in: cell)
        hold(.began, on: cell)
        try await waitUntil { !failure.isHidden }
        XCTAssertEqual(try XCTUnwrap(notifications.registrations.first?.item).status, .failed)
        let oldFailure = try XCTUnwrap(notifications.registrations.first { $0.name == .AVPlayerItemFailedToPlayToEndTime })
        XCTAssertEqual(loader.nativeRequests, 1)
        XCTAssertEqual(try failureLabel(in: cell).text, "Unable to play Live Photo. Touch and hold to try again.")
        XCTAssertFalse(failure.isUserInteractionEnabled, "The failure message must allow the next hold through to the photo")
        XCTAssertTrue(try retryButton(in: cell).isHidden)
        XCTAssertFalse(try loadingIndicator(in: cell).isAnimating)
        XCTAssertGreaterThanOrEqual(failedAsset.cancellationCount, 1)
        hold(.ended, on: cell)
        XCTAssertFalse(failure.isHidden)

        hold(.began, on: cell)
        try await waitUntil { self.livePlayer(in: cell)?.timeControlStatus == .playing }
        XCTAssertEqual(loader.nativeRequests, 2)
        XCTAssertEqual(loader.requestedIDs, ["motion-A", "motion-A"])
        XCTAssertTrue(failure.isHidden)
        let player = try XCTUnwrap(livePlayer(in: cell))
        oldFailure.deliver()
        XCTAssertTrue(livePlayer(in: cell) === player)
        XCTAssertTrue(failure.isHidden)
        let currentFailure = try XCTUnwrap(notifications.registrations.last { $0.name == .AVPlayerItemFailedToPlayToEndTime })
        currentFailure.deliver()
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(failure.isHidden)
        hold(.ended, on: cell)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(try loadingIndicator(in: cell).isAnimating)
    }

    func testUnavailableNativeLivePhotoExplainsFailureAndRetriesOnNextHold() async throws {
        let loader = PlaybackFailureLoader(sources: [])
        loader.nativeLivePhotoID = "native-live-photo"
        let cell = makeCell(loader: loader, isVideo: false)
        let failure = try failureView(in: cell)
        hold(.began, on: cell)
        try await waitUntil { !failure.isHidden }
        XCTAssertEqual(loader.nativeRequests, 1)
        XCTAssertTrue(loader.requestedIDs.isEmpty)
        XCTAssertFalse(try loadingIndicator(in: cell).isAnimating)
        hold(.ended, on: cell)
        hold(.began, on: cell)
        try await waitUntil { loader.nativeRequests == 2 }
        try await waitUntil { !failure.isHidden }
        cell.stopPlayback()
        XCTAssertTrue(try failureView(in: cell).isHidden)
    }

    private func asset(_ id: String, isVideo: Bool = true, motionID: String? = nil) -> AssetLite {
        AssetLite(id: id, isVideo: isVideo, ratio: 1, thumbhash: nil, createdAt: .distantPast, livePhotoVideoID: motionID)
    }

    private func makeCell(
        loader: PlaybackFailureLoader,
        notifications: NotificationCenter = .default,
        isVideo: Bool = true,
        motionID: String? = nil
    ) -> PhotoPagerCell {
        let cell = PhotoPagerCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844), playbackNotifications: notifications)
        cell.configure(with: asset("A", isVideo: isVideo, motionID: motionID), loader: loader)
        return cell
    }

    private func failureView(in cell: PhotoPagerCell) throws -> UIView {
        try XCTUnwrap(cell.contentView.subviews.first { $0.accessibilityIdentifier == "photoPlaybackFailure" })
    }

    private func failureLabel(in cell: PhotoPagerCell) throws -> UILabel {
        try XCTUnwrap(try failureView(in: cell).subviews.compactMap { $0 as? UILabel }.first)
    }

    private func retryButton(in cell: PhotoPagerCell) throws -> UIButton {
        try XCTUnwrap(try failureView(in: cell).subviews.compactMap { $0 as? UIButton }.first)
    }

    private func loadingIndicator(in cell: PhotoPagerCell) throws -> UIActivityIndicatorView {
        try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
    }

    private func imageView(in cell: PhotoPagerCell) -> UIImageView? {
        cell.contentView.subviews.first { $0 is UIScrollView }?.subviews.compactMap { $0 as? UIImageView }.first
    }

    private func videoPlayer(in cell: PhotoPagerCell) -> AVPlayer? {
        imageView(in: cell)?.subviews.compactMap { ($0.layer as? AVPlayerLayer)?.player }.first
    }

    private func livePlayer(in cell: PhotoPagerCell) -> AVPlayer? {
        imageView(in: cell)?.layer.sublayers?.compactMap { ($0 as? AVPlayerLayer)?.player }.first
    }

    private func hold(_ state: UIGestureRecognizer.State, on cell: PhotoPagerCell) {
        let recognizer = PagerTestHold(state: state)
        cell.perform(NSSelectorFromString("handleLongPress:"), with: recognizer)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(predicate() ? true : nil, "Condition did not become true before timeout", file: file, line: line)
    }

    private func fence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class TrackingPagerAsset: AVURLAsset, @unchecked Sendable {
    var cancellationCount = 0
    override func cancelLoading() {
        cancellationCount += 1
        super.cancelLoading()
    }
}

@MainActor
private final class PlaybackFailureLoader: PhotoPreviewLoader {
    var sources: [AVAsset?]
    var requestedIDs: [String] = []
    var holdsPlayback = false
    var pending: [CheckedContinuation<AVAsset?, Never>] = []
    var returnedRequests = 0
    var nativeLivePhotoID: String?
    var nativeRequests = 0

    init(sources: [AVAsset?]) {
        self.sources = sources
        super.init(session: MockSessionManager())
    }

    override func cachedImage(for assetId: String) -> UIImage? { nil }
    override func hasPreview(for assetId: String) -> Bool { true }
    override func localLivePhotoAssetID(for assetID: String) -> String? { nativeLivePhotoID }
    override func localLivePhoto(forLocalAssetID localID: String, targetSize: CGSize) async -> PHLivePhoto? {
        nativeRequests += 1
        return nil
    }
    override func playbackAsset(for assetId: String) async -> AVAsset? {
        requestedIDs.append(assetId)
        if holdsPlayback {
            let asset = await withCheckedContinuation { pending.append($0) }
            returnedRequests += 1
            return asset
        }
        return sources.isEmpty ? nil : sources.removeFirst()
    }
}

private final class PagerTestHold: UILongPressGestureRecognizer {
    private let testState: UIGestureRecognizer.State
    init(state: UIGestureRecognizer.State) {
        testState = state
        super.init(target: nil, action: nil)
    }
    override var state: UIGestureRecognizer.State { get { testState } set {} }
}

private final class PagerPlaybackNotifications: NotificationCenter, @unchecked Sendable {
    struct Registration {
        let token: NSObject
        let name: Notification.Name
        let item: AVPlayerItem?
        let callback: @Sendable (Notification) -> Void
        func deliver() { callback(Notification(name: name, object: item)) }
    }
    @MainActor var registrations: [Registration] = []
    @MainActor var removed: [NSObject] = []

    override func addObserver(
        forName name: Notification.Name?, object: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        MainActor.assumeIsolated {
            let token = NSObject()
            registrations.append(Registration(token: token, name: name!, item: object as? AVPlayerItem, callback: block))
            return token
        }
    }
    override func removeObserver(_ observer: Any) {
        MainActor.assumeIsolated { removed.append(observer as! NSObject) }
    }
}

@MainActor
func makePagerPlaybackMovie() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 16,
        kCVPixelBufferHeightKey as String: 16,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<3 {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        var pixelBuffer: CVPixelBuffer?
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return url
}
