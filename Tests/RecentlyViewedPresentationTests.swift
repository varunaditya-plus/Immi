import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class RecentlyViewedPresentationTests: SimulatorHostedTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var manager: SwiftDataManager?
    private var store: RecentlyViewedStore?
    private var repositories: [RecentlyViewedDetailRepository] = []
    private var snapshotIDs: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        suite = "recently-viewed-presentation.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        store = RecentlyViewedStore(owner: owner, defaults: defaults, dataManager: manager)
    }

    override func tearDown() async throws {
        repositories.forEach { $0.finishAll() }
        try await waitUntil("Every held viewer detail response finishes") {
            self.repositories.allSatisfy { $0.activeCount == 0 }
        }
        try await super.tearDown()
        repositories.removeAll()
        store = nil
        let container = manager?.modelContainer
        manager = nil
        try container?.erase()
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        for id in snapshotIDs { LocalSnapshot.remove(LocalSnapshot.Key.assetDetail(id)) }
    }

    func testRealViewerRecordsOnlyConfirmedDisplayedPagesAndRejectsThePreviousPagesLateResponse() async throws {
        let store = try XCTUnwrap(store)
        let photos = (0..<4).map { _ in photo() }
        let repository = repository()
        let window = try await show(photos: photos, repository: repository)
        try await waitUntil("Only the visible photo requests metadata") { repository.requests.count == 1 }
        XCTAssertEqual(repository.requests, [photos[0].id])
        XCTAssertTrue(store.assets.isEmpty, "A pager preview or pending detail must not count as a confirmed view")
        repository.finish(1, with: .success(photos[0]))
        try await waitUntil("The confirmed initial page becomes Recently Viewed") { store.assets.map(\.id) == [photos[0].id] }

        try await scroll(to: 1, in: window)
        try await waitUntil("The pager's second displayed page starts its own detail read") { repository.requests.count == 2 }
        XCTAssertEqual(repository.requests[1], photos[1].id)
        XCTAssertEqual(store.assets.map(\.id), [photos[0].id])
        try await scroll(to: 2, in: window)
        try await waitUntil("A third displayed page replaces the held second page") { repository.requests.count == 3 }
        repository.finish(2, with: .success(photos[1]))
        try await waitUntil("The obsolete detail read actually completes") { repository.completed.contains(2) }
        XCTAssertEqual(store.assets.map(\.id), [photos[0].id], "Late metadata cannot record an offscreen photo")
        repository.finish(3, with: .success(photos[2]))
        try await waitUntil("The current page records after successful metadata") {
            store.assets.map(\.id) == [photos[2].id, photos[0].id]
        }
        XCTAssertFalse(repository.requests.contains(photos[3].id), "Preloaded neighboring pager cells must not record views")

        try await scroll(to: 0, in: window)
        try await waitUntil("Returning to the first page confirms a new metadata read") { repository.requests.count == 4 }
        repository.finish(4, with: .success(photos[0]))
        try await waitUntil("A real revisit moves the photo to the front without duplicating it") {
            store.assets.map(\.id) == [photos[0].id, photos[2].id]
        }
        XCTAssertEqual(reopened().assets.map(\.id), [photos[0].id, photos[2].id])
    }

    func testCachedMetadataDoesNotRecordAViewWhenTheActualDetailReadFails() async throws {
        let photo = photo()
        LocalSnapshot.save(photo, for: LocalSnapshot.Key.assetDetail(photo.id))
        let repository = repository()
        let model = AssetDetailViewModel(repo: repository)
        _ = try await show(photos: [photo], repository: repository, model: model)
        try await waitUntil("The real viewer requests fresh detail even with a cached public snapshot") {
            repository.requests.count == 1
        }
        repository.finish(1, with: .failure(APIError.notConnected))
        try await waitUntil("The failed actual read reaches the viewer model") { model.phase.errorMessage != nil }

        XCTAssertEqual(model.detail?.id, photo.id, "Offline info may remain visible independently of recents")
        XCTAssertTrue(try XCTUnwrap(store).assets.isEmpty)
        XCTAssertTrue(reopened().assets.isEmpty)
    }

    func testLockedTrashAndArchivedViewerRoutesNeverAddPublicRecents() async throws {
        var archived = photo()
        archived.isArchived = true
        archived.visibility = "archive"
        let trashed = photo(trashed: true)
        let publicPhoto = photo()
        let manager = try XCTUnwrap(manager)
        let scenarios: [(AssetResponseDTO, AssetVisibilityPolicy)] = [
            (archived, AssetVisibilityPolicy(dataManager: manager)),
            (trashed, AssetVisibilityPolicy(removalScope: .trash, dataManager: manager)),
            (publicPhoto, AssetVisibilityPolicy(scope: .locked, dataManager: manager)),
        ]
        for (photo, policy) in scenarios {
            let repository = repository()
            let model = AssetDetailViewModel(repo: repository)
            _ = try await show(photos: [photo], repository: repository, model: model, policy: policy)
            try await waitUntil("The excluded viewer route completes a real metadata request") { repository.requests.count == 1 }
            repository.finish(1, with: .success(photo))
            try await waitUntil("The real viewer receives the excluded photo's detail") { model.detail?.id == photo.id }
            _ = try await screenshot(try XCTUnwrap(windows.last))
            XCTAssertTrue(try XCTUnwrap(store).assets.isEmpty)
            XCTAssertTrue(reopened().assets.isEmpty)
        }
    }

    func testAccountExpiryWhileTheVisibleDetailIsHeldCannotRecordIntoTheNextSession() async throws {
        let photo = photo()
        let repository = repository()
        _ = try await show(photos: [photo], repository: repository)
        try await waitUntil("A visible viewer read is held before account expiry") { repository.requests.count == 1 }

        LocalSnapshot.clearAll()
        repository.finish(1, with: .success(photo))

        try await waitUntil("The old-account response reaches the invalidated viewer") { repository.completed.contains(1) }
        XCTAssertTrue(try XCTUnwrap(store).assets.isEmpty)
        XCTAssertTrue(reopened().assets.isEmpty)
    }

    func testNativeRecentsTileOpensThroughItsActualButtonAndDisappearsWhenItsOnlyPhotoBecomesPrivate() async throws {
        let store = try XCTUnwrap(store)
        let photo = photo()
        store.record(photo)
        var opened = 0
        let window = try await host(SearchRecentsView(store: store) { opened += 1 })
        try await waitUntil("The actual Recently Viewed tile is accessible") { self.recentButton(in: window) != nil }
        let tile = try XCTUnwrap(recentButton(in: window))
        XCTAssertEqual(tile.accessibilityFrame.width, 112, accuracy: 1)
        XCTAssertEqual(tile.accessibilityFrame.height, 112, accuracy: 1)

        try await activateAccessibilityButton(named: "Recently Viewed", in: window)

        XCTAssertEqual(opened, 1)
        try XCTUnwrap(manager).setAssetVisibility([photo.id], to: "locked")
        try await waitUntil("The tile removes its private cover through live store observation") {
            store.assets.isEmpty && self.recentButton(in: window) == nil
        }
        _ = try await screenshot(window)
        XCTAssertEqual(opened, 1, "Privacy changes must not navigate by themselves")
    }

    func testActualViewerFavoriteAndDateActionsPatchStoredMetadataWithoutChangingVisitOrder() async throws {
        let store = try XCTUnwrap(store)
        var photo = photo()
        photo.fileCreatedAt = Date(timeIntervalSince1970: 1_599_999_960)
        let repository = repository()
        let model = AssetDetailViewModel(repo: repository)
        let window = try await show(photos: [photo], repository: repository, model: model)
        try await waitUntil("The displayed viewer requests its initial metadata") { repository.requests.count == 1 }
        repository.finish(1, with: .success(photo))
        try await waitUntil("The displayed public photo is recorded before editing") { store.assets.map(\.id) == [photo.id] }
        let laterVisit = self.photo()
        store.record(laterVisit)

        try await activateAccessibilityButton(named: "Favorite", in: window)

        try await waitUntil("The actual Favorite action updates existing stored metadata") {
            repository.favoriteWrites == [true] && store.assets.last?.isFavorite == true
        }
        XCTAssertEqual(store.assets.map(\.id), [laterVisit.id, photo.id])
        XCTAssertTrue(reopened().assets.last?.isFavorite == true)
        repository.rejectMutations = true
        try await activateAccessibilityButton(named: "Unfavorite", in: window)
        try await waitUntil("The rejected actual Unfavorite action reaches the viewer") { model.actionError != nil }
        XCTAssertTrue(store.assets.last?.isFavorite == true, "A failed action must preserve the accepted recents metadata")
        repository.rejectMutations = false
        try await activateAccessibilityButton(named: "Info", in: window)
        try await activateAccessibilityButton(named: "Adjust", in: window)
        try await waitUntil("The viewer's actual date editor presents its native picker") { self.datePicker(in: window) != nil }
        let picker = try XCTUnwrap(datePicker(in: window))
        let saved = photo.fileCreatedAt.addingTimeInterval(86_400)
        picker.setDate(saved, animated: false)
        picker.sendActions(for: .valueChanged)

        try await activateAccessibilityButton(named: "Save", in: window)

        try await waitUntil("The actual date save is accepted and requests refreshed server detail") {
            repository.savedDates == [saved] && repository.requests.count == 2
        }
        repository.finish(2, with: .failure(APIError.notConnected))
        try await waitUntil("The accepted capture date updates history even when the follow-up read fails") {
            store.assets.last?.createdAt == saved
        }
        XCTAssertEqual(store.assets.map(\.id), [laterVisit.id, photo.id])
        XCTAssertTrue(store.assets.last?.isFavorite == true, "Updating a date must preserve an independently accepted favorite")
        XCTAssertEqual(reopened().assets.last?.createdAt, saved)
        XCTAssertTrue(reopened().assets.last?.isFavorite == true)
    }

    private var owner: BackupQueueOwner { BackupQueueOwner(server: "https://recent.example/api", userID: "user") }

    private func reopened() -> RecentlyViewedStore {
        RecentlyViewedStore(owner: owner, defaults: defaults, dataManager: manager)
    }

    private func photo(trashed: Bool = false) -> AssetResponseDTO {
        let id = UUID().uuidString
        snapshotIDs.append(id)
        return makeTestAsset(id: id, isTrashed: trashed)
    }

    private func repository() -> RecentlyViewedDetailRepository {
        let repository = RecentlyViewedDetailRepository(api: makeStubAPIClient())
        repositories.append(repository)
        return repository
    }

    private func show(photos: [AssetResponseDTO], repository: RecentlyViewedDetailRepository,
                      model: AssetDetailViewModel? = nil, policy: AssetVisibilityPolicy? = nil) async throws -> UIWindow {
        let assets = photos.map(AssetLite.init)
        let initial = try XCTUnwrap(assets.first)
        let viewer = AssetDetailView(currentAsset: initial, assets: assets,
            visibilityPolicy: policy ?? AssetVisibilityPolicy(scope: .timeline, dataManager: manager),
            isModal: true, viewModel: model ?? AssetDetailViewModel(repo: repository), recentlyViewedStore: store)
        return try await host(NavigationStack { viewer })
    }

    private func scroll(to index: Int, in window: UIWindow) async throws {
        let pager = try XCTUnwrap(pager(in: window.rootViewController))
        let collection = try XCTUnwrap(pager.view.subviews.first { $0 is UICollectionView } as? UICollectionView)
        try await waitUntil("The real pager has its page width") { collection.bounds.width > 0 }
        collection.setContentOffset(CGPoint(x: collection.bounds.width * CGFloat(index), y: 0), animated: true)
    }

    private func pager(in controller: UIViewController?) -> PhotoPagerController? {
        guard let controller else { return nil }
        if let pager = controller as? PhotoPagerController { return pager }
        return controller.children.lazy.compactMap { self.pager(in: $0) }.first
    }

    private func datePicker(in view: UIView) -> UIDatePicker? {
        if let picker = view as? UIDatePicker { return picker }
        return view.subviews.lazy.compactMap { self.datePicker(in: $0) }.first
    }

    private func recentButton(in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0 { return nil }
            if object.accessibilityLabel == "Recently Viewed", object.accessibilityTraits.contains(.button) { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let result = find(child, depth: depth + 1) { return result } }
            }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { if let result = find(child, depth: depth + 1) { return result } }
            }
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let result = find(child, depth: depth + 1) { return result }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }
}

