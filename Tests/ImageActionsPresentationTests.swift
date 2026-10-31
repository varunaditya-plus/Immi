import Observation
import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ImmichApp

@MainActor
final class ImageActionsPresentationTests: SimulatorHostedTestCase {
    private var transports: [URLSession] = []
    private var collectionFixture: ImageActionsCollectionFixture?
    private var mounted: [ImageActionsMountedState] = []
    private var exportGates: [ImageActionsExportGate] = []
    private var clipboard: [[String: Any]]?
    private var viewerModel: AssetDetailViewModel?
    private weak var retainedViewerModel: AssetDetailViewModel?
    private var http: ImageActionsHTTP?
    private var mappings: [(recordID: String, localID: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        mounted.forEach { $0.content = nil }
        try await waitUntil("The image actions unmount before their still-mounted hosts close") {
            self.windows.allSatisfy {
                self.find(PhotoGridController.self, in: $0.rootViewController) == nil
                    && self.find(PhotoPagerController.self, in: $0.rootViewController) == nil
            }
        }
        exportGates.forEach { $0.releaseIfHeld() }
        exportGates.removeAll()
        try await waitUntil("Every held collection export returns before cleanup") {
            (self.collectionFixture?.exportsReturned ?? 0) == (self.collectionFixture?.exportRequests.count ?? 0)
        }
        try await super.tearDown()
        mounted.removeAll()
        viewerModel = nil
        http = nil
        MockURLProtocol.reset()
        transports.forEach { $0.invalidateAndCancel() }
        transports.removeAll()
        TemporaryMediaStore.remove(collectionFixture?.files ?? [])
        collectionFixture = nil
        for mapping in mappings {
            let recordID = mapping.recordID
            let descriptor = FetchDescriptor<BackupRecord>(predicate: #Predicate { $0.id == recordID })
            for record in try SwiftDataManager.shared.modelContext.fetch(descriptor) {
                SwiftDataManager.shared.modelContext.delete(record)
            }
            try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: mapping.localID)
        }
        mappings.removeAll()
        if let clipboard { UIPasteboard.general.setItems(clipboard) }
        clipboard = nil
        try await waitUntil("Closing the image actions releases the viewer model") { self.retainedViewerModel == nil }
    }

    func testMountedCollectionCopyWritesActualImageBytesAfterCleaningItsExport() async throws {
        preserveClipboard()
        let fixture = try ImageActionsCollectionFixture(count: 1)
        let window = try await showCollection(fixture)
        let grid = try await collectionGrid(in: window)
        let asset = try XCTUnwrap(fixture.assets.first)
        let action = try XCTUnwrap(grid.menuActions?(asset.id).first { $0.title == "Copy" })

        action.handler()

        try await waitUntil("The mounted Copy action writes the exported image rather than a temporary URL") {
            UIPasteboard.general.data(forPasteboardType: UTType.png.identifier) == fixture.images[asset.id]
        }
        XCTAssertEqual(fixture.exportRequests, [[asset.id]])
        XCTAssertNil(UIPasteboard.general.url)
        XCTAssertEqual(fixture.files.count, 1)
        XCTAssertTrue(fixture.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier), fixture.images[asset.id])
    }

