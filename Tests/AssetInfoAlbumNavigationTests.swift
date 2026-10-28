import Observation
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class AssetInfoAlbumNavigationTests: XCTestCase {
    private var keys = Set<String>()
    private var windows: [UIWindow] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for key in keys { LocalSnapshot.remove(key) }
        keys.removeAll()
        try await super.tearDown()
    }

    func testMetadataCallbacksNotifyBothRowsAndPreserveCurrentContentsAndSharing() {
        let model = model()
        let selected = model.selectAsset("photo")
        model.albums = [album("target", name: "Old", count: 7, cover: "current", shared: true)]
        model.containingAlbums = model.albums
        let published = AlbumRowPublication()
        withObservationTracking { _ = model.albums } onChange: {
            MainActor.assumeIsolated { published.available = true }
        }
        withObservationTracking { _ = model.containingAlbums } onChange: {
            MainActor.assumeIsolated { published.containing = true }
        }
        var edited = album("target", name: "Saved name", count: 99, cover: "obsolete")
        edited.description = "Saved description"
        model.applyAlbumUpdate(edited, for: selected)

        XCTAssertTrue(published.available)
        XCTAssertTrue(published.containing)
        for row in [model.albums.first, model.containingAlbums.first] {
            XCTAssertEqual(row?.albumName, "Saved name")
            XCTAssertEqual(row?.description, "Saved description")
            XCTAssertEqual(row?.assetCount, 7)
            XCTAssertEqual(row?.albumThumbnailAssetId, "current")
            XCTAssertEqual(row?.shared, true)
        }
    }

    func testConfirmedContentsUpdateCoverCountAndOnlyRemoveTheSelectedPhotosAssociation() {
        let model = model()
        let selected = model.selectAsset("photo")
        model.albums = [album("target", count: 3, cover: "removed"), album("other")]
        model.containingAlbums = model.albums
        let currentPhoto = AssetLite(makeTestAsset(id: "photo"))
        model.applyAlbumContents([currentPhoto], to: "target", for: selected)
        XCTAssertEqual(model.containingAlbums.map(\.id), ["target", "other"])
        XCTAssertEqual(model.containingAlbums.first?.assetCount, 1)
        XCTAssertEqual(model.containingAlbums.first?.albumThumbnailAssetId, "photo")
        let keptPhoto = AssetLite(makeTestAsset(id: "kept"))
        model.applyAlbumContents([keptPhoto], to: "target", for: selected)
        XCTAssertEqual(model.containingAlbums.map(\.id), ["other"])
        XCTAssertEqual(model.albums.map(\.id), ["target", "other"], "The album still exists in the destination picker")
        XCTAssertEqual(model.albums.first?.assetCount, 1)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "kept")
    }

    func testConfirmedDeletionRemovesBothRowsAndOnlyItsOwnOfflineAlbum() {
        let model = model()
        let selected = model.selectAsset("photo")
        let id = UUID().uuidString
        let other = UUID().uuidString
        model.albums = [album(id), album(other)]
        model.containingAlbums = model.albums
        saveAlbumSnapshot(id)
        saveAlbumSnapshot(other)

        model.removeDeletedAlbum(id, for: selected)

        XCTAssertEqual(model.albums.map(\.id), [other])
        XCTAssertEqual(model.containingAlbums.map(\.id), [other])
        XCTAssertNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(id)))
        XCTAssertEqual(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(other)), ["photo"])
    }

    func testCallbacksInvalidateHeldContainingAndPickerReadsWithoutBlockingLaterRefreshes() async {
        for action in ["metadata", "contents", "delete", "share"] {
            let repository = AlbumInfoRepository()
            repository.containing = { [self.album("target", name: "Current", count: 7, cover: "old-cover")] }
            let model = model(repository)
            let selected = model.selectAsset("photo")
            await model.loadContainingAlbums(selected)
            let containing = AlbumInfoGate<[AlbumResponseDTO]>()
            let available = AlbumInfoGate<[AlbumResponseDTO]>()
            repository.containing = { try await containing.value() }
            repository.available = { try await available.value() }
            let readingContaining = Task { await model.loadContainingAlbums(selected) }
            let readingAvailable = Task { await model.loadAlbumsIfNeeded() }
            addTeardownBlock {
                await containing.complete(.failure(CancellationError()))
                await available.complete(.failure(CancellationError()))
                await readingContaining.value
                await readingAvailable.value
            }
            await fulfillment(of: [containing.started, available.started], timeout: 2)
            switch action {
            case "metadata": model.applyAlbumUpdate(album("target", name: "Saved"), for: selected)
            case "share": model.applyAlbumShared("target", for: selected)
            case "contents":
                model.applyAlbumContents([AssetLite(makeTestAsset(id: "photo"))], to: "target", for: selected)
            default: model.removeDeletedAlbum("target", for: selected)
            }
            containing.complete(.success([album("target", name: "Obsolete", count: 99)]))
            available.complete(.success([album("target", name: "Obsolete", count: 99)]))
            await readingContaining.value
            await readingAvailable.value

            XCTAssertTrue(model.albums.isEmpty, "A picker read started before the mutation cannot restore old metadata")
            if action == "delete" { XCTAssertTrue(model.containingAlbums.isEmpty) }
            else {
                XCTAssertEqual(model.containingAlbums.first?.shared, action == "share")
                XCTAssertEqual(model.containingAlbums.first?.albumName, action == "metadata" ? "Saved" : "Current")
                XCTAssertEqual(model.containingAlbums.first?.assetCount, action == "contents" ? 1 : 7)
                XCTAssertEqual(model.containingAlbums.first?.albumThumbnailAssetId,
                    action == "contents" ? "photo" : "old-cover")
            }
            let fresh = album("fresh", name: "Fresh")
            repository.available = { [fresh] }
            repository.containing = { [fresh] }
            await model.loadAlbumsIfNeeded()
            await model.loadContainingAlbums(selected)
            XCTAssertEqual(model.albums.map(\.id), ["fresh"])
            XCTAssertEqual(model.containingAlbums.first?.albumName, "Fresh")
        }
    }

    func testAnotherPhotoReturnVisitInactiveViewerAndAccountChangeRejectOldCallbacks() {
        for change in ["photo", "return", "inactive", "account"] {
            let model = model()
            let old = model.selectAsset("photo")
            if change == "account" { LocalSnapshot.clearAll() }
            else if change == "inactive" { model.invalidateSelection() }
            else {
                _ = model.selectAsset("different")
                if change == "return" { _ = model.selectAsset("photo") }
            }
            let current = album(UUID().uuidString, name: "Current", count: 7, cover: "current")
            model.albums = [current]
            model.containingAlbums = [current]
            saveAlbumSnapshot(current.id)
            model.applyAlbumShared(current.id, for: old)
            model.applyAlbumUpdate(album(current.id, name: "Stale callback"), for: old)
            model.applyAlbumContents([], to: current.id, for: old)
            model.removeDeletedAlbum(current.id, for: old)

            XCTAssertEqual(model.albums.first?.albumName, "Current", change)
            XCTAssertEqual(model.containingAlbums.first?.albumName, "Current", change)
            XCTAssertEqual(model.containingAlbums.first?.assetCount, 7, change)
            XCTAssertEqual(model.containingAlbums.first?.shared, false, change)
            XCTAssertNotNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(current.id)), change)
        }
    }

    func testCanceledCallbackDoesNotChangeRowsOrDeleteItsSnapshot() async {
        let model = model()
        let selected = model.selectAsset("photo")
        let current = album(UUID().uuidString, name: "Current")
        model.albums = [current]
        model.containingAlbums = [current]
        saveAlbumSnapshot(current.id)
        let entry = AlbumInfoGate<Void>()
        let operation = Task {
            try? await entry.value()
            model.applyAlbumShared(current.id, for: selected)
            model.applyAlbumUpdate(self.album(current.id, name: "Canceled"), for: selected)
            model.applyAlbumContents([], to: current.id, for: selected)
            model.removeDeletedAlbum(current.id, for: selected)
        }
        addTeardownBlock { await entry.complete(.failure(CancellationError())); await operation.value }
        await fulfillment(of: [entry.started], timeout: 2)
        operation.cancel()
        entry.complete(.success(()))
        await operation.value
        XCTAssertEqual(model.albums.first?.albumName, "Current")
        XCTAssertEqual(model.containingAlbums.first?.albumName, "Current")
        XCTAssertEqual(model.containingAlbums.first?.shared, false)
        XCTAssertNotNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(current.id)))
    }

    func testCurrentSelectionGetterDoesNotAdmitAnotherPhotoOrAnExpiredAccount() {
        let model = model()
        let selected = model.selectAsset("photo")
        XCTAssertEqual(model.currentSelection(for: "photo"), selected)
        XCTAssertNil(model.currentSelection(for: "different"))
        LocalSnapshot.clearAll()
        XCTAssertNil(model.currentSelection(for: "photo"))
    }

    func testActualPanelDestinationForwardsItsAlbumIDAndAllFourCallbacks() async throws {
        let row = album(UUID().uuidString, name: "Old", count: 2, cover: "old")
        let photo = makeTestAsset(id: "photo")
        let model = model()
        let selected = model.selectAsset(photo.id)
        model.albums = [row]
        model.containingAlbums = [row]
        saveAlbumSnapshot(row.id)
        let mounted = expectation(description: "The actual panel destination is constructed")
        let fixture = AlbumInfoPanelFixture(detail: photo, rows: [row],
            contents: { id, assets in model.applyAlbumContents(assets, to: id, for: selected) },
            changed: { model.applyAlbumUpdate($0, for: selected) },
            deleted: { model.removeDeletedAlbum($0, for: selected) },
            shared: { model.applyAlbumShared($0, for: selected) }) { destination in
                XCTAssertEqual(destination.album.id, row.id)
                destination.onShared?()
                XCTAssertEqual(model.containingAlbums.first?.shared, true)
                XCTAssertEqual(model.albums.first?.shared, true)
                var edited = row
                edited.albumName = "Saved"
                destination.onAlbumChanged?(edited)
                XCTAssertEqual(model.containingAlbums.first?.albumName, "Saved")
                destination.onContentsChanged?([AssetLite(photo)])
                XCTAssertEqual(model.containingAlbums.first?.assetCount, 1)
                XCTAssertEqual(model.containingAlbums.first?.albumThumbnailAssetId, photo.id)
                destination.onDeleted?()
                XCTAssertTrue(model.containingAlbums.isEmpty)
                XCTAssertTrue(model.albums.isEmpty)
                XCTAssertNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album(row.id)))
                mounted.fulfill()
            }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: fixture
            .environment(MockSessionManager() as SessionManager))
        window.makeKeyAndVisible()
        windows.append(window)
        await fulfillment(of: [mounted], timeout: 3)
    }

    private func model(_ albums: AlbumInfoRepository? = nil) -> AssetDetailViewModel {
        AssetDetailViewModel(repo: AssetDetailRepository(api: APIClient(session: MockSessionManager())), albumRepo: albums)
    }

    private func album(_ id: String, name: String = "Album", count: Int = 0, cover: String? = nil,
                       shared: Bool = false) -> AlbumResponseDTO {
        .init(id: id, albumName: name, description: nil, assetCount: count, albumThumbnailAssetId: cover,
            shared: shared, createdAt: Date(timeIntervalSince1970: 100), assets: nil)
    }

    private func saveAlbumSnapshot(_ id: String) {
        let key = LocalSnapshot.Key.album(id)
        keys.insert(key)
        LocalSnapshot.save(["photo"], for: key)
    }
}

