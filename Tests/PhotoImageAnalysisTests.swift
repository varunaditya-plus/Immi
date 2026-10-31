import SwiftUI
import SwiftData
import UIKit
import VisionKit
import XCTest
@testable import ImmichApp

@MainActor
final class PhotoImageAnalysisRequestTests: XCTestCase {
    func testReplacementAndCancellationRejectHeldResultsWithoutLosingTheNewTasksCancellation() async throws {
        let request = PhotoImageAnalysisRequest<String>()
        let old = PeopleStateGate<String>(), current = PeopleStateGate<String>()
        var received: [String] = [], currentWasCancelled = false
        let first = try XCTUnwrap(request.start(operation: { try await old.value() },
            isAllowed: { true }, onReady: { received.append($0) }))
        await fulfillment(of: [old.started], timeout: 2)
        let second = try XCTUnwrap(request.start(operation: {
            let value = try await current.value()
            currentWasCancelled = Task.isCancelled
            return value
        }, isAllowed: { true }, onReady: { received.append($0) }))
        await fulfillment(of: [current.started], timeout: 2)

        old.complete(.success("old visit"))
        await first.value
        XCTAssertTrue(received.isEmpty)
        request.cancel()
        current.complete(.success("cancelled visit"))
        await second.value

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(currentWasCancelled, "A late old completion must not discard the current task's cancellation handle")
        let retry = try XCTUnwrap(request.start(operation: { "current visit" },
            isAllowed: { true }, onReady: { received.append($0) }))
        await retry.value
        XCTAssertEqual(received, ["current visit"])
    }

    func testPermissionLossRejectsAHeldResultAndAnIneligibleRequestNeverAnalyzes() async throws {
        let request = PhotoImageAnalysisRequest<String>(), gate = PeopleStateGate<String>()
        var allowed = true, received: [String] = []
        let pending = try XCTUnwrap(request.start(operation: { try await gate.value() },
            isAllowed: { allowed }, onReady: { received.append($0) }))
        await fulfillment(of: [gate.started], timeout: 2)
        allowed = false
        gate.complete(.success("private result"))
        await pending.value
        XCTAssertTrue(received.isEmpty)
        XCTAssertNil(request.start(operation: {
            XCTFail("An unauthorized image must not reach the analyzer")
            return "private"
        }, isAllowed: { allowed }, onReady: { received.append($0) }))
    }

    func testAnalysisFailureDoesNotPublishAndTheSameRequestCanRetry() async throws {
        let request = PhotoImageAnalysisRequest<String>()
        var received: [String] = []
        let failed = try XCTUnwrap(request.start(operation: { throw URLError(.cannotDecodeContentData) },
            isAllowed: { true }, onReady: { received.append($0) }))
        await failed.value
        XCTAssertTrue(received.isEmpty)
        let retry = try XCTUnwrap(request.start(operation: { "usable result" },
            isAllowed: { true }, onReady: { received.append($0) }))
        await retry.value
        XCTAssertEqual(received, ["usable result"])
    }
}

@MainActor
final class PhotoImageAnalysisPresentationTests: SimulatorHostedTestCase {
    private var analyzers: [HeldPhotoImageAnalyzer] = []
    private var cells: [PhotoPagerCell] = []
    private var controllers: [PhotoPagerController] = []
    private weak var retainedCell: PhotoPagerCell?
    private weak var retainedController: PhotoPagerController?
    private var mappings: [(recordID: String, localID: String)] = []

