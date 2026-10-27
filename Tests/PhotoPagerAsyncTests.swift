import AVFoundation
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoPagerAsyncTests: XCTestCase {
    func testQueuedEndFromOldPlayerCannotStopTheReplacementPlayer() async throws {
        let loader = HeldPreviewLoader()
        loader.cached = ["A": image(.gray), "B": image(.gray)]
        let notifications = HeldPlaybackNotifications()
        let cell = PhotoPagerCell(frame: .zero, playbackNotifications: notifications)
        cell.configure(with: video("A"), loader: loader)
        cell.togglePlayPause()
        try await waitUntil { notifications.deliveries.filter { $0.name == .AVPlayerItemDidPlayToEndTime }.count == 1 }
        let previousEnd = try XCTUnwrap(notifications.deliveries.first { $0.name == .AVPlayerItemDidPlayToEndTime })
        let previousStall = try XCTUnwrap(notifications.deliveries.first { $0.name == .AVPlayerItemPlaybackStalled })
        let previousPlayer = try videoPlayer(in: cell)

        cell.configure(with: video("B"), loader: loader)
        cell.togglePlayPause()
        try await waitUntil { notifications.deliveries.filter { $0.name == .AVPlayerItemDidPlayToEndTime }.count == 2 }
        let currentEnd = try XCTUnwrap(notifications.deliveries.last { $0.name == .AVPlayerItemDidPlayToEndTime })
        let currentStall = try XCTUnwrap(notifications.deliveries.last { $0.name == .AVPlayerItemPlaybackStalled })
        let currentPlayer = try videoPlayer(in: cell)
        XCTAssertTrue(cell.playbackState.isPlaying)
        XCTAssertTrue(notifications.removed.contains { $0 === previousEnd.token })

        var playbackReports = 0
        cell.onPlaybackChanged = { _ in playbackReports += 1 }
        previousStall.deliver()
        XCTAssertEqual(playbackReports, 0, "A queued stall from the removed item must be ignored")
        currentStall.deliver()
        XCTAssertEqual(playbackReports, 1, "The current item's stall must still update playback")
        // Removing an observer cannot retract a notification already queued on main.
        withExtendedLifetime(previousPlayer) { previousEnd.deliver() }
        XCTAssertTrue(cell.playbackState.isPlaying)
        XCTAssertTrue(try videoPlayer(in: cell) === currentPlayer)
        currentEnd.deliver()
        XCTAssertFalse(cell.playbackState.isPlaying, "The current player's end event must still work")
        cell.stopPlayback()
    }

    func testSamePhotoReconfigurationKeepsTheNewPreviewWhenOldRequestFinishes() async throws {
        let loader = HeldPreviewLoader()
        let cell = PhotoPagerCell(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        let photo = asset("A")
        cell.configure(with: photo, loader: loader)
        try await waitUntil { loader.images.count == 1 }
        cell.configure(with: photo, loader: loader)
        try await waitUntil { loader.images.count == 2 }

        let currentImage = image(.blue)
        loader.images[1].result.resolve(currentImage)
        try await waitUntil { self.displayedImage(in: cell) === currentImage }
        loader.images[0].result.resolve(image(.red))
        await loader.images[0].result.waitUntilReturned(in: self)

        XCTAssertTrue(displayedImage(in: cell) === currentImage)
        XCTAssertEqual(loader.imageCancellations, ["A"])
    }

    func testOldPreviewCannotClearTheLatestTaskHandleOrLoseItsCancellation() async throws {
        let loader = HeldPreviewLoader()
        let cell = PhotoPagerCell(frame: .zero)
        cell.configure(with: asset("A"), loader: loader)
        try await waitUntil { loader.images.count == 1 }
        cell.configure(with: asset("B"), loader: loader)
        try await waitUntil { loader.images.count == 2 }
        loader.images[0].result.resolve(image(.red))
        await loader.images[0].result.waitUntilReturned(in: self)

        cell.retryIfNeeded(loader: loader)
        await mainQueueFence()
        XCTAssertEqual(loader.images.map(\.id), ["A", "B"])

        // Cancelling the cell must still reach B's retained task after A returns.
        cell.prepareForReuse()
        loader.images[1].result.resolve(image(.blue))
        await loader.images[1].result.waitUntilReturned(in: self)
        XCTAssertEqual(loader.imageCancellations, ["A", "B"])
        XCTAssertNil(displayedImage(in: cell))

        cell.configure(with: asset("A"), loader: loader)
        try await waitUntil { loader.images.count == 3 }
        let currentImage = image(.green)
        loader.images[2].result.resolve(currentImage)
        try await waitUntil { self.displayedImage(in: cell) === currentImage }
    }

    func testReturningToSamePhotoDoesNotAcceptItsPreviousVisitPreview() async throws {
        let loader = HeldPreviewLoader()
        let cell = PhotoPagerCell(frame: .zero)
        cell.configure(with: asset("A"), loader: loader)
        try await waitUntil { loader.images.count == 1 }
        cell.configure(with: asset("B"), loader: loader)
        try await waitUntil { loader.images.count == 2 }
        cell.configure(with: asset("A"), loader: loader)
        try await waitUntil { loader.images.count == 3 }
        let currentImage = image(.green)
        loader.images[2].result.resolve(currentImage)
        try await waitUntil { self.displayedImage(in: cell) === currentImage }
        loader.images[0].result.resolve(image(.red))
        loader.images[1].result.resolve(image(.blue))
        await loader.images[0].result.waitUntilReturned(in: self)
        await loader.images[1].result.waitUntilReturned(in: self)
        XCTAssertTrue(displayedImage(in: cell) === currentImage)
    }

    func testChangedLivePhotoHintRejectsOldMatchAndAcceptsCurrentMatch() async throws {
        let loader = HeldPreviewLoader()
        loader.cached["A"] = image(.gray)
        let cell = PhotoPagerCell(frame: .zero)
        cell.configure(with: asset("A"), loader: loader)
        let badge = try liveBadge(in: cell)
        let oldHint = hint("old.jpg")
        let currentHint = hint("new.jpg")
        cell.updateLivePhotoContext(videoID: nil, localHint: oldHint, loader: loader)
        try await waitUntil { loader.matches.count == 1 }
        cell.updateLivePhotoContext(videoID: nil, localHint: currentHint, loader: loader)
        try await waitUntil { loader.matches.count == 2 }
        loader.matches[0].result.resolve("old-local-id")
        await loader.matches[0].result.waitUntilReturned(in: self)
        XCTAssertEqual(badge.alpha, 0)

        cell.updateLivePhotoContext(videoID: nil, localHint: currentHint, loader: loader)
        await mainQueueFence()
        XCTAssertEqual(loader.matches.count, 2, "The cancelled match must not clear the current task")
        loader.matches[1].result.resolve("current-local-id")
        try await waitUntil { badge.alpha == 1 }
        cell.updateLivePhotoContext(videoID: nil, localHint: nil, loader: loader)
        try await waitUntil { badge.alpha == 0 }
    }

    func testLivePhotoMatchFromPreviousVisitCannotClearCurrentDetectionTask() async throws {
        let loader = HeldPreviewLoader()
        loader.cached = ["A": image(.gray), "B": image(.gray)]
        let cell = PhotoPagerCell(frame: .zero)
        let badge = try liveBadge(in: cell)
        let matchHint = hint("same.jpg")
        cell.configure(with: asset("A"), loader: loader)
        cell.updateLivePhotoContext(videoID: nil, localHint: matchHint, loader: loader)
        try await waitUntil { loader.matches.count == 1 }
        cell.configure(with: asset("B"), loader: loader)
        cell.configure(with: asset("A"), loader: loader)
        cell.updateLivePhotoContext(videoID: nil, localHint: matchHint, loader: loader)
        try await waitUntil { loader.matches.count == 2 }
        loader.matches[0].result.resolve("previous-visit")
        await loader.matches[0].result.waitUntilReturned(in: self)
        cell.updateLivePhotoContext(videoID: nil, localHint: matchHint, loader: loader)
        await mainQueueFence()
        XCTAssertEqual(loader.matches.count, 2)
        XCTAssertEqual(badge.alpha, 0)
        loader.matches[1].result.resolve("current-visit")
        try await waitUntil { badge.alpha == 1 }
    }

    func testFilmstripCachedReplacementRejectsAnOlderSamePhotoRequest() async throws {
        let loader = HeldThumbnailLoader()
        let cell = PhotoFilmstripCell(frame: .zero)
        cell.configure(with: asset("A"), loader: loader)
        try await waitUntil { loader.requests.count == 1 }
        let currentImage = image(.blue)
        loader.cached["A"] = currentImage
        cell.configure(with: asset("A"), loader: loader)
        XCTAssertTrue(displayedImage(in: cell) === currentImage)
        loader.requests[0].resolve(image(.red))
        await loader.requests[0].waitUntilReturned(in: self)
        XCTAssertTrue(displayedImage(in: cell) === currentImage)

        cell.configure(with: asset("B"), loader: loader)
        try await waitUntil { loader.requests.count == 2 }
        let nextImage = image(.green)
        loader.requests[1].resolve(nextImage)
        try await waitUntil { self.displayedImage(in: cell) === nextImage }
    }

    func testEditedPhotoReloadInvalidatesItsTargetWithoutReconfiguringAnotherPhoto() async throws {
        let loader = HeldPreviewLoader()
        let firstImage = image(.red)
        let secondImage = image(.blue)
        loader.cached = ["A": firstImage, "B": secondImage]
        let controller = makePager(loader: loader, currentID: "B")
        let secondCell = try currentCell(in: controller, index: 1)
        XCTAssertTrue(displayedImage(in: secondCell) === secondImage)
        let reload = Task { await controller.reloadImage(for: "A") }
        try await waitUntil { loader.invalidations.count == 1 }
        XCTAssertEqual(loader.invalidations[0].id, "A")
        loader.cached["B"] = image(.green)
        loader.invalidations[0].result.resolve(())
        await reload.value
        XCTAssertTrue(displayedImage(in: secondCell) === secondImage)

        // Returning to the edited photo permits its completed edit to refresh it.
        controller.apply(assets: [asset("A"), asset("B")], currentAssetID: "A")
        controller.view.layoutIfNeeded()
        let currentImage = image(.purple)
        let currentReload = Task { await controller.reloadImage(for: "A") }
        try await waitUntil { loader.invalidations.count == 2 }
        loader.cached["A"] = currentImage
        loader.invalidations[1].result.resolve(())
        await currentReload.value
        XCTAssertTrue(displayedImage(in: try currentCell(in: controller, index: 0)) === currentImage)
    }

    func testOlderReloadCannotReplaceTheNewerReloadForTheSamePhoto() async throws {
        let loader = HeldPreviewLoader()
        loader.cached = ["A": image(.gray), "B": image(.gray)]
        let controller = makePager(loader: loader, currentID: "A")
        let first = Task { await controller.reloadImage(for: "A") }
        try await waitUntil { loader.invalidations.count == 1 }
        let second = Task { await controller.reloadImage(for: "A") }
        try await waitUntil { loader.invalidations.count == 2 }
        let currentImage = image(.blue)
        loader.cached["A"] = currentImage
        loader.invalidations[1].result.resolve(())
        await second.value
        let cell = try currentCell(in: controller, index: 0)
        XCTAssertTrue(displayedImage(in: cell) === currentImage)
        loader.cached["A"] = image(.red)
        loader.invalidations[0].result.resolve(())
        await first.value
        XCTAssertTrue(displayedImage(in: cell) === currentImage)
    }

    private func asset(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }

    private func video(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: true, ratio: 1, thumbhash: nil, createdAt: .distantPast)
    }

    private func videoPlayer(in cell: PhotoPagerCell) throws -> AVPlayer {
        let scroll = try XCTUnwrap(cell.contentView.subviews.first { $0 is UIScrollView })
        let image = try XCTUnwrap(scroll.subviews.first { $0 is UIImageView })
        return try XCTUnwrap(image.subviews.compactMap { ($0.layer as? AVPlayerLayer)?.player }.first)
    }

    private func hint(_ name: String) -> LocalLivePhotoMatchHint {
        LocalLivePhotoMatchHint(createdAt: .distantPast, pixelWidth: 10, pixelHeight: 10, originalFileName: name)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func displayedImage(in cell: UICollectionViewCell) -> UIImage? {
        let container = cell.contentView.subviews.first(where: { $0 is UIScrollView }) ?? cell.contentView
        return container.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    private func liveBadge(in cell: PhotoPagerCell) throws -> UIView {
        func containsLabel(_ view: UIView) -> Bool {
            (view as? UILabel)?.text == "LIVE" || view.subviews.contains(where: containsLabel)
        }
        return try XCTUnwrap(cell.contentView.subviews.first(where: containsLabel))
    }

    private func makePager(loader: PhotoPreviewLoader, currentID: String) -> PhotoPagerController {
        let controller = PhotoPagerController(loader: loader)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.apply(assets: [asset("A"), asset("B")], currentAssetID: currentID)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func currentCell(in controller: PhotoPagerController, index: Int) throws -> PhotoPagerCell {
        let collection = try XCTUnwrap(controller.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
        return try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)) as? PhotoPagerCell)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(predicate() ? true : nil, "Condition did not become true before timeout", file: file, line: line)
    }

    fileprivate func mainQueueFence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class HeldValue<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private let returned = XCTestExpectation(description: "held request returned")

    func get() async -> Value {
        let value = await withCheckedContinuation { continuation = $0 }
        returned.fulfill()
        return value
    }

    func resolve(_ value: Value) {
        precondition(continuation != nil, "Request must start before it is resolved")
        continuation?.resume(returning: value)
        continuation = nil
    }

    func waitUntilReturned(in test: PhotoPagerAsyncTests) async {
        await test.fulfillment(of: [returned], timeout: 2)
        await test.mainQueueFence()
    }
}

@MainActor
private final class HeldPreviewLoader: PhotoPreviewLoader {
    var cached: [String: UIImage] = [:]
    var images: [(id: String, result: HeldValue<UIImage?>)] = []
    var imageCancellations: [String] = []
    var matches: [(hint: LocalLivePhotoMatchHint, result: HeldValue<String?>)] = []
    var invalidations: [(id: String, result: HeldValue<Void>)] = []

    init() { super.init(session: MockSessionManager()) }

    override func cachedImage(for assetId: String) -> UIImage? { cached[assetId] }
    override func hasPreview(for assetId: String) -> Bool { cached[assetId] != nil }
    override func localLivePhotoAssetID(for assetID: String) -> String? { nil }
    override func prefetch(_ assetIds: [String]) {}

    override func playbackAsset(for assetId: String) async -> AVAsset? {
        AVURLAsset(url: URL(fileURLWithPath: "/nonexistent-pager-test-\(assetId).mov"))
    }

    override func image(for assetId: String) async -> UIImage? {
        let result = HeldValue<UIImage?>()
        images.append((assetId, result))
        let image = await result.get()
        if Task.isCancelled { imageCancellations.append(assetId) }
        return image
    }

    override func matchingLocalLivePhoto(for hint: LocalLivePhotoMatchHint) async -> String? {
        let result = HeldValue<String?>()
        matches.append((hint, result))
        return await result.get()
    }

    override func invalidate(_ assetId: String) async {
        let result = HeldValue<Void>()
        invalidations.append((assetId, result))
        await result.get()
    }
}

@MainActor
private final class HeldThumbnailLoader: PhotoThumbnailLoader {
    var cached: [String: UIImage] = [:]
    var requests: [HeldValue<UIImage?>] = []

    init() { super.init(session: MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { cached[assetId] }

    override func image(for assetId: String) async -> UIImage? {
        let result = HeldValue<UIImage?>()
        requests.append(result)
        return await result.get()
    }
}

private final class HeldPlaybackNotifications: NotificationCenter, @unchecked Sendable {
    struct Delivery {
        let token: NSObject
        let name: Notification.Name
        let object: Any?
        let callback: @Sendable (Notification) -> Void

        func deliver() { callback(Notification(name: name, object: object)) }
    }

    @MainActor var deliveries: [Delivery] = []
    @MainActor var removed: [AnyObject] = []

    override func addObserver(
        forName name: Notification.Name?,
        object: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        MainActor.assumeIsolated {
            let token = NSObject()
            deliveries.append(Delivery(token: token, name: name!, object: object, callback: block))
            return token
        }
    }

    override func removeObserver(_ observer: Any) {
        MainActor.assumeIsolated { removed.append(observer as AnyObject) }
    }
}
