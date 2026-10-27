import XCTest
@testable import ImmichApp

@MainActor
final class AccountMutationIsolationTests: XCTestCase {
    override func setUp() async throws {
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.clear()
        RemovedAssets.shared.clear()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.clear()
        RemovedAssets.shared.clear()
    }

    func testPreviousAccountsRestoreCannotInsertPhotosOrChangeCurrentDeletionRegistry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let photo = asset("previous-account-photo")
        let model = grid(dataManager: fixture.dataManager, assets: [photo])
        let gate = MutationResultGate(started: expectation(description: "Restore request started"))
        let repository = HeldMutationTrashRepository(api: makeStubAPIClient(), gate: gate)
        let restoration = Task { await model.restore([photo.id], using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)

        LocalSnapshot.clearAll()
        try fixture.dataManager.clearAllAccountData()
        try fixture.dataManager.restoreToTimeline([asset("next-account-photo")])
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: false)
        // The repository returns success after the switch. This tests the
        // model's storage boundary independently of API response validation.
        gate.resume()
        await restoration.value

        XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), ["next-account-photo"])
        XCTAssertNil(fixture.dataManager.getCachedAsset(id: photo.id))
        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.contains(photo.id))
        XCTAssertEqual(model.assets.map(\.id), [photo.id])
        let restoredStore = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
        XCTAssertEqual(restoredStore.timelineAssets().map(\.asset.id), ["next-account-photo"])
    }

    func testCurrentAccountsRestoreStillPersistsPhotoAndClearsDeletionRegistry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let photo = asset("current-account-photo")
        let model = grid(dataManager: fixture.dataManager, assets: [photo])
        DeletedServerAssetRegistry.shared.record([photo.id], permanently: false)
        let gate = MutationResultGate(started: expectation(description: "Current restore started"))
        let repository = HeldMutationTrashRepository(api: makeStubAPIClient(), gate: gate)
        let restoration = Task { await model.restore([photo.id], using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        gate.resume()
        await restoration.value

        XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), [photo.id])
        XCTAssertEqual(fixture.dataManager.getCachedAsset(id: photo.id)?.ratio, photo.ratio)
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains(photo.id))
        XCTAssertTrue(model.assets.isEmpty)
        let restoredStore = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)
        XCTAssertNotNil(restoredStore.getCachedAsset(id: photo.id))
    }

    func testPreviousAccountsArchiveCannotHideCurrentAccountsCachedPhoto() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let photo = asset("shared-id")
        let gate = MutationResultGate(started: expectation(description: "Archive started"))
        let repository = HeldMutationAssetRepository(api: makeStubAPIClient(), gate: gate)
        let model = grid(dataManager: fixture.dataManager, assets: [photo], repository: repository)
        let archive = Task { await model.setArchived([photo.id], to: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        try fixture.dataManager.clearAllAccountData()
        try fixture.dataManager.restoreToTimeline([photo])
        gate.resume()
        let succeeded = await archive.value

        XCTAssertFalse(succeeded)
        XCTAssertEqual(fixture.dataManager.getCachedAsset(id: photo.id)?.isArchived, false)
        XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), [photo.id])
    }

    func testPreviousAccountsTimelineDeleteCannotPurgeCurrentAccountsCachedPhoto() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let photo = asset("shared-id")
        let gate = MutationResultGate(started: expectation(description: "Delete started"))
        let repository = HeldMutationAssetRepository(api: makeStubAPIClient(), gate: gate)
        let model = TimelineViewModel(dataManager: fixture.dataManager, assetRepo: repository)
        let deletion = Task { await model.delete(photo) }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        try fixture.dataManager.clearAllAccountData()
        try fixture.dataManager.restoreToTimeline([photo])
        gate.resume()
        let succeeded = await deletion.value

        XCTAssertFalse(succeeded)
        XCTAssertNotNil(fixture.dataManager.getCachedAsset(id: photo.id))
        XCTAssertFalse(RemovedAssets.shared.ids.contains(photo.id))
    }

    func testPreviousAccountsRestoreAllCannotClearCurrentDeletionRegistry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = grid(dataManager: fixture.dataManager, assets: [])
        let gate = MutationResultGate(started: expectation(description: "Restore all started"))
        let repository = HeldMutationTrashRepository(api: makeStubAPIClient(), gate: gate)
        let restoration = Task { await model.restoreAll(using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.record(["next-account-trash"], permanently: false)
        gate.resume()
        await restoration.value

        XCTAssertTrue(DeletedServerAssetRegistry.shared.suppressedIDs.contains("next-account-trash"))
    }

    func testPreviousAccountsEmptyTrashCannotMakeCurrentTrashPermanent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = grid(dataManager: fixture.dataManager, assets: [])
        let gate = MutationResultGate(started: expectation(description: "Empty trash started"))
        let repository = HeldMutationTrashRepository(api: makeStubAPIClient(), gate: gate)
        let emptying = Task { await model.emptyTrash(using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.record(["next-account-trash"], permanently: false)
        gate.resume()
        await emptying.value

        DeletedServerAssetRegistry.shared.restoreAllFromTrash()
        XCTAssertFalse(DeletedServerAssetRegistry.shared.suppressedIDs.contains("next-account-trash"))
    }

    private func grid(
        dataManager: SwiftDataManager, assets: [AssetLite],
        repository: AssetDetailRepository? = nil
    ) -> AssetGridViewModel {
        let model = AssetGridViewModel(
            assetRepo: repository ?? MockAssetDetailRepository(api: makeStubAPIClient()),
            albumRepo: MockAlbumRepository(api: makeStubAPIClient()),
            dataManager: dataManager,
            loader: { assets })
        model.assets = assets
        return model
    }

    private func asset(_ id: String) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1.5, thumbhash: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), isFavorite: true)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let dataManager: SwiftDataManager
        var storeURL: URL { directory.appendingPathComponent("test.store") }
        var journalURL: URL { directory.appendingPathComponent("journal.json") }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutation-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataManager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("journal.json"))
        XCTAssertTrue(dataManager.isPersistentStoreAvailable)
        return Fixture(directory: directory, dataManager: dataManager)
    }
}

@MainActor
private final class MutationResultGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resume() {
        XCTAssertNotNil(continuation, "The operation must reach its response boundary first")
        continuation?.resume()
        continuation = nil
    }
}

private final class HeldMutationTrashRepository: TrashRepository {
    private let gate: MutationResultGate

    init(api: APIClient, gate: MutationResultGate) {
        self.gate = gate
        super.init(api: api)
    }

    override func restore(_ ids: [String]) async throws { await gate.wait() }
    override func restoreAll() async throws { await gate.wait() }
    override func empty() async throws { await gate.wait() }
}

private final class HeldMutationAssetRepository: AssetDetailRepository {
    private let gate: MutationResultGate

    init(api: APIClient, gate: MutationResultGate) {
        self.gate = gate
        super.init(api: api)
    }

    override func setVisibility(_ id: String, to value: Visibility) async throws { await gate.wait() }
    override func delete(_ id: String) async throws { await gate.wait() }
}
