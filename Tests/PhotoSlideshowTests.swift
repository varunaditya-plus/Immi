import AVFoundation
import Observation
import Photos
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoSlideshowStateTests: XCTestCase {
    private var directories: [URL] = []
    private var managers: [SwiftDataManager] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        managers.removeAll()
        for container in containers { try container.erase() }
        containers.removeAll()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testOrderStartPositionDeduplicationAndManualControlsUseTheSuppliedPhotos() {
        let a = asset(), b = asset(), c = asset()
        var duplicate = a; duplicate.isFavorite = true
        let state = PhotoSlideshowState(assets: [a, b, duplicate, c], initialAssetID: b.id)
        XCTAssertEqual(state.assets.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(state.assets.first?.isFavorite, false)
        XCTAssertEqual(state.currentAssetID, b.id)
        state.previous()
        XCTAssertEqual(state.currentAssetID, a.id)
        XCTAssertFalse(state.canMovePrevious)
        state.previous()
        XCTAssertEqual(state.currentAssetID, a.id)
        state.next()
        XCTAssertEqual(state.currentAssetID, b.id)
        state.select(c.id)
        XCTAssertEqual(state.currentAssetID, c.id)
        state.select("outside-source")
        XCTAssertEqual(state.currentAssetID, c.id)
        state.next()
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.canMoveNext)
        state.togglePlayback()
        XCTAssertEqual(state.currentAssetID, a.id)
        XCTAssertFalse(state.hasEnded)
        XCTAssertTrue(state.isPlaying)
    }

    func testPauseResumeSceneAndShareSuspensionPreserveTheRemainingIntervalAndVideoDuration() {
        let a = asset(), video = asset(video: true, duration: 12)
        let state = PhotoSlideshowState(assets: [a, video])
        ready(state)
        state.elapse(2)
        let media = state.mediaRevision
        state.togglePlayback()
        XCTAssertEqual(state.mediaRevision, media, "Pause must not restart the video renderer")
        state.elapse(100)
        state.togglePlayback()
        state.isSceneActive = false
        state.elapse(100)
        state.isSceneActive = true
        state.elapse(100, suspended: true)
        state.elapse(2.9)
        XCTAssertEqual(state.currentAssetID, a.id)
        state.elapse(0.2)
        XCTAssertEqual(state.currentAssetID, video.id)
        XCTAssertEqual(state.duration, 12)
        XCTAssertNotEqual(state.mediaRevision, media)
        ready(state)
        state.elapse(11.9)
        XCTAssertFalse(state.hasEnded)
        state.elapse(0.2)
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.currentAssetID, video.id)
        state.replay()
        XCTAssertEqual(state.currentAssetID, a.id)
        XCTAssertTrue(state.isPlaying)
    }

    func testSelectingTheSameThumbnailRestartsItsMediaAndTimerWhileInvalidDurationsCannotStallPlayback() {
        let a = asset(), b = asset()
        let state = PhotoSlideshowState(assets: [a, b])
        ready(state)
        state.elapse(4.9)
        let media = state.mediaRevision
        state.select(a.id)
        XCTAssertNotEqual(state.mediaRevision, media)
        ready(state)
        state.elapse(0.2)
        XCTAssertEqual(state.currentAssetID, a.id)
        state.elapse(4.9)
        XCTAssertEqual(state.currentAssetID, b.id)
        for duration in [nil, 0, -1, .infinity, .nan] as [Double?] {
            let state = PhotoSlideshowState(assets: [asset(video: true, duration: duration)])
            XCTAssertEqual(state.duration, 5)
            ready(state)
            for elapsed in [Double.nan, .infinity, -1] { state.elapse(elapsed) }
            XCTAssertFalse(state.hasEnded)
            state.elapse(5)
            XCTAssertTrue(state.hasEnded)
        }
    }

    func testTimelinePrivacyReconcilesToTheNextEligiblePhotoAndAccountChangesRejectTheEntireSource() throws {
        let manager = try manager(), removed = RemovedAssets()
        let a = asset(), hidden = asset(), archived = asset(), b = asset(), c = asset()
        try manager.setAssetVisibility([hidden.id], to: "locked")
        try manager.setAssetVisibility([archived.id], to: "archive")
        let state = PhotoSlideshowState(assets: [a, hidden, archived, b, c], initialAssetID: b.id,
            dataManager: manager, removed: removed)
        XCTAssertEqual(state.assets.map(\.id), [a.id, b.id, c.id])
        XCTAssertTrue(state.allowsSharing(b.id))
        XCTAssertFalse(state.allowsSharing(a.id), "Sharing belongs to the currently displayed photo")
        removed.remove([b.id])
        XCTAssertNil(state.currentAsset, "The removed photo must disappear before its replacement is reconciled")
        XCTAssertFalse(state.allowsSharing(b.id))
        state.reconcile()
        XCTAssertEqual(state.currentAssetID, c.id)
        removed.remove([c.id])
        state.reconcile()
        XCTAssertEqual(state.currentAssetID, a.id)
        LocalSnapshot.clearAll()
        state.reconcile()
        XCTAssertTrue(state.assets.isEmpty)
        XCTAssertNil(state.currentAssetID)
        XCTAssertFalse(state.isPlaying)
        state.replay()
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.allowsSharing(a.id))
    }

    func testCollectionPolicyIncludesArchivedPhotosWhileTimelinePrivacyStillExcludesThem() throws {
        let manager = try manager(), removed = RemovedAssets()
        let archived = asset(), ordinary = asset(), locked = asset()
        try manager.setAssetVisibility([archived.id], to: "archive")
        try manager.setAssetVisibility([locked.id], to: "locked")
        let source = [archived, ordinary, locked]
        let timeline = PhotoSlideshowState(assets: source, dataManager: manager, removed: removed)
        XCTAssertEqual(timeline.assets.map(\.id), [ordinary.id])
        let state = PhotoSlideshowState(assets: source, initialAssetID: archived.id,
            visibilityPolicy: AssetVisibilityPolicy(scope: .collection, dataManager: manager, removed: removed))
        XCTAssertEqual(state.assets.map(\.id), [archived.id, ordinary.id])
        XCTAssertEqual(state.currentAssetID, archived.id)
        XCTAssertTrue(state.allowsSharing(archived.id))
        state.next()
        XCTAssertEqual(state.currentAssetID, ordinary.id)
        state.previous()
        XCTAssertEqual(state.currentAssetID, archived.id)

        try manager.setAssetVisibility([archived.id], to: "locked")
        XCTAssertNil(state.currentAsset)
        XCTAssertFalse(state.allowsSharing(archived.id))
        state.reconcile()
        XCTAssertEqual(state.currentAssetID, ordinary.id)
        removed.remove([ordinary.id])
        state.reconcile()
        XCTAssertTrue(state.assets.isEmpty)
        XCTAssertNil(state.currentAssetID)
        XCTAssertFalse(state.isPlaying)
    }

    func testLoadingAndBufferingPreserveTheIntervalAndObsoleteOrStoppedMediaCannotAdvanceIt() {
        let a = asset(), b = asset()
        let state = PhotoSlideshowState(assets: [a, b])
        let first = state.mediaRevision
        state.elapse(100)
        XCTAssertEqual(state.currentAssetID, a.id)
        ready(state)
        state.elapse(2)
        state.updateMediaState(.loading, assetID: a.id, revision: first)
        state.elapse(100)
        XCTAssertEqual(state.currentAssetID, a.id)
        ready(state)
        state.elapse(3)
        XCTAssertEqual(state.currentAssetID, b.id)
        XCTAssertEqual(state.mediaState, .loading)
        state.updateMediaState(.failed, assetID: a.id, revision: first)
        XCTAssertEqual(state.currentAssetID, b.id)
        XCTAssertFalse(state.hasEnded)
        state.stop()
        state.updateMediaState(.failed, assetID: b.id, revision: state.mediaRevision)
        XCTAssertFalse(state.hasEnded)

        let failed = PhotoSlideshowState(assets: [a, b])
        failed.updateMediaState(.failed, assetID: a.id, revision: failed.mediaRevision)
        failed.elapse(100, suspended: true)
        XCTAssertEqual(failed.currentAssetID, a.id, "A failed preview must not advance or cancel a suspended share")
        failed.togglePlayback()
        failed.elapse(100)
        XCTAssertEqual(failed.currentAssetID, a.id, "A failed preview must preserve the user's Pause intent")
        failed.togglePlayback()
        failed.elapse(0.1)
        XCTAssertEqual(failed.currentAssetID, b.id, "Unavailable media must not leave the slideshow waiting forever")
        failed.updateMediaState(.failed, assetID: b.id, revision: failed.mediaRevision)
        failed.elapse(0.1)
        XCTAssertTrue(failed.hasEnded)
        XCTAssertFalse(failed.isPlaying)
    }

    private func ready(_ state: PhotoSlideshowState) {
        guard let id = state.currentAssetID else { return XCTFail("A selected slide is required") }
        state.updateMediaState(.ready, assetID: id, revision: state.mediaRevision)
    }

    private func asset(video: Bool = false, duration: Double? = nil) -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: video, ratio: 1, thumbhash: nil, createdAt: .now, duration: duration)
    }

    private func manager() throws -> SwiftDataManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-slideshow-state-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        managers.append(manager)
        containers.append(manager.modelContainer)
        return manager
    }
}