    override func tearDown() async throws {
        cells.forEach { $0.prepareForReuse() }
        controllers.forEach { $0.stopImageAnalysis() }
        analyzers.forEach { $0.finishAll() }
        try await waitUntil("All held analysis operations finish before the fixture is released") {
            self.analyzers.allSatisfy { $0.activeCount == 0 }
        }
        try await super.tearDown()
        cells.removeAll()
        controllers.removeAll()
        analyzers.removeAll()
        try await waitUntil("The closed pager releases its cell and controller") {
            self.retainedCell == nil && self.retainedController == nil
        }
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

    func testSystemCapabilityUsesTheActualPlatformGate() async throws {
        let loader = AnalysisPreviewLoader()
        let asset = photo()
        loader.cached[asset.id] = image(.green)
        let cell = PhotoPagerCell(frame: .zero)
        track(cell)
        try await host(AnalysisCellHost(cell: cell))
        cell.configure(with: asset, loader: loader)
        cell.setImageAnalysisActive(true)

        XCTAssertEqual(interactions(in: cell).count, ImageAnalyzer.isSupported ? 1 : 0)
        if !ImageAnalyzer.isSupported {
            XCTAssertFalse(try imageView(in: cell).isUserInteractionEnabled)
        }
    }

    func testOnlyTheActiveStillInstallsTheNativeInteractionAndPreservesImageOrientationAndZoom() async throws {
        let analyzer = analyzer(), loader = AnalysisPreviewLoader()
        let cell = PhotoPagerCell(frame: .zero)
        cell.setImageAnalyzer(analyzer)
        track(cell)
        try await host(AnalysisCellHost(cell: cell))
        let asset = photo()
        let source = image(.green)
        let oriented = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 2, orientation: .rightMirrored)
        loader.cached[asset.id] = oriented
        cell.configure(with: asset, loader: loader)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertTrue(analyzer.images.isEmpty)

        cell.setImageAnalysisActive(true)

        try await waitUntil("The displayed still reaches the injected analyzer") { analyzer.images.count == 1 }
        XCTAssertTrue(analyzer.images.first === oriented)
        XCTAssertEqual(analyzer.images.first?.imageOrientation, .rightMirrored)
        let view = try imageView(in: cell)
        let interaction = try XCTUnwrap(interactions(in: cell).first)
        XCTAssertTrue(interaction.view === view)
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertEqual(interaction.preferredInteractionTypes, [.textSelection, .dataDetectors, .imageSubject, .visualLookUp])
        let scroll = try XCTUnwrap(view.superview as? UIScrollView)
        scroll.setZoomScale(2, animated: false)
        cell.scrollViewDidZoom(scroll)
        XCTAssertTrue(interaction.view === view)
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        cell.setImageAnalysisActive(false)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertNil(interaction.analysis)
        XCTAssertEqual(interaction.preferredInteractionTypes, [])
        XCTAssertFalse(view.isUserInteractionEnabled)
    }

    func testVideoLivePhotoAndPlaceholderDoNotStartAnalysisAndLateLiveContextClearsIt() async throws {
        let analyzer = analyzer(), loader = AnalysisPreviewLoader()
        let cell = PhotoPagerCell(frame: .zero)
        cell.setImageAnalyzer(analyzer)
        track(cell)
        try await host(AnalysisCellHost(cell: cell))
        var video = photo(); video = AssetLite(id: video.id, isVideo: true, ratio: 1, thumbhash: nil, createdAt: .now)
        var live = photo(); live.livePhotoVideoID = UUID().uuidString
        for asset in [video, live] {
            loader.cached[asset.id] = image(.green)
            cell.configure(with: asset, loader: loader)
            cell.setImageAnalysisActive(true)
            XCTAssertTrue(interactions(in: cell).isEmpty)
        }
        let placeholder = photo()
        cell.configure(with: placeholder, loader: loader)
        cell.setImageAnalysisActive(true)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertTrue(analyzer.images.isEmpty)

        let still = photo()
        loader.cached[still.id] = image(.blue)
        cell.configure(with: still, loader: loader)
        try await waitUntil("The authorized ordinary still begins analysis") { analyzer.images.count == 1 }
        cell.updateLivePhotoContext(videoID: UUID().uuidString, localHint: nil, loader: loader)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        analyzer.finishAll()
        try await waitUntil("The cancelled still analysis returns") { analyzer.activeCount == 0 }
        XCTAssertEqual(analyzer.cancelledCount, 1)
    }