    func testActualBulkCopyKeepsLibraryOrderWhenCellsAreSelectedInReverse() async throws {
        preserveClipboard()
        let fixture = try ImageActionsCollectionFixture(count: 2)
        let window = try await showCollection(fixture)
        let grid = try await collectionGrid(in: window)
        try await activateAccessibilityButton(named: "Select", in: window)
        for asset in fixture.assets.reversed() { try await select(asset.id, in: grid) }

        try await activateSearchMenuAction(named: "Copy", in: window)

        try await waitUntil("The actual bulk Copy action publishes both selected image items") {
            UIPasteboard.general.items.count == 2
        }
        let actual = try (0..<2).map { index in
            try XCTUnwrap(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier,
                inItemSet: IndexSet(integer: index))?.first)
        }
        let expected = try fixture.assets.map { try XCTUnwrap(fixture.images[$0.id]) }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(fixture.exportRequests, [fixture.assets.map(\.id)])
        XCTAssertEqual(fixture.files.count, 2)
        XCTAssertTrue(fixture.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testContextDeleteWaitsForConfirmationAndKeepsTheCapturedVideoTitle() async throws {
        let fixture = try ImageActionsCollectionFixture(count: 2, firstIsVideo: true)
        let window = try await showCollection(fixture)
        let grid = try await collectionGrid(in: window)
        let video = try XCTUnwrap(fixture.assets.first)
        let action = try XCTUnwrap(grid.menuActions?(video.id).first { $0.title == "Delete" })

        action.handler()

        XCTAssertTrue(fixture.deletions.isEmpty, "The context action must only request confirmation")
        let alert = try await presentedAlert(in: window)
        XCTAssertEqual(alert.title, "Delete Video")
        XCTAssertEqual(alert.message, "Are you sure you want to delete this video?")
        XCTAssertEqual(Set(alert.actions.compactMap(\.title)), ["Delete", "Cancel"])
        fixture.assets.removeAll { $0.id == video.id }
        _ = try await screenshot(window)
        XCTAssertEqual(alert.title, "Delete Video", "The pending target must not change with the grid's source array")
        XCTAssertTrue(fixture.deletions.isEmpty)
    }

    func testContextDeleteConfirmsOnlyTheCapturedSourceAndSession() async throws {
        for change in ["unchanged", "remap", "unlink", "server"] {
            let fixture = try ImageActionsCollectionFixture(count: 1)
            let localID = UUID().uuidString, recordID = UUID().uuidString
            let sourceID = UUID().uuidString
            let displayID = LocalPhotoLibrary.assetID(for: localID)
            mappings.append((recordID, localID))
            try SwiftDataManager.shared.insertBackupRecord(BackupRecord(id: recordID, assetId: sourceID,
                deviceAssetId: "", localIdentifier: localID))
            fixture.assets = [AssetLite(id: displayID, isVideo: false, ratio: 1, thumbhash: nil, createdAt: .now)]
            let session = MockSessionManager()
            try session.setServer("https://delete-before.example")
            let window = try await showCollection(fixture, session: session)
            let grid = try await collectionGrid(in: window)
            let action = try XCTUnwrap(grid.menuActions?(displayID).first { $0.title == "Delete" })
            action.handler()
            let alert = try await presentedAlert(in: window)
            XCTAssertTrue(fixture.deletions.isEmpty)
            let generation = LocalSnapshot.generation

            if change == "remap" {
                try SwiftDataManager.shared.upsertBackupRecord(assetID: UUID().uuidString,
                    checksum: "", localIdentifier: localID)
            } else if change == "unlink" {
                try SwiftDataManager.shared.unlinkDeviceAsset(localIdentifier: localID)
            } else if change == "server" {
                try session.setServer("https://delete-after.example")
            }
            XCTAssertEqual(LocalSnapshot.generation, generation)
            let command = try XCTUnwrap(alert.keyCommands?.first { $0.input == "\r" },
                "The native confirmation must provide its public Return command")
            XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: alert, from: command, for: nil))
            try await waitUntil("The native confirmation finishes before checking its deletion") {
                !self.searchPresentedControllers(in: window.rootViewController).contains { $0 === alert }
            }
            if change == "unchanged" {
                try await waitUntil("The unchanged confirmation invokes the actual collection deletion") {
                    fixture.deletions == [[displayID]]
                }
            } else {
                XCTAssertTrue(fixture.deletions.isEmpty, change)
            }
            mounted.last?.content = nil
            try await waitUntil("Each collection unmounts before the next confirmation fixture") {
                self.find(PhotoGridController.self, in: window.rootViewController) == nil
            }
        }
    }

    func testCancellingTheActualSelectionRejectsALateCopyExport() async throws {
        preserveClipboard()
        let fixture = try ImageActionsCollectionFixture(count: 1)
        let gate = ImageActionsExportGate()
        exportGates.append(gate)
        fixture.exportGate = gate
        let window = try await showCollection(fixture)
        let grid = try await collectionGrid(in: window)
        let asset = try XCTUnwrap(fixture.assets.first)
        try await activateAccessibilityButton(named: "Select", in: window)
        try await select(asset.id, in: grid)
        try await activateSearchMenuAction(named: "Copy", in: window)
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(fixture.exportRequests, [[asset.id]])

        try await activateAccessibilityButton(named: "Cancel", in: window)
        try await waitUntil("The actual Cancel control exits selection before the export returns") {
            self.collection(in: grid.view)?.isEditing == false
        }
        gate.finish()
        try await waitUntil("The late export returns and its managed file is discarded") {
            fixture.exportsReturned == 1 && fixture.files.count == 1
                && fixture.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }

        XCTAssertEqual(UIPasteboard.general.string, "Before media Copy")
        XCTAssertNil(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier))
    }

    func testMountedCopyRejectsALateExportAfterTheServerChangesWithoutAnAccountReset() async throws {
        preserveClipboard()
        let fixture = try ImageActionsCollectionFixture(count: 1)
        let gate = ImageActionsExportGate()
        exportGates.append(gate)
        fixture.exportGate = gate
        let session = MockSessionManager()
        try session.setServer("https://collection-actions-before.example")
        let window = try await showCollection(fixture, session: session)
        let grid = try await collectionGrid(in: window)
        let asset = try XCTUnwrap(fixture.assets.first)
        let action = try XCTUnwrap(grid.menuActions?(asset.id).first { $0.title == "Copy" })
        let generation = LocalSnapshot.generation

        action.handler()
        await fulfillment(of: [gate.started], timeout: 2)
        try session.setServer("https://collection-actions-after.example")
        XCTAssertEqual(LocalSnapshot.generation, generation)
        gate.finish()
        try await waitUntil("The late context-mismatched export returns and is discarded") {
            fixture.exportsReturned == 1 && fixture.files.count == 1
                && fixture.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }

        XCTAssertEqual(fixture.exportRequests, [[asset.id]])
        XCTAssertEqual(UIPasteboard.general.string, "Before media Copy")
        XCTAssertNil(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier))
    }

    func testViewerMoreCopyUsesTheCurrentFileAndCleansItBeforeTheClipboardIsRead() async throws {
        preserveClipboard()
        let window = try await showViewer()
        let response = try XCTUnwrap(http)
        try await activateSearchMenuAction(named: "Copy", in: window)

        try await waitUntil("The actual viewer Copy action writes its downloaded media bytes") {
            UIPasteboard.general.data(forPasteboardType: UTType.png.identifier) == response.png
        }
        XCTAssertEqual(response.originalRequests.count, 1)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(response.originalRequests.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "edited" }?.value, "true")
        XCTAssertNil(viewerModel?.actionError)
        XCTAssertTrue(try managedShareFiles { $0.lastPathComponent == response.filename }.isEmpty)
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier), response.png)
    }

    func testViewerWithoutOpeningMoreReleasesItsModel() async throws {
        _ = try await showViewer()
        XCTAssertNotNil(viewerModel?.detail)
    }

    func testViewerMoreOpensExistingMetadataEditorsAndCancellationDoesNotMutateTheAsset() async throws {
        let window = try await showViewer()
        let response = try XCTUnwrap(http)
        for title in ["Adjust Date & Time", "Adjust Location"] {
            try await activateSearchMenuAction(named: title, in: window)
            try await waitUntil("The actual \(title) sheet opens from More") {
                guard let presented = window.rootViewController?.presentedViewController else { return false }
                return self.searchContainsText(title, in: presented.view)
            }
            let presented = try XCTUnwrap(window.rootViewController?.presentedViewController)
            try await activateAccessibilityButton(named: "Cancel", in: window, within: presented.view)
            try await waitUntil("Cancelling the metadata sheet returns to the viewer") {
                window.rootViewController?.presentedViewController == nil
            }
        }
        XCTAssertTrue(response.mutations.isEmpty)
    }

    func testMountedCollectionSlideshowStartsAtTheContextPhotoAndItsActualControlsReturnToTheGrid() async throws {
        let fixture = try ImageActionsCollectionFixture(count: 3)
        let source = fixture.assets
        for asset in source {
            let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(fixture.images[asset.id])))
            ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(asset.id)-thumbnail", 600))
            ImageMemoryCache.shared.insert(image, for: ImageCache.memoryKey("\(asset.id)-preview", 1400))
        }
        defer {
            for asset in source {
                ImageMemoryCache.shared.remove(for: ImageCache.memoryKey("\(asset.id)-thumbnail", 600))
                ImageMemoryCache.shared.remove(for: ImageCache.memoryKey("\(asset.id)-preview", 1400))
            }
        }
        let window = try await showCollection(fixture)
        let grid = try await collectionGrid(in: window)
        let target = try XCTUnwrap(source.dropFirst().first)
        let action = try XCTUnwrap(grid.menuActions?(target.id).first { $0.title == "Slideshow" },
            "Use the mounted collection's configured context action, without private context-menu APIs")

        action.handler()

        try await waitUntil("The configured action opens the actual slideshow at its captured photo") {
            self.searchPresentedControllers(in: window.rootViewController).contains {
                self.searchContainsText("Slideshow", in: $0.view) && self.searchContainsText("2 of 3", in: $0.view)
            }
        }
        let slideshow = try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).first {
            searchContainsText("Slideshow", in: $0.view)
        })
        try await activateAccessibilityButton(named: "Pause", in: window, within: slideshow.view)
        try await activateAccessibilityButton(named: "Next", in: window, within: slideshow.view)
        try await waitUntil("The actual Next control changes the rendered slide position") {
            self.searchContainsText("3 of 3", in: slideshow.view)
        }
        try await activateAccessibilityButton(named: "Previous", in: window, within: slideshow.view)
        try await waitUntil("The actual Previous control returns to the captured middle photo") {
            self.searchContainsText("2 of 3", in: slideshow.view)
        }
        try await activateAccessibilityButton(named: "Close", in: window, within: slideshow.view)
        try await waitUntil("Closing the slideshow returns to the same mounted collection") {
            self.searchPresentedControllers(in: window.rootViewController).isEmpty
                && self.grid(in: window.rootViewController) != nil
        }
        XCTAssertEqual(fixture.assets.map(\.id), source.map(\.id))
        XCTAssertTrue(fixture.exportRequests.isEmpty)
        XCTAssertTrue(fixture.deletions.isEmpty)
    }

    private func preserveClipboard() {
        clipboard = UIPasteboard.general.items
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: "Before media Copy"]])
    }

    private func showCollection(_ fixture: ImageActionsCollectionFixture, session: SessionManager? = nil) async throws -> UIWindow {
        collectionFixture = fixture
        let content = AnyView(NavigationStack { ImageActionsCollectionHost(fixture: fixture) })
        let state = ImageActionsMountedState(session.map { AnyView(content.environment($0)) } ?? content)
        mounted.append(state)
        return try await host(ImageActionsMountedHost(state: state))
    }

    private func collectionGrid(in window: UIWindow) async throws -> PhotoGridController {
        try await waitUntil("The actual photo collection grid is mounted") { self.grid(in: window.rootViewController) != nil }
        return try XCTUnwrap(grid(in: window.rootViewController))
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        find(PhotoGridController.self, in: controller)
    }

    private func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController?) -> T? {
        guard let controller else { return nil }
        if let found = controller as? T { return found }
        return controller.children.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func select(_ id: String, in grid: PhotoGridController) async throws {
        let collection = try XCTUnwrap(collection(in: grid.view))
        try await waitUntil("Select puts the mounted grid into editing mode") { collection.isEditing }
        try await waitUntil("The selected photo has reached the actual data-source snapshot") { grid.revealCell(for: id) != nil }
        let path = try XCTUnwrap(grid.revealCell(for: id))
        try await waitUntil("The selected photo cell is rendered") { collection.cellForItem(at: path) != nil }
        XCTAssertTrue(try XCTUnwrap(collection.cellForItem(at: path)).accessibilityActivate())
        try await waitUntil("The native cell selection reaches the collection") {
            collection.indexPathsForSelectedItems?.contains(path) == true
        }
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }

    private func presentedAlert(in window: UIWindow) async throws -> UIAlertController {
        try await waitUntil("The actual deletion confirmation is visible") {
            self.searchPresentedControllers(in: window.rootViewController).contains { $0 is UIAlertController }
        }
        return try XCTUnwrap(searchPresentedControllers(in: window.rootViewController).compactMap { $0 as? UIAlertController }.first)
    }

    private func showViewer() async throws -> UIWindow {
        let session = MockSessionManager()
        try session.setServer("https://image-actions.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        transports.append(transport)
        let response = try ImageActionsHTTP()
        http = response
        MockURLProtocol.responseProvider = { response.respond($0) }
        let api = APIClient(session: session, urlSession: transport)
        viewerModel = AssetDetailViewModel(repo: AssetDetailRepository(api: api))
        retainedViewerModel = viewerModel
        let state = ImageActionsMountedState(AnyView(NavigationStack {
            AssetDetailView(currentAsset: AssetLite(response.asset), assets: [AssetLite(response.asset)],
                isModal: true, viewModel: viewerModel)
        }.environment(session as SessionManager).environment(\.horizontalSizeClass, .compact)))
        mounted.append(state)
        let window = try await host(ImageActionsMountedHost(state: state))
        try await waitUntil("The viewer loads the actual fixture metadata before its More actions") {
            self.viewerModel?.detail?.id == response.asset.id
        }
        return window
    }
}

@MainActor
@Observable
private final class ImageActionsMountedState {
    var content: AnyView?
    init(_ content: AnyView) { self.content = content }
}

private struct ImageActionsMountedHost: View {
    let state: ImageActionsMountedState
    var body: some View { state.content }
}

@MainActor
@Observable
private final class ImageActionsCollectionFixture {
    var assets: [AssetLite]
    var deletions: [[String]] = []
    var exportRequests: [[String]] = []
    var files: [URL] = []
    var exportGate: ImageActionsExportGate?
    var exportsReturned = 0
    let images: [String: Data]

    init(count: Int, firstIsVideo: Bool = false) throws {
        let photos = (0..<count).map { index in
            AssetLite(id: UUID().uuidString, isVideo: firstIsVideo && index == 0, ratio: 1,
                thumbhash: nil, createdAt: Date(timeIntervalSince1970: 1_760_000_000 - Double(index)))
        }
        assets = photos
        images = try Dictionary(uniqueKeysWithValues: photos.enumerated().map { index, asset in
            (asset.id, try imageActionsPNG(color: index == 0 ? .green : .blue))
        })
    }

    func export(_ ids: [String]) async -> [URL] {
        exportRequests.append(ids)
        let prepared = ids.compactMap { id -> URL? in
            do {
                let data = try XCTUnwrap(images[id])
                let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: source)
                let file = try TemporaryMediaStore.adoptShareFile(at: source, suggestedFilename: "\(id).png")
                files.append(file)
                return file
            } catch { XCTFail("The synthetic export failed: \(error)"); return nil }
        }
        if let exportGate { await exportGate.value() }
        exportsReturned += 1
        return prepared
    }
}