@MainActor
private final class RecentlyViewedDetailRepository: AssetDetailRepository {
    private(set) var requests: [String] = []
    private(set) var completed: Set<Int> = []
    private var pending: [Int: CheckedContinuation<AssetResponseDTO, Error>] = [:]
    private(set) var favoriteWrites: [Bool] = []
    private(set) var savedDates: [Date] = []
    var rejectMutations = false
    var activeCount: Int { requests.count - completed.count }

    override func fetchAsset(_ id: String) async throws -> AssetResponseDTO {
        requests.append(id)
        let request = requests.count
        defer { completed.insert(request) }
        return try await withCheckedThrowingContinuation { pending[request] = $0 }
    }

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        if rejectMutations { throw APIError.server(status: 503, message: "Favorite rejected") }
        favoriteWrites.append(value)
    }

    override func updateDate(_ id: String, to date: Date) async throws {
        if rejectMutations { throw APIError.server(status: 503, message: "Date rejected") }
        savedDates.append(date)
    }

    func finish(_ request: Int, with result: Result<AssetResponseDTO, Error>) {
        guard let continuation = pending.removeValue(forKey: request) else {
            XCTFail("The held viewer request \(request) must exist")
            return
        }
        continuation.resume(with: result)
    }

    func finishAll() {
        for request in Array(pending.keys) { finish(request, with: .failure(CancellationError())) }
    }
}