@MainActor
final class PhotoSlideshowPresentationTests: SimulatorHostedTestCase {
    private var presentations: [SlideshowTestPresentation] = []
    private var models: [PhotoSlideshowState] = []
    private var assets: [AssetLite] = []
    private var files: [URL] = []
    private weak var retainedState: PhotoSlideshowState?
    private var gates: [PeopleStateGate<URL?>] = []
    private var policyManagers: [SwiftDataManager] = []
    private var policyDirectories: [URL] = []
    private var mappings: [(localID: String, recordID: String)] = []

    override func tearDown() async throws {
        gates.forEach { $0.complete(.success(nil)) }
        presentations.forEach { $0.isPresented = false }
        try await super.tearDown()
        presentations.removeAll()
        models.removeAll()
        try await waitUntil("The dismissed slideshow releases its playback state") { self.retainedState == nil }
        for asset in assets {
            for (name, size) in [("thumbnail", 600), ("preview", 1400), ("preview", 2048)] {
                ImageMemoryCache.shared.remove(for: ImageCache.memoryKey("\(asset.id)-\(name)", size))
            }
        }
        TemporaryMediaStore.remove(files)
        assets.removeAll()
        files.removeAll()
        MockURLProtocol.reset()
        let containers = policyManagers.map(\.modelContainer)
        policyManagers.removeAll()
        for container in containers { try container.erase() }
        for directory in policyDirectories { try FileManager.default.removeItem(at: directory) }
        policyDirectories.removeAll()
        for mapping in mappings {
            let recordID = mapping.recordID
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.id == recordID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
            try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: mapping.localID)
        }
        mappings.removeAll()
    }

    func testMountedPausePreviousNextThumbnailsReplayAndCloseOperateTheActualSlideshow() async throws {
        let source = photos(3)
        let model = model(source, initialID: source[1].id)
        let (window, presentation) = try await show(source, model: model, prepare: { _ in nil })
        try await activateAccessibilityButton(named: "Pause", in: window)
        XCTAssertFalse(model.isPlaying)
        try await activateAccessibilityButton(named: "Next", in: window)
        XCTAssertEqual(model.currentAssetID, source[2].id)
        try await activateAccessibilityButton(named: "Previous", in: window)
        XCTAssertEqual(model.currentAssetID, source[1].id)
        try await activateAccessibilityButton(named: PhotoAssetAccessibility.label(for: source[0]), in: window)
        XCTAssertEqual(model.currentAssetID, source[0].id)
        try await activateAccessibilityButton(named: "Play", in: window)
        XCTAssertTrue(model.isPlaying)
        model.select(source[2].id)
        try await activateAccessibilityButton(named: "Next", in: window)
        XCTAssertTrue(model.hasEnded)
        try await activateAccessibilityButton(named: "Replay", in: window)
        XCTAssertEqual(model.currentAssetID, source[0].id)
        XCTAssertTrue(model.isPlaying)
        try await activateAccessibilityButton(named: "Close", in: window)
        try await waitUntil("Close dismisses the actual fullscreen presentation") { !presentation.isPresented }
        XCTAssertFalse(model.isPlaying)
    }

    func testShareUsesTheCurrentPhotoAndOpeningItsActualSheetPausesUntilItCloses() async throws {
        let source = photos(2), file = try shareFile()
        let model = model(source, initialID: source[1].id)
        var requested: [String] = []
        let (window, _) = try await show(source, model: model, prepare: { asset in requested.append(asset.id); return file })
        model.select(source[1].id)
        try await waitUntil("The selected still is actually ready before approaching its interval") { model.mediaState == .ready }
        model.elapse(4.8)
        try await activateAccessibilityButton(named: "Share", in: window)
        var share: PhotoShareViewController?
        try await waitUntil("The actual Photos-style share sheet is presented") {
            share = self.shareController(in: window.rootViewController)
            return share != nil
        }
        XCTAssertEqual(requested, [source[1].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.currentAssetID, source[1].id)
        XCTAssertFalse(model.hasEnded, "The share sheet must suspend the near-complete interval")
        XCTAssertTrue(model.isPlaying, "Temporary sharing must preserve the user's Play intent")
        let close = try XCTUnwrap(descendants(try XCTUnwrap(share).view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "photoShare.close" })
        XCTAssertTrue(close.window === window && close.isEnabled && !close.isHidden)
        close.sendActions(for: .touchUpInside)
        share = nil
        try await waitUntil("Closing the child share returns to the slideshow") { self.shareController(in: window.rootViewController) == nil }
        try await waitUntil("Closing the share resumes the remaining interval and reaches the end") { model.hasEnded }
        XCTAssertEqual(model.currentAssetID, source[1].id)
    }

    func testChangingSlidesCancelsAHeldShareAndDeletesItsLateFileWithoutOpeningTheWrongPhoto() async throws {
        let source = photos(2), file = try shareFile(), gate = PeopleStateGate<URL?>()
        gates.append(gate)
        let model = model(source)
        var requested: [String] = []
        let (window, _) = try await show(source, model: model, prepare: { asset in
            requested.append(asset.id)
            return try? await gate.value()
        })
        try await activateAccessibilityButton(named: "Share", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        try await activateAccessibilityButton(named: "Next", in: window)
        XCTAssertEqual(model.currentAssetID, source[1].id)
        gate.complete(.success(file))
        try await waitUntil("The abandoned share removes the file after its held operation returns") {
            !FileManager.default.fileExists(atPath: file.path)
        }
        XCTAssertEqual(requested, [source[0].id])
        XCTAssertNil(shareController(in: window.rootViewController))
        XCTAssertEqual(model.currentAssetID, source[1].id)
    }

    func testServerContextChangeDismissesEvenAPausedSlideshowWithoutWaitingForAnAccountReset() async throws {
        let session = MockSessionManager()
        try session.setServer("https://slideshow-before.example")
        let source = photos(2), model = model(source)
        let (window, presentation) = try await show(source, model: model, session: session, prepare: { _ in nil })
        try await activateAccessibilityButton(named: "Pause", in: window)
        let generation = LocalSnapshot.generation, revision = model.revision

        try session.setServer("https://slideshow-after.example")

        XCTAssertEqual(LocalSnapshot.generation, generation, "The session revision must independently invalidate the presentation")
        try await waitUntil("A changed server dismisses the actual paused slideshow") { !presentation.isPresented }
        XCTAssertFalse(model.isPlaying)
        XCTAssertNotEqual(model.revision, revision, "Dismissal must cancel the slideshow's interval")
        XCTAssertNil(shareController(in: window.rootViewController))
    }

    func testCollectionSlideshowDisplaysArchivedLocalAndServerPhotosWithTheSameFilmstripPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slideshow-archive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        policyDirectories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        policyManagers.append(manager)
        let localID = UUID().uuidString, serverID = UUID().uuidString
        let local = AssetLite(id: LocalPhotoLibrary.assetID(for: localID), isVideo: false,
            ratio: 1.5, thumbhash: nil, createdAt: .now, origin: .device)
        assets.append(local)
        let server = photos(2)
        try manager.linkDeviceAsset(localIdentifier: localID, to: serverID)
        try manager.setAssetVisibility([serverID, server[0].id], to: "archive")
        try manager.setAssetVisibility([server[1].id], to: "locked")
        let policy = AssetVisibilityPolicy(scope: .collection, dataManager: manager)
        XCTAssertFalse(AssetVisibilityPolicy(scope: .timeline, dataManager: manager).allows(id: local.id))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(local.id)-thumbnail", 600))
        let session = MockSessionManager()
        try session.setServer("https://archived-slideshow.example")
        var loaded: [String] = []
        let loader = PhotoPreviewLoader(session: session, serverIDForLocalAsset: { _ in nil }, localPreview: { id in
            loaded.append(id)
            return image
        })
        let presentation = SlideshowTestPresentation()
        presentations.append(presentation)
        let window = try await host(SlideshowTestPresenter(presentation: presentation,
            assets: [local] + server, model: nil, prepare: { _ in nil },
            visibilityPolicy: policy, previewLoader: loader, localLibrary: readableSlideshowLibrary())
            .environment(session as SessionManager))
        try await waitUntil("The archived collection's actual slideshow opens with both admitted photos") {
            self.searchContainsText("1 of 2", in: window) && loaded == [local.id]
        }
        XCTAssertTrue(presentation.isPresented)
        try await activateAccessibilityButton(named: "Pause", in: window)
        let filmstrip = try XCTUnwrap(descendants(window).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(filmstrip.numberOfItems(inSection: 0), 2,
            "The filmstrip must use the same collection policy as the slide instead of dropping archived thumbnails")
        try assertGreenImageCenter(await screenshot(window))
        try await activateAccessibilityButton(named: "Next", in: window)
        try await waitUntil("Next reaches the archived server photo") { self.searchContainsText("2 of 2", in: window) }
        try await activateAccessibilityButton(named: "Previous", in: window)
        try await waitUntil("Previous returns to the archived local photo") { self.searchContainsText("1 of 2", in: window) }
        try await activateAccessibilityButton(named: "Close", in: window)
        try await waitUntil("Close dismisses the actual archived collection slideshow") { !presentation.isPresented }
    }

    func testLocalStillRendersTheInjectedPhotoKitPreviewWithoutSendingItsDeviceIdentifierToHTTP() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseProvider = { request in
            XCTFail("A local slideshow must not request \(request.url?.path ?? "")")
            return (nil, nil, URLError(.unsupportedURL))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let session = SessionManager(urlSession: transport, restoresSession: false)
        try session.setServer("https://local-slideshow.example")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let asset = AssetLite(id: "device:\(UUID())", isVideo: false, ratio: 1.5, thumbhash: nil,
            createdAt: .now, origin: .device)
        assets.append(asset)
        ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(asset.id)-thumbnail", 600))
        var requested: [String] = []
        let loader = PhotoPreviewLoader(session: session, serverIDForLocalAsset: { _ in nil }, localPreview: { id in
            requested.append(id)
            return image
        })
        let model = model([asset])
        let window = try await host(PhotoSlideshowView(assets: [asset], session: session, prepareShare: { _ in nil },
            state: model, previewLoader: loader, localLibrary: readableSlideshowLibrary(), existingLocalIDs: { Set($0) })
            .environment(session as SessionManager).environment(\.scenePhase, .active))
        try await waitUntil("The real loader's PhotoKit branch receives only the selected local identifier") { requested == [asset.id] }
        try assertGreenImageCenter(await screenshot(window))
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testHeldLocalVideoCannotConsumeItsSlideshowIntervalBeforeRealPlaybackStarts() async throws {
        let movie = try TemporaryMediaStore.adoptShareFile(at: await makePagerPlaybackMovie(), suggestedFilename: "held-slideshow.mov")
        files.append(movie)
        let video = AssetLite(id: "device:\(UUID())", isVideo: true, ratio: 1, thumbhash: nil, createdAt: .now, duration: 3, origin: .device)
        assets.append(video)
        let following = photos(1)[0]
        let image = try XCTUnwrap(ImageMemoryCache.shared.image(for: ImageCache.memoryKey("\(following.id)-thumbnail", 600)))
        ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(video.id)-thumbnail", 600))
        let loader = SlideshowLocalPlaybackLoader(), gate = PeopleStateGate<AVAsset?>()
        defer { gate.complete(.success(nil)) }
        loader.preview = image
        loader.operation = { _ in try? await gate.value() }
        let model = model([video, following])
        let presentation = SlideshowTestPresentation()
        presentations.append(presentation)
        let session = MockSessionManager()
        try session.setServer("https://held-slideshow.example")
        _ = try await host(SlideshowTestPresenter(presentation: presentation, assets: [video, following],
            model: model, prepare: { _ in nil }, previewLoader: loader, localLibrary: readableSlideshowLibrary())
            .environment(session as SessionManager))
        await fulfillment(of: [gate.started], timeout: 2)
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertEqual(model.currentAssetID, video.id, "Waiting longer than the video's duration must not skip the unloaded clip")
        XCTAssertEqual(model.mediaState, .loading)
        XCTAssertTrue(model.isPlaying)

        gate.complete(.success(AVURLAsset(url: movie)))
        try await waitUntil("The generated movie actually starts playing") { model.mediaState == .ready }
        XCTAssertEqual(model.currentAssetID, video.id)
        try await waitUntil("Its full playing interval advances to the following photo") { model.currentAssetID == following.id }
        XCTAssertTrue(presentation.isPresented)
    }

    func testHeldPreviewCannotPublishPixelsOrReadinessAfterItsSourceOrLoaderSessionChanges() async throws {
        for invalidation in ["mapping", "session"] {
            let localID = UUID().uuidString
            try SwiftDataManager.shared.linkDeviceAsset(localIdentifier: localID, to: UUID().uuidString)
            let record = try XCTUnwrap(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID))
            mappings.append((localID, record.id))
            let asset = AssetLite(id: LocalPhotoLibrary.assetID(for: localID), isVideo: false, ratio: 1,
                thumbhash: nil, createdAt: .now, origin: .both)
            assets.append(asset)
            let old = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
                UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            }
            ImageMemoryCache.shared.insert(old, for: ImageCache.memoryKey("\(asset.id)-thumbnail", 600))
            let loaderSession = MockSessionManager()
            try loaderSession.setServer("https://held-renderer-before.example")
            let loader = SlideshowHeldPreviewLoader(session: loaderSession), gate = PeopleStateGate<UIImage?>()
            defer { gate.complete(.success(nil)) }
            var requests = 0
            loader.operation = { _ in
                requests += 1
                return requests == 1 ? try? await gate.value() : nil
            }
            let model = model([asset])
            model.togglePlayback()
            let window = try await host(PhotoSlideshowView(assets: [asset], session: loaderSession, prepareShare: { _ in nil },
                state: model, previewLoader: loader, localLibrary: readableSlideshowLibrary(), existingLocalIDs: { Set($0) })
                .environment(\.scenePhase, .active))
            await fulfillment(of: [gate.started], timeout: 2)
            if invalidation == "mapping" {
                try SwiftDataManager.shared.upsertBackupRecord(assetID: UUID().uuidString, checksum: "", localIdentifier: localID)
            } else { try loaderSession.setServer("https://held-renderer-after.example") }
            gate.complete(.success(old))
            try await waitUntil("The obsolete \(invalidation) preview completes and is rejected") {
                loader.completed == 2 && model.mediaState == .failed
            }
            XCTAssertFalse(model.isPlaying)
            let pixel = try centerPixel(await screenshot(window))
            XCTAssertLessThanOrEqual(Int(pixel[1]), max(Int(pixel[0]), Int(pixel[2])) + 40,
                "The old green bitmap must not render under a replacement \(invalidation)")
        }
    }

    func testCompletedPreviewIsHiddenAfterRemappingUntilANewBitmapArrives() async throws {
        let localID = UUID().uuidString, oldID = UUID().uuidString
        try SwiftDataManager.shared.linkDeviceAsset(localIdentifier: localID, to: oldID)
        let record = try XCTUnwrap(SwiftDataManager.shared.getBackupRecord(localIdentifier: localID))
        mappings.append((localID, record.id))
        let asset = AssetLite(id: LocalPhotoLibrary.assetID(for: localID), isVideo: false, ratio: 1,
            thumbhash: nil, createdAt: .now, origin: .both)
        assets.append(asset)
        func bitmap(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            }
        }
        let old = bitmap(.green), replacement = bitmap(.blue)
        ImageMemoryCache.shared.insert(old, for: ImageCache.memoryKey("\(asset.id)-thumbnail", 600))
        let removed = RemovedAssets(), policy = AssetVisibilityPolicy(scope: .collection, removed: removed)
        let model = model([asset], visibilityPolicy: policy)
        model.togglePlayback()
        let loaderSession = MockSessionManager()
        let loader = SlideshowHeldPreviewLoader(session: loaderSession), gate = PeopleStateGate<UIImage?>()
        defer { gate.complete(.success(nil)) }
        var requests = 0
        loader.operation = { _ in
            requests += 1
            return requests == 1 ? old : try? await gate.value()
        }
        let window = try await host(PhotoSlideshowView(assets: [asset], session: loaderSession, prepareShare: { _ in nil },
            state: model, previewLoader: loader, localLibrary: readableSlideshowLibrary(), existingLocalIDs: { Set($0) })
            .environment(\.scenePhase, .active))
        try await waitUntil("The original bitmap is installed before its source changes") { model.mediaState == .ready }
        try assertGreenImageCenter(await screenshot(window))
        loader.cached = old
        try SwiftDataManager.shared.upsertBackupRecord(assetID: UUID().uuidString, checksum: "", localIdentifier: localID)
        removed.remove([oldID])
        XCTAssertTrue(policy.allows(id: asset.id))
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(model.mediaState, .loading)
        let hidden = try centerPixel(await screenshot(window))
        XCTAssertLessThanOrEqual(Int(hidden[1]), max(Int(hidden[0]), Int(hidden[2])) + 40,
            "A cached bitmap from the old private source must not be retagged as the public replacement")
        gate.complete(.success(replacement))
        try await waitUntil("The replacement bitmap resumes the currently selected slide") { model.mediaState == .ready }
        let fresh = try centerPixel(await screenshot(window))
        XCTAssertGreaterThan(Int(fresh[2]), max(Int(fresh[0]), Int(fresh[1])) + 40)
        XCTAssertFalse(model.isPlaying)
    }

    private func assertGreenImageCenter(_ image: UIImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let pixel = try centerPixel(image)
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[0]) + 40, "The actual slide must render its allowed green preview", file: file, line: line)
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[2]) + 40, file: file, line: line)
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                width: source.width, height: source.height))
        }
        return pixel
    }

    private func photos(_ count: Int) -> [AssetLite] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        return (0..<count).map { index in
            let asset = AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1.5, thumbhash: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 86_400)))
            for (name, size) in [("thumbnail", 600), ("preview", 1400), ("preview", 2048)] {
                ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(asset.id)-\(name)", size))
            }
            assets.append(asset)
            return asset
        }
    }

    private func model(_ assets: [AssetLite], initialID: String? = nil, visibilityPolicy: AssetVisibilityPolicy? = nil) -> PhotoSlideshowState {
        let model = PhotoSlideshowState(assets: assets, initialAssetID: initialID, visibilityPolicy: visibilityPolicy)
        models.append(model)
        retainedState = model
        return model
    }

    private func show(_ assets: [AssetLite], model: PhotoSlideshowState, session supplied: MockSessionManager? = nil,
                      prepare: @escaping (AssetLite) async -> URL?) async throws -> (UIWindow, SlideshowTestPresentation) {
        let presentation = SlideshowTestPresentation()
        presentations.append(presentation)
        let session = supplied ?? MockSessionManager()
        if supplied == nil { try session.setServer("https://slideshow.example") }
        let window = try await host(SlideshowTestPresenter(presentation: presentation, assets: assets,
            model: model, prepare: prepare).environment(session as SessionManager))
        try await waitUntil("The actual slideshow controls appear") {
            self.searchContainsText("Slideshow", in: window)
        }
        return (window, presentation)
    }

    private func shareFile() throws -> URL {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.pngData())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("slideshow-\(UUID()).png")
        try data.write(to: source)
        let file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: source.lastPathComponent)
        files.append(file)
        return file
    }

    private func shareController(in controller: UIViewController?) -> PhotoShareViewController? {
        guard let controller else { return nil }
        if let share = controller as? PhotoShareViewController { return share }
        if let found = shareController(in: controller.presentedViewController) { return found }
        return controller.children.lazy.compactMap { self.shareController(in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor
@Observable
private final class SlideshowTestPresentation { var isPresented = true }

private struct SlideshowTestPresenter: View {
    @Environment(SessionManager.self) private var session
    @Bindable var presentation: SlideshowTestPresentation
    let assets: [AssetLite]
    let model: PhotoSlideshowState?
    let prepare: (AssetLite) async -> URL?
    var visibilityPolicy: AssetVisibilityPolicy? = nil
    var previewLoader: PhotoPreviewLoader? = nil
    var localLibrary: LocalPhotoLibrary? = nil
    var body: some View {
        Color.clear.fullScreenCover(isPresented: $presentation.isPresented) {
            PhotoSlideshowView(assets: assets, session: session, visibilityPolicy: visibilityPolicy, prepareShare: prepare,
                state: model, previewLoader: previewLoader, localLibrary: localLibrary, existingLocalIDs: { Set($0) })
                .environment(\.scenePhase, .active)
        }
    }
}

@MainActor
private func readableSlideshowLibrary() -> LocalPhotoLibrary {
    LocalPhotoLibrary(defaults: UserDefaults(suiteName: "slideshow-readable-\(UUID())")!,
        reader: .init(authorizationStatus: { .limited }))
}

@MainActor
final class PhotoSlideshowVideoTests: XCTestCase {
    func testChangingACompletedLocalVideosSourceReplacesItsPlayerAndRejectsTheOldEndNotification() async throws {
        let session = MockSessionManager(), notifications = NotificationCenter(), loader = SlideshowLocalPlaybackLoader()
        loader.resolvedSource = "original"
        loader.operation = { _ in AVMutableComposition() }
        var players: [SlideshowTrackingPlayer] = []
        let view = MemoryStoryVideoView(playbackNotifications: notifications, playerFactory: { item in
            let player = SlideshowTrackingPlayer(item: item)
            players.append(player)
            return player
        })
        defer { view.teardown() }
        let id = "device:\(UUID())"
        view.update(assetID: id, session: session, isActive: true, isPaused: false, localLoader: loader)
        let firstDeadline = Date().addingTimeInterval(2)
        while players.isEmpty, Date() < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let old = try XCTUnwrap(players.first), item = try XCTUnwrap(old.currentItem)
        loader.resolvedSource = "replacement"
        view.update(assetID: id, session: session, isActive: true, isPaused: true, localLoader: loader)
        let nextDeadline = Date().addingTimeInterval(2)
        while players.count < 2, Date() < nextDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(players.count, 2)
        XCTAssertNil(old.currentItem)
        let plays = old.playCount
        notifications.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertEqual(old.playCount, plays)
        XCTAssertEqual(players.last?.playCount, 0, "Rebinding must preserve Pause intent")
    }

    func testPlayerReadinessTracksActualKVOBufferingAndStopsPublishingAfterTeardown() async throws {
        let session = MockSessionManager()
        try session.setServer("https://slideshow-buffering.example")
        var player: SlideshowTrackingPlayer?
        var states: [PhotoStoryMediaState] = []
        let view = MemoryStoryVideoView(playbackNotifications: NotificationCenter(), playerFactory: { item in
            let value = SlideshowTrackingPlayer(item: item)
            player = value
            return value
        })
        view.update(assetID: "buffering-video", session: session, isActive: true, isPaused: false,
            onMediaStateChanged: { states.append($0) })
        let tracked = try XCTUnwrap(player)
        try await waitForMediaState(.ready, in: { states })
        tracked.simulateBuffering()
        try await waitForMediaState(.loading, in: { states })
        tracked.play()
        try await waitForMediaState(.ready, in: { states })
        let published = states.count
        view.teardown()
        tracked.simulateBuffering()
        tracked.play()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(states.count, published, "Removed player observations cannot publish into a dismissed slideshow")
    }

    private func waitForMediaState(_ state: PhotoStoryMediaState, in states: () -> [PhotoStoryMediaState]) async throws {
        let deadline = Date().addingTimeInterval(2)
        while states().last != state, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(states().last, state)
    }

    func testLocalPlaybackKeepsPauseIntentWhileLoadingAndRejectsItsLateResultAfterTeardown() async throws {
        let session = MockSessionManager()
        try session.setServer("https://local-slideshow-video.example")
        let loader = SlideshowLocalPlaybackLoader(), gate = PeopleStateGate<AVAsset?>()
        loader.operation = { _ in try? await gate.value() }
        var players: [SlideshowTrackingPlayer] = []
        let view = MemoryStoryVideoView(playbackNotifications: NotificationCenter(), playerFactory: { item in
            let player = SlideshowTrackingPlayer(item: item)
            players.append(player)
            return player
        })
        let id = "device:\(UUID())"
        view.update(assetID: id, session: session, isActive: true, isPaused: false, localLoader: loader)
        await fulfillment(of: [gate.started], timeout: 2)
        view.update(assetID: id, session: session, isActive: true, isPaused: true, localLoader: loader)
        let composition = AVMutableComposition()
        gate.complete(.success(composition))
        let deadline = Date().addingTimeInterval(2)
        while players.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let player = try XCTUnwrap(players.first)
        XCTAssertEqual(loader.requested, [id])
        XCTAssertTrue(player.currentItem?.asset === composition)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(player.pauseCount, 1)
        view.update(assetID: id, session: session, isActive: true, isPaused: false, localLoader: loader)
        XCTAssertEqual(player.playCount, 1)
        view.teardown()

        let late = PeopleStateGate<AVAsset?>()
        loader.operation = { _ in try? await late.value() }
        view.update(assetID: "device:\(UUID())", session: session, isActive: true, isPaused: false, localLoader: loader)
        await fulfillment(of: [late.started], timeout: 2)
        view.teardown()
        late.complete(.success(AVMutableComposition()))
        let lateDeadline = Date().addingTimeInterval(2)
        while loader.completed < 2, Date() < lateDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loader.completed, 2)
        XCTAssertEqual(players.count, 1, "A late local result must not create a player after dismissal")
        XCTAssertNil((view.layer as? AVPlayerLayer)?.player)
    }

    func testAnEndNotificationCannotUndoPauseAndResumeKeepsTheCurrentPosition() throws {
        let (view, player, notifications, session) = try fixture()
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.seekCount, 1)
        view.update(assetID: "synthetic-video", session: session, isActive: true, isPaused: true)
        XCTAssertEqual(player.pauseCount, 1)
        notifications.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.seekCount, 1)
        view.update(assetID: "synthetic-video", session: session, isActive: true, isPaused: false)
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(player.seekCount, 1, "Resuming a paused clip must not rewind it")
        notifications.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertEqual(player.playCount, 3)
        XCTAssertEqual(player.seekCount, 2)
        view.teardown()
        XCTAssertNil((view.layer as? AVPlayerLayer)?.player)
        XCTAssertNil(player.currentItem)
    }

    func testAccountChangesAndAReplacedItemRejectTheOldEndNotification() throws {
        let (view, player, notifications, _) = try fixture()
        let item = try XCTUnwrap(player.currentItem)
        LocalSnapshot.clearAll()
        notifications.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.seekCount, 1)
        view.teardown()

        let (replacementView, replacementPlayer, replacementNotifications, _) = try fixture()
        let oldItem = try XCTUnwrap(replacementPlayer.currentItem)
        replacementPlayer.replaceCurrentItem(with: nil)
        replacementNotifications.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        XCTAssertEqual(replacementPlayer.playCount, 1)
        XCTAssertEqual(replacementPlayer.seekCount, 1)
        replacementView.teardown()
    }

    private func fixture() throws -> (MemoryStoryVideoView, SlideshowTrackingPlayer, NotificationCenter, MockSessionManager) {
        let notifications = NotificationCenter(), session = MockSessionManager()
        try session.setServer("https://slideshow-video.example")
        var captured: SlideshowTrackingPlayer?
        let view = MemoryStoryVideoView(playbackNotifications: notifications, playerFactory: { item in
            let player = SlideshowTrackingPlayer(item: item)
            captured = player
            return player
        })
        view.update(assetID: "synthetic-video", session: session, isActive: true, isPaused: false)
        return (view, try XCTUnwrap(captured), notifications, session)
    }
}