    func testPrivacyAndAccountChangesRemoveTheInteractionWithoutWaitingForAnalysis() async throws {
        for invalidation in ["privacy", "account"] {
            let analyzer = analyzer(), loader = AnalysisPreviewLoader(), removed = RemovedAssets()
            loader.visibilityPolicy = AssetVisibilityPolicy(removed: removed)
            let cell = PhotoPagerCell(frame: .zero)
            cell.setImageAnalyzer(analyzer)
            track(cell)
            try await host(AnalysisCellHost(cell: cell))
            let asset = photo()
            loader.cached[asset.id] = image(.green)
            cell.configure(with: asset, loader: loader)
            cell.setImageAnalysisActive(true)
            try await waitUntil("The visible image starts one held analysis") { analyzer.images.count == 1 }
            XCTAssertEqual(interactions(in: cell).count, 1)

            if invalidation == "privacy" { removed.remove([asset.id]) }
            else { LocalSnapshot.clearAll() }

            try await waitUntil("The interaction clears immediately after \(invalidation) changes") {
                self.interactions(in: cell).isEmpty
            }
            analyzer.finishAll()
            try await waitUntil("The revoked request returns without restoring an interaction") { analyzer.activeCount == 0 }
            XCTAssertEqual(analyzer.cancelledCount, 1)
            XCTAssertTrue(interactions(in: cell).isEmpty)
        }
    }

    func testReplacingTheImageAndReusingTheCellCancelThePreviousAnalysis() async throws {
        let analyzer = analyzer(), loader = AnalysisPreviewLoader(), asset = photo()
        let cell = PhotoPagerCell(frame: .zero)
        cell.setImageAnalyzer(analyzer)
        track(cell)
        try await host(AnalysisCellHost(cell: cell))
        let first = image(.red), second = image(.blue)
        loader.cached[asset.id] = first
        cell.configure(with: asset, loader: loader)
        cell.setImageAnalysisActive(true)
        try await waitUntil("The first image request starts") { analyzer.images.count == 1 }
        loader.cached[asset.id] = second
        cell.configure(with: asset, loader: loader)
        try await waitUntil("An edited preview starts a distinct request") { analyzer.images.count == 2 }
        XCTAssertTrue(analyzer.images[1] === second)
        cell.prepareForReuse()
        analyzer.finishAll()
        try await waitUntil("Both abandoned image requests return") { analyzer.activeCount == 0 }
        XCTAssertEqual(analyzer.cancelledCount, 2)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertNil(try imageView(in: cell).image)
    }

    func testRemappingAnAliasClearsHeldAndCompletedInteractionsWithoutAuthorizingTheSameOldBitmapAgain() async throws {
        for completed in [false, true] {
            let localID = UUID().uuidString, oldID = UUID().uuidString, newID = UUID().uuidString
            try link(localID, to: oldID)
            let asset = AssetLite(id: LocalPhotoLibrary.assetID(for: localID), isVideo: false, ratio: 1,
                thumbhash: nil, createdAt: .now, origin: .both)
            let analyzer = analyzer(), loader = AnalysisPreviewLoader(), removed = RemovedAssets()
            loader.visibilityPolicy = AssetVisibilityPolicy(scope: .collection, removed: removed)
            let oldImage = image(.red), replacementImage = image(.blue)
            loader.cached[asset.id] = oldImage
            let cell = PhotoPagerCell(frame: .zero)
            cell.setImageAnalyzer(analyzer)
            track(cell)
            let window = try await host(AnalysisCellHost(cell: cell))
            cell.configure(with: asset, loader: loader)
            cell.setImageAnalysisActive(true)
            try await waitUntil("The original mapped bitmap reaches the analyzer") { analyzer.images.count == 1 }
            if completed {
                analyzer.finishAll()
                try await waitUntil("The analysis request finishes while its native interaction stays mounted") { analyzer.activeCount == 0 }
            }
            XCTAssertEqual(interactions(in: cell).count, 1)

            try SwiftDataManager.shared.upsertBackupRecord(assetID: newID, checksum: "", localIdentifier: localID)
            removed.remove([oldID])
            XCTAssertTrue(loader.visibilityPolicy.allows(id: asset.id))
            XCTAssertFalse(loader.visibilityPolicy.allows(id: oldID))
            try await waitUntil("Remapping removes the original image's interaction even though the alias is still public") {
                self.interactions(in: cell).isEmpty
            }
            analyzer.finishAll()
            try await waitUntil("The obsolete analyzer returns without restoring its interaction") { analyzer.activeCount == 0 }
            XCTAssertEqual(analyzer.cancelledCount, completed ? 0 : 1)

            cell.configure(with: asset, loader: loader)
            _ = try await screenshot(window)
            XCTAssertTrue(try imageView(in: cell).image === oldImage)
            XCTAssertTrue(interactions(in: cell).isEmpty)
            XCTAssertEqual(analyzer.images.count, 1, "Reusing an old UIImage must preserve its original source binding")
            loader.cached[asset.id] = replacementImage
            cell.configure(with: asset, loader: loader)
            try await waitUntil("A new bitmap can be analyzed under the replacement identity") { analyzer.images.count == 2 }
            XCTAssertTrue(analyzer.images.last === replacementImage)
            cell.prepareForReuse()
            analyzer.finishAll()
        }
    }