@MainActor private final class AlbumRowPublication { var available = false; var containing = false }

private final class AlbumInfoRepository: AlbumRepository {
    var containing: @MainActor () async throws -> [AlbumResponseDTO] = { [] }
    var available: @MainActor () async throws -> [AlbumResponseDTO] = { [] }
    @MainActor init() { super.init(api: APIClient(session: MockSessionManager())) }
    override func albums(containing assetId: String) async throws -> [AlbumResponseDTO] { try await containing() }
    override func all() async throws -> [AlbumResponseDTO] { try await available() }
}

@MainActor private final class AlbumInfoGate<Value> {
    let started = XCTestExpectation(description: "An album info request is held")
    private var result: Result<Value, Error>?
    private var continuations: [CheckedContinuation<Value, Error>] = []
    private var hasStarted = false
    func value() async throws -> Value {
        if !hasStarted { hasStarted = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(with: result) }
    }
}

private struct AlbumInfoPanelFixture: View {
    let detail: AssetResponseDTO
    let rows: [AlbumResponseDTO]
    let contents: (String, [AssetLite]) -> Void
    let changed: (AlbumResponseDTO) -> Void
    let deleted: (String) -> Void
    let shared: (String) -> Void
    let didMount: (AlbumDetailView) -> Void
    @State private var description = ""
    @FocusState private var focused: Bool
    @State private var mounted = false

    var body: some View {
        let panel = AssetInfoPanel(detail: detail, descriptionDraft: $description, descriptionFocus: $focused,
            containingAlbums: rows, onAlbumContentsChanged: contents, onAlbumChanged: changed,
            onAlbumDeleted: deleted, onAlbumShared: shared)
        NavigationStack {
            panel.onAppear {
                guard !mounted else { return }
                mounted = true
                didMount(panel.albumDestination(for: rows[0]))
            }
        }
    }
}
