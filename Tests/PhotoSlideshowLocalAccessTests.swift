import AVFoundation
import Observation
import Photos
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoSlideshowLocalAccessTests: SimulatorHostedTestCase {
    private var presentations: [LocalAccessSlideshowPresentation] = []
    private var states: [PhotoSlideshowState] = []
    private var accessFixtures: [SlideshowPhotoAccess] = []
    private var files: [URL] = []

    override func tearDown() async throws {
        presentations.forEach { $0.isPresented = false }
        states.forEach { $0.stop() }
        try await super.tearDown()
        TemporaryMediaStore.remove(files)
        for access in accessFixtures { UserDefaults.standard.removePersistentDomain(forName: access.suite) }
        presentations.removeAll()
        states.removeAll()
        accessFixtures.removeAll()
        files.removeAll()
    }

    func testLosingAVisibleLimitedPhotoReplacesItsLoadedPixelsWithTheNextServerPhoto() async throws {
        let local = photo(local: true), server = photo()
        let access = access(local), loader = LocalAccessSlideshowLoader()
        loader.images = [local.id: bitmap(.green), server.id: bitmap(.blue)]
        let (window, state, presentation) = try await show([local, server], access: access, loader: loader)
        try await waitUntil("The allowed device still is actually rendered") { state.mediaState == .ready }
        try assertCenter(.green, in: await screenshot(window))
        let revision = state.mediaRevision

        access.revoke(to: .limited)

        try await waitUntil("The same limited authorization removes its former readable photo") {
            state.assets.map(\.id) == [server.id] && state.currentAssetID == server.id && state.mediaState == .ready
        }
        XCTAssertEqual(access.library.authorizationStatus, .limited)
        XCTAssertEqual(access.lookups.last, [LocalPhotoLibrary.localIdentifier(from: local.id)])
        XCTAssertNotEqual(state.mediaRevision, revision)
        XCTAssertFalse(state.allowsSharing(local.id))
        XCTAssertTrue(presentation.isPresented, "The remaining authorized server photo must stay usable")
        try assertCenter(.blue, in: await screenshot(window))
    }

    func testRevokingPhotosAccessDismissesTheLastLocalVideoAndReleasesItsActualPlayer() async throws {
        let local = photo(local: true, video: true), access = access(local)
        let loader = LocalAccessSlideshowLoader()
        loader.images[local.id] = bitmap(.green)
        let movie = try TemporaryMediaStore.adoptShareFile(at: await makePagerPlaybackMovie(), suggestedFilename: "access-video.mov")
        files.append(movie)
        loader.video = { _ in AVURLAsset(url: movie) }
        let (window, state, presentation) = try await show([local], access: access, loader: loader, playing: true)
        try await waitUntil("The selected synthetic movie actually starts before access changes") {
            (self.player(in: window)?.rate ?? 0) > 0
        }
        let player = try XCTUnwrap(player(in: window)), lookups = access.lookups.count

        access.revoke(to: .denied)

        try await waitUntil("Revocation dismisses the slideshow and tears down its retained video") {
            !presentation.isPresented && player.currentItem == nil && player.rate == 0
        }
        XCTAssertTrue(state.assets.isEmpty)
        XCTAssertNil(state.currentAsset)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(access.lookups.count, lookups, "Denied permission must not trigger a Photos enumeration")
    }

    func testLimitedAccessChangeRejectsAHeldPreviewAfterTheNextSlideHasRendered() async throws {
        let local = photo(local: true), server = photo(), access = access(local)
        let loader = LocalAccessSlideshowLoader(), held = PeopleStateGate<UIImage?>()
        addTeardownBlock { held.complete(.success(nil)) }
        let old = bitmap(.green)
        loader.images[server.id] = bitmap(.blue)
        loader.image = { [weak loader] id in id == local.id ? try? await held.value() : loader?.images[id] }
        let (window, state, _) = try await show([local, server], access: access, loader: loader)
        await fulfillment(of: [held.started], timeout: 2)
        XCTAssertEqual(state.currentAssetID, local.id)
        XCTAssertEqual(state.mediaState, .loading)

        access.revoke(to: .limited)

        try await waitUntil("The server replacement renders while the obsolete local read is still held") {
            state.currentAssetID == server.id && state.mediaState == .ready
        }
        try assertCenter(.blue, in: await screenshot(window))
        held.complete(.success(old))
        try await waitUntil("The cancelled local loader has returned its late bitmap") { loader.completed.contains(local.id) }
        XCTAssertEqual(state.currentAssetID, server.id)
        XCTAssertEqual(state.mediaState, .ready)
        try assertCenter(.blue, in: await screenshot(window))
    }

    func testLimitedAccessChangeCleansAHeldShareWithoutPresentingItsLateFile() async throws {
        try await verifyShareInvalidation(held: true)
    }

    func testLimitedAccessChangeClosesAnExistingShareAndRemovesItsPreparedDeviceFile() async throws {
        try await verifyShareInvalidation(held: false)
    }

    func testMappedFallbackUsesOneServerPageAndStartsANewMediaVisitWithoutChangingPauseIntent() {
        let local = photo(local: true), server = photo(), following = photo()
        let state = PhotoSlideshowState(assets: [local, server, following])
        state.togglePlayback()
        state.updateMediaState(.ready, assetID: local.id, revision: state.mediaRevision)
        let revision = state.mediaRevision

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: false,
            existingLocalIDs: { _ in XCTFail("Denied access cannot enumerate Photos"); return [] },
            serverIDsByLocalIdentifier: [LocalPhotoLibrary.localIdentifier(from: local.id): server.id]))

        XCTAssertEqual(state.assets.map(\.id), [server.id, following.id])
        XCTAssertEqual(state.currentAssetID, server.id)
        XCTAssertEqual(state.currentAsset?.origin, .server)
        XCTAssertNotEqual(state.mediaRevision, revision)
        XCTAssertEqual(state.mediaState, .loading)
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.allowsSharing(local.id))
        XCTAssertTrue(state.allowsSharing(server.id))
    }

    func testRemovingAnotherLocalPhotoPreservesTheCurrentReadableSlidesRemainingInterval() {
        let removed = photo(local: true), current = photo(local: true), following = photo()
        let state = PhotoSlideshowState(assets: [removed, current, following], initialAssetID: current.id)
        state.updateMediaState(.ready, assetID: current.id, revision: state.mediaRevision)
        state.elapse(4.9)
        let revision = state.mediaRevision

        XCTAssertTrue(state.refreshLocalAccess(hasReadAccess: true,
            existingLocalIDs: { _ in [LocalPhotoLibrary.localIdentifier(from: current.id)] },
            serverIDsByLocalIdentifier: [:]))

        XCTAssertEqual(state.assets.map(\.id), [current.id, following.id])
        XCTAssertEqual(state.currentAssetID, current.id)
        XCTAssertEqual(state.mediaRevision, revision)
        XCTAssertEqual(state.mediaState, .ready)
        XCTAssertTrue(state.isPlaying)
        state.elapse(0.2)
        XCTAssertEqual(state.currentAssetID, following.id, "A readable slide must retain its nearly complete interval")
    }

    private func verifyShareInvalidation(held shouldHold: Bool) async throws {
        let local = photo(local: true), server = photo(), access = access(local)
        let loader = LocalAccessSlideshowLoader(), held = PeopleStateGate<URL?>()
        addTeardownBlock { held.complete(.success(nil)) }
        loader.images = [local.id: bitmap(.green), server.id: bitmap(.blue)]
        let file = try managedPhoto()
        let (window, state, _) = try await show([local, server], access: access, loader: loader, prepare: { asset in
            XCTAssertEqual(asset.id, local.id)
            return shouldHold ? try? await held.value() : file
        })
        try await waitUntil("The local photo is ready before sharing") { state.mediaState == .ready }
        try await activateAccessibilityButton(named: "Share", in: window)
        if shouldHold {
            await fulfillment(of: [held.started], timeout: 2)
            XCTAssertNil(shareController(in: window.rootViewController))
        } else {
            try await waitUntil("The real share controller owns the selected local file") {
                self.shareController(in: window.rootViewController) != nil
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        access.revoke(to: .limited)

        try await waitUntil("Revocation replaces the local photo before the held share is released") {
            state.currentAssetID == server.id && !state.allowsSharing(local.id)
        }
        if shouldHold { held.complete(.success(file)) }
        try await waitUntil("The obsolete local share is closed and its file is removed") {
            self.shareController(in: window.rootViewController) == nil && !FileManager.default.fileExists(atPath: file.path)
        }
        XCTAssertEqual(state.assets.map(\.id), [server.id])
        try await waitUntil("The authorized replacement remains available after sharing cleanup") { state.mediaState == .ready }
        try assertCenter(.blue, in: await screenshot(window))
    }

    private func show(_ assets: [AssetLite], access: SlideshowPhotoAccess, loader: LocalAccessSlideshowLoader,
                      playing: Bool = false, prepare: @escaping (AssetLite) async -> URL? = { _ in nil }) async throws
        -> (UIWindow, PhotoSlideshowState, LocalAccessSlideshowPresentation) {
        let state = PhotoSlideshowState(assets: assets), presentation = LocalAccessSlideshowPresentation()
        if !playing { state.togglePlayback() }
        states.append(state)
        presentations.append(presentation)
        let window = try await host(LocalAccessSlideshowPresenter(state: state, presentation: presentation,
            access: access, loader: loader, prepare: prepare).environment(loader.session as SessionManager))
        try await waitUntil("The actual slideshow is mounted") { self.searchContainsText("Slideshow", in: window) }
        return (window, state, presentation)
    }

    private func access(_ asset: AssetLite) -> SlideshowPhotoAccess {
        let access = SlideshowPhotoAccess(readable: [LocalPhotoLibrary.localIdentifier(from: asset.id)])
        accessFixtures.append(access)
        return access
    }

    private func photo(local: Bool = false, video: Bool = false) -> AssetLite {
        let id = UUID().uuidString
        return AssetLite(id: local ? LocalPhotoLibrary.assetID(for: id) : id, isVideo: video,
            ratio: 1.5, thumbhash: nil, createdAt: .now, duration: video ? 30 : nil, origin: local ? .device : .server)
    }

    private func bitmap(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    private func managedPhoto() throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("slideshow-access-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: source) }
        try XCTUnwrap(bitmap(.green).pngData()).write(to: source)
        let file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "Selected Photo.png")
        files.append(file)
        return file
    }

    private func assertCenter(_ color: UIColor, in image: UIImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                width: source.width, height: source.height))
        }
        let dominant = color == .green ? 1 : 2
        for channel in 0..<3 where channel != dominant {
            XCTAssertGreaterThan(Int(pixel[dominant]), Int(pixel[channel]) + 40,
                "The authorized \(color == .green ? "green" : "blue") image must occupy the actual slide center", file: file, line: line)
        }
    }

    private func player(in view: UIView) -> AVPlayer? {
        (view.layer as? AVPlayerLayer)?.player ?? view.subviews.lazy.compactMap { self.player(in: $0) }.first
    }

    private func shareController(in controller: UIViewController?) -> PhotoShareViewController? {
        guard let controller else { return nil }
        if let share = controller as? PhotoShareViewController { return share }
        return shareController(in: controller.presentedViewController)
            ?? controller.children.lazy.compactMap { self.shareController(in: $0) }.first
    }
}