    func testChangingTheSessionRejectsHeldAnalysisAndCannotReauthorizeItsStillMountedOldBitmap() async throws {
        let session = MockSessionManager()
        try session.setServer("https://analysis-before.example")
        let analyzer = analyzer(), loader = AnalysisPreviewLoader(session: session), asset = photo()
        let oldImage = image(.red), freshImage = image(.blue)
        loader.cached[asset.id] = oldImage
        let cell = PhotoPagerCell(frame: .zero)
        cell.setImageAnalyzer(analyzer)
        track(cell)
        let window = try await host(AnalysisCellHost(cell: cell))
        cell.configure(with: asset, loader: loader)
        cell.setImageAnalysisActive(true)
        try await waitUntil("The original session starts one held analysis") { analyzer.images.count == 1 }
        let generation = LocalSnapshot.generation

        try session.setServer("https://analysis-after.example")

        XCTAssertEqual(LocalSnapshot.generation, generation)
        try await waitUntil("The changed request context removes the actual native interaction") { self.interactions(in: cell).isEmpty }
        analyzer.finishAll()
        try await waitUntil("The old session's held analysis is cancelled") { analyzer.activeCount == 0 }
        XCTAssertEqual(analyzer.cancelledCount, 1)
        cell.configure(with: asset, loader: loader)
        _ = try await screenshot(window)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertEqual(analyzer.images.count, 1)
        loader.cached[asset.id] = freshImage
        cell.configure(with: asset, loader: loader)
        try await waitUntil("A fresh image under the new session can be analyzed") { analyzer.images.count == 2 }
        XCTAssertTrue(analyzer.images.last === freshImage)
    }

    func testAHeldPreviewCannotInstallOldPixelsAfterItsAliasOrSessionChanges() async throws {
        for invalidation in ["mapping", "session"] {
            let session = MockSessionManager()
            try session.setServer("https://held-preview-before.example")
            let localID = UUID().uuidString
            try link(localID, to: UUID().uuidString)
            let asset = AssetLite(id: LocalPhotoLibrary.assetID(for: localID), isVideo: false, ratio: 1,
                thumbhash: nil, createdAt: .now, origin: .both)
            let analyzer = analyzer(), loader = AnalysisPreviewLoader(session: session)
            let gate = PeopleStateGate<UIImage?>(), oldImage = image(.red)
            loader.imageOperation = { _ in try? await gate.value() }
            let cell = PhotoPagerCell(frame: .zero)
            cell.setImageAnalyzer(analyzer)
            track(cell)
            try await host(AnalysisCellHost(cell: cell))
            cell.configure(with: asset, loader: loader)
            cell.setImageAnalysisActive(true)
            addTeardownBlock { await gate.complete(.success(nil)) }
            await fulfillment(of: [gate.started], timeout: 2)
            XCTAssertTrue(analyzer.images.isEmpty)
            if invalidation == "mapping" {
                try SwiftDataManager.shared.upsertBackupRecord(assetID: UUID().uuidString, checksum: "", localIdentifier: localID)
            } else { try session.setServer("https://held-preview-after.example") }
            gate.complete(.success(oldImage))
            try await waitUntil("The original preview loader returns after \(invalidation) changes") { loader.completedImageLoads == 1 }

            XCTAssertNil(try imageView(in: cell).image, invalidation)
            XCTAssertTrue(analyzer.images.isEmpty, invalidation)
            XCTAssertTrue(interactions(in: cell).isEmpty, invalidation)
            let freshImage = image(.blue)
            loader.imageOperation = { _ in freshImage }
            cell.retryIfNeeded(loader: loader)
            try await waitUntil("The stale preview releases its request handle so a fresh source can retry") {
                analyzer.images.count == 1
            }
            XCTAssertTrue(try imageView(in: cell).image === freshImage, invalidation)
            XCTAssertTrue(analyzer.images.first === freshImage, invalidation)
        }
    }

