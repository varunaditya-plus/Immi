import Observation
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import ImmichApp

@MainActor
final class RecentlyViewedActionsPresentationTests: SimulatorHostedTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var manager: SwiftDataManager?
    private var container: ModelContainer?
    private var fixture: RecentActionsFixture?
    private var mounted: RecentActionsMountedState?
    private weak var retainedStore: RecentlyViewedStore?
    private weak var retainedModel: AssetGridViewModel?
    private weak var retainedManager: SwiftDataManager?

    override func setUp() async throws {
        try await super.setUp()
        suite = "recently-viewed-actions.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        container = manager?.modelContainer
        retainedManager = manager
    }

    override func tearDown() async throws {
        fixture?.repository.finishAll()
        try await waitUntil("All held Recently Viewed mutations return before teardown") {
            (self.fixture?.repository.activeCount ?? 0) == 0
        }
        mounted?.content = nil
        try await waitUntil("The history collection unmounts from its still-mounted host") {
            self.windows.allSatisfy { self.grid(in: $0.rootViewController) == nil }
        }
        try await super.tearDown()
        fixture?.releaseDependencies()
        fixture = nil
        mounted = nil
        manager = nil
        try await waitUntil("The closed Recently Viewed collection releases its model, history and isolated cache") {
            self.retainedModel == nil && self.retainedStore == nil && self.retainedManager == nil
        }
        guard retainedManager == nil else { return }
        try container?.erase()
        container = nil
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    func testMountedContextFavoritePreservesAnIndependentVisitUpdateAfterSuccessAndRejection() async throws {
        for accepts in [true, false] {
            let fixture = try makeFixture()
            let window = try await show(fixture)
            let unrelated = fixture.photos[0], target = fixture.photos[1]
            let controller = try XCTUnwrap(grid(in: window.rootViewController))
            var action: PhotoGridMenuAction? = try XCTUnwrap(controller.menuActions?(target.id).first { $0.title == "Favorite" },
                "Use the mounted production grid's configured context action")

            action?.handler()
            action = nil

            try await waitUntil("The configured context action reaches the actual mutation repository") {
                fixture.repository.writes.count == 1
            }
            XCTAssertEqual(fixture.repository.writes.map(\.id), [target.id])
            XCTAssertEqual(fixture.repository.writes.map(\.value), [true])
            fixture.store.updateFavorite(unrelated.id, to: true)
            XCTAssertFalse(try XCTUnwrap(fixture.model.assets.first { $0.id == unrelated.id }).isFavorite,
                "The unrelated accepted history update must not refresh this held action's old model snapshot")
            fixture.repository.finish(1, accepts: accepts)
            try await waitUntil("The held context action publishes its accepted result or error") {
                accepts ? fixture.store.assets.first { $0.id == target.id }?.isFavorite == true
                    : fixture.model.actionError != nil
            }
            _ = try await screenshot(window)

            assertHistory(fixture, expected: [unrelated.id: true, target.id: accepts])
            XCTAssertEqual(fixture.repository.writes.count, 1)
            await unmountCurrentFixture()
        }
    }

    func testActualBulkFavoritePersistsOnlyAcceptedTargetsAndPreservesAnUnrelatedNewerFlag() async throws {
        let fixture = try makeFixture()
        let window = try await show(fixture)
        let unrelated = fixture.photos[0]
        let targets = Array(fixture.photos.dropFirst())
        try await activateAccessibilityButton(named: "Select", in: window)
        for photo in targets { try await selectPhoto(photo.id, in: window) }

        try await activateAccessibilityButton(named: "Favorite", in: window)

        try await waitUntil("The actual selection toolbar starts the first target's write") {
            fixture.repository.writes.count == 1
        }
        let first = try XCTUnwrap(fixture.repository.writes.first)
        XCTAssertTrue(targets.contains { $0.id == first.id })
        fixture.repository.finish(1, accepts: true)
        try await waitUntil("The next bulk target is held after the first success") {
            fixture.repository.writes.count == 2
        }
        let rejected = fixture.repository.writes[1]
        XCTAssertNotEqual(first.id, rejected.id)
        fixture.store.updateFavorite(unrelated.id, to: true)
        XCTAssertFalse(try XCTUnwrap(fixture.model.assets.first { $0.id == unrelated.id }).isFavorite)
        fixture.repository.finish(2, accepts: false)
        try await waitUntil("The rejected bulk target reports the actual mutation error") { fixture.model.actionError != nil }
        _ = try await screenshot(window)

        assertHistory(fixture, expected: [unrelated.id: true, first.id: true, rejected.id: false])
        XCTAssertEqual(fixture.repository.writes.count, 2, "The batch must stop after the first rejection")
        XCTAssertTrue(fixture.repository.writes.allSatisfy(\.value))
        let untouched = try XCTUnwrap(targets.first { $0.id != first.id && $0.id != rejected.id })
        XCTAssertFalse(try XCTUnwrap(fixture.store.assets.first { $0.id == untouched.id }).isFavorite)
    }

    private func makeFixture() throws -> RecentActionsFixture {
        let store = RecentlyViewedStore(owner: BackupQueueOwner(server: "https://recent-actions.example/api", userID: suite),
            defaults: defaults, dataManager: manager)
        let photos = (0..<4).map { _ in makeTestAsset(id: UUID().uuidString) }
        for photo in photos { store.record(photo) }
        let api = makeStubAPIClient()
        let repository = RecentActionsRepository(api: api)
        let model = AssetGridViewModel(assetRepo: repository, albumRepo: AlbumRepository(api: api),
            dataManager: manager) { store.assets }
        let fixture = RecentActionsFixture(store: store, model: model, repository: repository, photos: photos)
        self.fixture = fixture
        retainedStore = store
        retainedModel = model
        return fixture
    }

    private func show(_ fixture: RecentActionsFixture) async throws -> UIWindow {
        let screen = RecentlyViewedCollectionView(store: fixture.store, viewModel: fixture.model)
        let mounted = RecentActionsMountedState(AnyView(NavigationStack { screen }))
        self.mounted = mounted
        let window = try await host(RecentActionsMountedHost(state: mounted))
        try await waitUntil("The mounted history grid and its action model load the same visits") {
            self.grid(in: window.rootViewController) != nil && fixture.model.assets.count == fixture.photos.count
        }
        return window
    }

    private func assertHistory(_ fixture: RecentActionsFixture, expected: [String: Bool],
                               file: StaticString = #filePath, line: UInt = #line) {
        let reopened = RecentlyViewedStore(owner: BackupQueueOwner(server: "https://recent-actions.example/api", userID: suite),
            defaults: defaults, dataManager: manager)
        let expectedOrder = fixture.photos.reversed().map(\.id)
        XCTAssertEqual(fixture.store.assets.map(\.id), expectedOrder, file: file, line: line)
        XCTAssertEqual(reopened.assets.map(\.id), expectedOrder, file: file, line: line)
        for (id, flag) in expected {
            XCTAssertEqual(fixture.store.assets.first { $0.id == id }?.isFavorite, flag, file: file, line: line)
            XCTAssertEqual(reopened.assets.first { $0.id == id }?.isFavorite, flag, file: file, line: line)
        }
    }

    private func unmountCurrentFixture() async {
        mounted?.content = nil
        fixture?.repository.finishAll()
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows.removeAll()
        fixture?.releaseDependencies()
        fixture = nil
        mounted = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func selectPhoto(_ id: String, in window: UIWindow) async throws {
        let controller = try XCTUnwrap(grid(in: window.rootViewController))
        let collection = try XCTUnwrap(collection(in: controller.view))
        try await waitUntil("The actual Select control puts the production collection into editing mode") { collection.isEditing }
        let path = try XCTUnwrap(controller.revealCell(for: id))
        try await waitUntil("The actual selection cell is rendered") { collection.cellForItem(at: path) != nil }
        XCTAssertTrue(try XCTUnwrap(collection.cellForItem(at: path)).accessibilityActivate())
        try await waitUntil("The actual cell becomes selected") { collection.indexPathsForSelectedItems?.contains(path) == true }
    }

    private func grid(in controller: UIViewController?) -> PhotoGridController? {
        guard let controller else { return nil }
        if let grid = controller as? PhotoGridController { return grid }
        return controller.children.lazy.compactMap { self.grid(in: $0) }.first
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }
}

@MainActor
@Observable
private final class RecentActionsMountedState {
    var content: AnyView?
    init(_ content: AnyView) { self.content = content }
}

private struct RecentActionsMountedHost: View {
    let state: RecentActionsMountedState
    var body: some View { state.content }
}

@MainActor
private final class RecentActionsFixture {
    private var dependencies: (RecentlyViewedStore, AssetGridViewModel, RecentActionsRepository)?
    var store: RecentlyViewedStore { dependencies!.0 }
    var model: AssetGridViewModel { dependencies!.1 }
    var repository: RecentActionsRepository { dependencies!.2 }
    let photos: [AssetResponseDTO]
    init(store: RecentlyViewedStore, model: AssetGridViewModel, repository: RecentActionsRepository, photos: [AssetResponseDTO]) {
        dependencies = (store, model, repository)
        self.photos = photos
    }
    func releaseDependencies() { dependencies = nil }
}

@MainActor
private final class RecentActionsRepository: AssetDetailRepository {
    struct Write { let id: String; let value: Bool }
    private(set) var writes: [Write] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    var activeCount: Int { pending.count }

    override func toggleFavorite(_ id: String, to value: Bool) async throws {
        writes.append(Write(id: id, value: value))
        let index = writes.count
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finish(_ index: Int, accepts: Bool) {
        guard let continuation = pending.removeValue(forKey: index) else { return XCTFail("The held favorite request must exist") }
        if accepts { continuation.resume() }
        else { continuation.resume(throwing: APIError.server(status: 503, message: "Favorite rejected")) }
    }

    func finishAll() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}
