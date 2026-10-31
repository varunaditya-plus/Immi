import AVFoundation
import Photos
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class EditedLivePlaybackTests: XCTestCase {
    private var cells: [PhotoPagerCell] = []
    private var files: [URL] = []
    override func tearDown() async throws {
        cells.forEach { $0.stopPlayback() }
        TemporaryMediaStore.remove(files)
        try await super.tearDown()
    }

    func testEditedMotionUsesItsActualItemAudioAndLoopThenReleasesItsOwnedFile() async throws {
        let file = try await movie()
        let item = AVPlayerItem(url: file)
        let loader = EditedLivePlaybackLoader(result: .movie(item, isMuted: true, loops: true, ownedURLs: [file]))
        let cell = makeCell(loader)
        hold(.began, on: cell)
        try await waitUntil { self.player(in: cell)?.timeControlStatus == .playing }
        let player = try XCTUnwrap(player(in: cell))
        XCTAssertTrue(player.currentItem === item)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(loader.originalRequests, 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitUntil { player.timeControlStatus == .playing && player.currentTime().seconds < 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        hold(.ended, on: cell)

        XCTAssertNil(player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAHeldEditedResultCannotAppearAfterItsCapturedSessionChanges() async throws {
        let file = try await movie(), gate = PeopleStateGate<EditedLivePhotoResult>()
        defer { gate.complete(.success(.unavailable)) }
        let loader = EditedLivePlaybackLoader(result: .original)
        loader.operation = { try? await gate.value() }
        let cell = makeCell(loader)
        hold(.began, on: cell)
        await fulfillment(of: [gate.started], timeout: 2)
        try loader.testSession.setServer("https://new-live-session.example")
        gate.complete(.success(.movie(AVPlayerItem(url: file), isMuted: false, loops: true, ownedURLs: [file])))

        try await waitUntil { loader.completed == 1 && !FileManager.default.fileExists(atPath: file.path) }

        XCTAssertNil(player(in: cell))
        XCTAssertEqual(loader.originalRequests, 0)
        hold(.ended, on: cell)
    }

    func testUnavailableEditedMotionShowsFailureAndNeverFallsBackToTheOriginal() async throws {
        let loader = EditedLivePlaybackLoader(result: .unavailable), cell = makeCell(loader)
        hold(.began, on: cell)
        try await waitUntil { cell.contentView.subviews.contains { $0.accessibilityIdentifier == "photoPlaybackFailure" && !$0.isHidden } }
        XCTAssertEqual(loader.originalRequests, 0)
        XCTAssertNil(player(in: cell))
    }

    func testLiveOffFinishesWithoutLoadingOriginalMotionOrShowingFailure() async throws {
        let loader = EditedLivePlaybackLoader(result: .off), cell = makeCell(loader)
        hold(.began, on: cell)
        try await waitUntil { loader.completed == 1 && !cell.contentView.subviews.compactMap { $0 as? UIActivityIndicatorView }.contains(where: \.isAnimating) }
        XCTAssertEqual(loader.originalRequests, 0)
        XCTAssertNil(player(in: cell))
        XCTAssertFalse(cell.contentView.subviews.contains { $0.accessibilityIdentifier == "photoPlaybackFailure" && !$0.isHidden })
    }

    func testBadgesDescribeTheActualSavedLiveEffectInsteadOfAlwaysSayingLive() {
        let loader = EditedLivePlaybackLoader(result: .off)
        loader.mode = .off
        let cell = makeCell(loader)
        func labels(_ view: UIView) -> [UILabel] { view.subviews.compactMap { $0 as? UILabel } + view.subviews.flatMap(labels) }
        XCTAssertTrue(labels(cell).contains { $0.text == "LIVE OFF" })
        loader.mode = .bounce
        cell.configure(with: AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil,
            createdAt: .now, livePhotoVideoID: UUID().uuidString), loader: loader)
        XCTAssertTrue(labels(cell).contains { $0.text == "BOUNCE" })
        XCTAssertFalse(labels(cell).contains { $0.text == "LIVE OFF" })
    }

    private func movie() async throws -> URL {
        let source = try await makePagerPlaybackMovie()
        defer { try? FileManager.default.removeItem(at: source) }
        let managed = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "Edited.mov")
        files.append(managed)
        return managed
    }
    private func makeCell(_ loader: EditedLivePlaybackLoader) -> PhotoPagerCell {
        let cell = PhotoPagerCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        cell.configure(with: AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: .now, livePhotoVideoID: UUID().uuidString), loader: loader)
        cells.append(cell)
        return cell
    }
    private func player(in cell: PhotoPagerCell) -> AVPlayer? {
        let image = cell.contentView.subviews.first { $0 is UIScrollView }?.subviews.compactMap { $0 as? UIImageView }.first
        return image?.layer.sublayers?.compactMap { ($0 as? AVPlayerLayer)?.player }.first
    }
    private func hold(_ state: UIGestureRecognizer.State, on cell: PhotoPagerCell) {
        cell.perform(NSSelectorFromString("handleLongPress:"), with: EditedLiveHold(state))
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

@MainActor
private final class EditedLivePlaybackLoader: PhotoPreviewLoader {
    let testSession = MockSessionManager()
    var operation: () async -> EditedLivePhotoResult?
    var completed = 0
    var originalRequests = 0
    var mode = LivePhotoEditRecipe.Mode.live
    init(result: EditedLivePhotoResult) {
        operation = { result }
        super.init(session: testSession)
    }
    override func hasPreview(for assetId: String) -> Bool { true }
    override func localLivePhotoAssetID(for assetId: String) -> String? { nil }
    override func livePhotoMode(for assetID: String) -> LivePhotoEditRecipe.Mode { mode }
    override func editedLivePhoto(for assetID: String, targetSize: CGSize) async -> EditedLivePhotoResult {
        defer { completed += 1 }
        return await operation() ?? .unavailable
    }
    override func playbackAsset(for assetId: String) async -> AVAsset? { originalRequests += 1; return nil }
}

private final class EditedLiveHold: UILongPressGestureRecognizer {
    private let delivered: UIGestureRecognizer.State
    init(_ state: UIGestureRecognizer.State) { delivered = state; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { delivered } set {} }
}