    func testWindowRemovalAndBackgroundSuspensionClearTheNativeInteractionAndCanResume() async throws {
        let analyzer = analyzer(), loader = AnalysisPreviewLoader(), asset = photo()
        let cell = PhotoPagerCell(frame: .zero)
        cell.setImageAnalyzer(analyzer)
        track(cell)
        let window = try await host(AnalysisCellHost(cell: cell))
        loader.cached[asset.id] = image(.green)
        cell.configure(with: asset, loader: loader)
        cell.setImageAnalysisActive(true)
        try await waitUntil("The displayed cell starts analysis") { analyzer.images.count == 1 }
        cell.removeFromSuperview()
        XCTAssertTrue(interactions(in: cell).isEmpty)
        window.rootViewController?.view.addSubview(cell)
        try await waitUntil("Reattaching the still-current cell starts a new request") { analyzer.images.count == 2 }
        cell.setImageAnalysisActive(false)

        let view = try imageView(in: cell)
        let center = NotificationCenter()
        let analysis = PhotoImageAnalysis(imageView: view, analyzer: analyzer, notificationCenter: center)
        analysis.update(image: view.image, assetID: asset.id, generation: LocalSnapshot.generation, isAllowed: { true })
        try await waitUntil("The isolated foreground interaction starts") { analyzer.images.count == 3 }
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(interactions(in: cell).isEmpty)
        analysis.update(image: view.image, assetID: asset.id, generation: LocalSnapshot.generation, isAllowed: { true })
        XCTAssertTrue(interactions(in: cell).isEmpty)
        XCTAssertEqual(analyzer.images.count, 3)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        analysis.update(image: view.image, assetID: asset.id, generation: LocalSnapshot.generation, isAllowed: { true })
        try await waitUntil("Returning to foreground permits analysis again") { analyzer.images.count == 4 }
        analysis.clear()
        analyzer.finishAll()
        try await waitUntil("Every suspended request completes") { analyzer.activeCount == 0 }
        XCTAssertEqual(analyzer.cancelledCount, 4)
    }

    func testPagerAnalyzesOnlyTheSelectedPageAndStopsDuringDraggingAndDismissal() async throws {
        let analyzer = analyzer(), loader = AnalysisPreviewLoader()
        let assets = [photo(), photo(), photo()]
        let images = [image(.red), image(.green), image(.blue)]
        for (asset, image) in zip(assets, images) { loader.cached[asset.id] = image }
        let controller = PhotoPagerController(loader: loader, imageAnalyzer: analyzer)
        controllers.append(controller)
        retainedController = controller
        controller.loadViewIfNeeded()
        controller.apply(assets: assets, currentAssetID: assets[1].id)
        try await host(AnalysisPagerHost(controller: controller))
        try await waitUntil("Only the selected middle page starts analysis") { analyzer.images.count == 1 }
        XCTAssertTrue(analyzer.images.first === images[1])
        let collection = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.setContentOffset(CGPoint(x: collection.bounds.width * 0.75, y: 0), animated: false)
        collection.layoutIfNeeded()
        try await waitUntil("The neighbor is visible beside the selected page") { collection.visibleCells.count == 2 }
        XCTAssertEqual(analyzer.images.count, 1, "A prefetched or adjacent visible cell must not analyze")
        controller.scrollViewWillBeginDragging(collection)
        XCTAssertTrue(collection.visibleCells.compactMap { $0 as? PhotoPagerCell }.allSatisfy { interactions(in: $0).isEmpty })

        controller.apply(assets: assets, currentAssetID: assets[2].id)
        try await waitUntil("A programmatic filmstrip change activates only its destination") { analyzer.images.count == 2 }
        XCTAssertTrue(analyzer.images.last === images[2])
        controller.stopImageAnalysis()
        controller.viewDidLayoutSubviews()
        XCTAssertTrue(collection.visibleCells.compactMap { $0 as? PhotoPagerCell }.allSatisfy { interactions(in: $0).isEmpty })
        analyzer.finishAll()
        try await waitUntil("The old and dismissed page requests return") { analyzer.activeCount == 0 }
        XCTAssertEqual(analyzer.cancelledCount, 2)
    }