private struct ImageActionsCollectionHost: View {
    let fixture: ImageActionsCollectionFixture
    var body: some View {
        PhotoCollectionScreen(title: "Image Actions", layout: .monthly, assets: fixture.assets, phase: .loaded(()),
            onRetry: {}, onDelete: { fixture.deletions.append($0) }, shareURLs: { await fixture.export($0) })
    }
}

@MainActor
private final class ImageActionsExportGate {
    let started = XCTestExpectation(description: "The mounted Copy export is held")
    private var pending: CheckedContinuation<Void, Never>?

    func value() async { await withCheckedContinuation { pending = $0; started.fulfill() } }

    func finish() {
        guard let pending else { return XCTFail("The held mounted export must exist") }
        self.pending = nil
        pending.resume()
    }

    func releaseIfHeld() {
        guard let pending else { return }
        self.pending = nil
        pending.resume()
    }
}

private final class ImageActionsHTTP: @unchecked Sendable {
    let asset: AssetResponseDTO
    let filename: String
    let png: Data
    private let assetData: Data
    private let lock = NSLock()
    private var originals: [URLRequest] = []
    private var writes: [URLRequest] = []
    var originalRequests: [URLRequest] { lock.withLock { originals } }
    var mutations: [URLRequest] { lock.withLock { writes } }

    @MainActor
    init() throws {
        asset = makeTestAsset(id: UUID().uuidString)
        filename = "\(UUID().uuidString).png"
        png = try imageActionsPNG(color: .orange)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        assetData = try encoder.encode(asset)
    }

    func respond(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        lock.withLock {
            let path = request.url?.path ?? ""
            var data = Data("[]".utf8)
            var headers = ["Content-Type": "application/json"]
            if request.httpMethod != "GET" { writes.append(request) }
            if path.hasSuffix("/original") {
                originals.append(request)
                data = png
                headers = ["Content-Type": "image/png", "Content-Disposition": "attachment; filename=\"\(filename)\""]
            } else if path == "/api/assets/\(asset.id)" {
                data = assetData
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers), nil)
        }
    }
}

@MainActor
private func imageActionsPNG(color: UIColor) throws -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
        color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
    }
    return try XCTUnwrap(image.pngData())
}