private final class SlideshowTrackingPlayer: AVPlayer, @unchecked Sendable {
    private var item: AVPlayerItem?
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seekCount = 0
    private var playbackStatus = AVPlayer.TimeControlStatus.paused
    init(item: AVPlayerItem) { self.item = item; super.init() }
    override var currentItem: AVPlayerItem? { item }
    override var timeControlStatus: AVPlayer.TimeControlStatus { playbackStatus }
    override func play() { playCount += 1; setPlaybackStatus(.playing) }
    override func pause() { pauseCount += 1; setPlaybackStatus(.paused) }
    func simulateBuffering() { setPlaybackStatus(.waitingToPlayAtSpecifiedRate) }
    private func setPlaybackStatus(_ value: AVPlayer.TimeControlStatus) {
        guard playbackStatus != value else { return }
        willChangeValue(forKey: "timeControlStatus")
        playbackStatus = value
        didChangeValue(forKey: "timeControlStatus")
    }
    override func seek(to time: CMTime) { seekCount += 1 }
    override func replaceCurrentItem(with item: AVPlayerItem?) { self.item = item }
}

@MainActor
private final class SlideshowLocalPlaybackLoader: PhotoPreviewLoader {
    var preview: UIImage?
    var resolvedSource: String?
    var operation: (String) async -> AVAsset? = { _ in nil }
    private(set) var requested: [String] = []
    private(set) var completed = 0
    init() { super.init(session: MockSessionManager()) }
    override func sourceID(for assetID: String) -> String { resolvedSource ?? super.sourceID(for: assetID) }
    override func image(for assetId: String) async -> UIImage? { preview }
    override func playbackAsset(for assetId: String) async -> AVAsset? {
        requested.append(assetId)
        defer { completed += 1 }
        return await operation(assetId)
    }
}

@MainActor
private final class SlideshowHeldPreviewLoader: PhotoPreviewLoader {
    var cached: UIImage?
    var operation: (String) async -> UIImage? = { _ in nil }
    private(set) var completed = 0
    override func cachedImage(for assetId: String) -> UIImage? { cached }
    override func image(for assetId: String) async -> UIImage? {
        defer { completed += 1 }
        return await operation(assetId)
    }
}