    private func track(_ cell: PhotoPagerCell) { cells.append(cell); retainedCell = cell }

    private func link(_ localID: String, to serverID: String) throws {
        let recordID = UUID().uuidString
        mappings.append((recordID, localID))
        try SwiftDataManager.shared.insertBackupRecord(BackupRecord(id: recordID, assetId: serverID,
            deviceAssetId: "", localIdentifier: localID))
    }

    private func analyzer() -> HeldPhotoImageAnalyzer {
        let analyzer = HeldPhotoImageAnalyzer()
        analyzers.append(analyzer)
        return analyzer
    }

    private func photo() -> AssetLite {
        AssetLite(id: UUID().uuidString, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .now)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    private func imageView(in cell: PhotoPagerCell) throws -> UIImageView {
        let scroll = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIScrollView }.first)
        return try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
    }

    private func interactions(in cell: PhotoPagerCell) -> [ImageAnalysisInteraction] {
        (try? imageView(in: cell).interactions.compactMap { $0 as? ImageAnalysisInteraction }) ?? []
    }
}

@MainActor
private final class HeldPhotoImageAnalyzer: PhotoImageAnalyzing {
    let isSupported = true
    private(set) var images: [UIImage] = []
    private var pending: [PeopleStateGate<ImageAnalysis?>] = []
    private(set) var activeCount = 0
    private(set) var cancelledCount = 0

    func analyze(_ image: UIImage) async throws -> ImageAnalysis? {
        images.append(image)
        let gate = PeopleStateGate<ImageAnalysis?>()
        pending.append(gate)
        activeCount += 1
        defer { activeCount -= 1; if Task.isCancelled { cancelledCount += 1 } }
        return try await gate.value()
    }

    func finishAll() {
        pending.forEach { $0.complete(.success(nil)) }
        pending.removeAll()
    }
}

@MainActor
private final class AnalysisPreviewLoader: PhotoPreviewLoader {
    var cached: [String: UIImage] = [:]
    var imageOperation: ((String) async -> UIImage?)?
    private(set) var completedImageLoads = 0
    init(session: SessionManager? = nil) { super.init(session: session ?? MockSessionManager()) }
    override func cachedImage(for assetId: String) -> UIImage? { cached[assetId] }
    override func hasPreview(for assetId: String) -> Bool { cached[assetId] != nil }
    override func image(for assetId: String) async -> UIImage? {
        defer { completedImageLoads += 1 }
        if let imageOperation { return await imageOperation(assetId) }
        return cached[assetId]
    }
    override func localLivePhotoAssetID(for assetID: String) -> String? { nil }
    override func prefetch(_ assetIds: [String]) {}
}

private struct AnalysisCellHost: UIViewRepresentable {
    let cell: PhotoPagerCell
    func makeUIView(context: Context) -> PhotoPagerCell { cell }
    func updateUIView(_ uiView: PhotoPagerCell, context: Context) {}
}

private struct AnalysisPagerHost: UIViewControllerRepresentable {
    let controller: PhotoPagerController
    func makeUIViewController(context: Context) -> PhotoPagerController { controller }
    func updateUIViewController(_ uiViewController: PhotoPagerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: PhotoPagerController, coordinator: ()) {
        uiViewController.stopImageAnalysis()
    }
}