@MainActor
private final class SlideshowPhotoAccess {
    let suite = "slideshow-access-\(UUID())"
    private var status = PHAuthorizationStatus.limited
    private var readable: Set<String>
    private(set) var lookups: [[String]] = []
    lazy var library = LocalPhotoLibrary(defaults: UserDefaults(suiteName: suite)!,
        reader: .init(authorizationStatus: { [weak self] in self?.status ?? .denied }))

    init(readable: Set<String>) { self.readable = readable }

    func existing(_ ids: [String]) -> Set<String> {
        lookups.append(ids)
        return Set(ids).intersection(readable)
    }

    func revoke(to status: PHAuthorizationStatus) {
        self.status = status
        readable = []
        library.libraryDidChange()
    }
}

@MainActor
@Observable
private final class LocalAccessSlideshowPresentation { var isPresented = true }

private struct LocalAccessSlideshowPresenter: View {
    let state: PhotoSlideshowState
    @Bindable var presentation: LocalAccessSlideshowPresentation
    let access: SlideshowPhotoAccess
    let loader: LocalAccessSlideshowLoader
    let prepare: (AssetLite) async -> URL?

    var body: some View {
        Color.purple.fullScreenCover(isPresented: $presentation.isPresented) {
            PhotoSlideshowView(assets: state.assets, session: loader.session, prepareShare: prepare,
                state: state, previewLoader: loader, localLibrary: access.library, existingLocalIDs: { access.existing($0) })
                .environment(\.scenePhase, .active)
        }
    }
}

@MainActor
private final class LocalAccessSlideshowLoader: PhotoPreviewLoader {
    let session: MockSessionManager
    var images: [String: UIImage] = [:]
    var image: ((String) async -> UIImage?)?
    var video: (String) async -> AVAsset? = { _ in nil }
    private(set) var completed: [String] = []

    init() {
        let session = MockSessionManager()
        self.session = session
        super.init(session: session)
    }
    override func cachedImage(for assetId: String) -> UIImage? { images[assetId] }
    override func image(for assetId: String) async -> UIImage? {
        defer { completed.append(assetId) }
        return if let image { await image(assetId) } else { images[assetId] }
    }
    override func playbackAsset(for assetId: String) async -> AVAsset? { await video(assetId) }
}
