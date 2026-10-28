import XCTest
@testable import ImmichApp

@MainActor
final class TrashMutationLifecycleTests: XCTestCase {
    private var cleanup: [(URL, String)] = []

    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for (directory, key) in cleanup {
            LocalSnapshot.remove(key)
            try? FileManager.default.removeItem(at: directory)
        }
        cleanup.removeAll()
    }

    func testTrashVisibilitySurvivesSnapshotAndChangesContentWithoutChangingIdentity() throws {
        var dto = makeTestAsset(id: "archive", isArchived: true, isTrashed: true)
        dto.visibility = "archive"
        let archived = AssetLite(dto)
        let restored = try JSONDecoder().decode(AssetLite.self, from: JSONEncoder().encode(archived))
        XCTAssertEqual(restored.trashVisibility, "archive")
        XCTAssertTrue(restored.hasSameContent(as: archived))
        var timeline = archived
        timeline.trashVisibility = "timeline"
        XCTAssertEqual(timeline, archived)
        XCTAssertFalse(timeline.hasSameContent(as: archived))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archived)) as? [String: Any])
        object.removeValue(forKey: "trashVisibility")
        let legacy = try JSONDecoder().decode(AssetLite.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.trashVisibility)
        var live = makeTestAsset(id: dto.id, isArchived: true)
        live.visibility = "archive"
        XCTAssertNil(AssetLite(live).trashVisibility)
        dto.visibility = nil
        XCTAssertEqual(AssetLite(dto).trashVisibility, "archive", "Legacy archived server rows retain their classification")
    }

    func testRestoringFreshArchivedAndTimelineRowsPreservesTheirVisibilityAfterReopen() async throws {
        let fixture = try fixture()
        let archive = asset("archive", visibility: "archive")
        let timeline = asset("timeline", visibility: "timeline")
        let legacy = asset("legacy")
        try fixture.manager.setAssetVisibility([legacy.id], to: "archive")
        markTrashed([archive.id, timeline.id, legacy.id])
        let model = fixture.model([archive, timeline, legacy])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())

        _ = await model.restore([archive.id, timeline.id, legacy.id], using: repository)

        XCTAssertEqual(repository.requests, ["restore:archive,timeline,legacy"])
        XCTAssertTrue(model.assets.isEmpty)
        let reopened = fixture.reopen()
        XCTAssertEqual(Set(reopened.timelineAssets().map(\.asset.id)), [timeline.id])
        XCTAssertEqual(reopened.archivedAssetIDs, [archive.id, legacy.id])
        XCTAssertEqual(reopened.getCachedAsset(id: archive.id)?.isArchived, true)
        XCTAssertEqual(reopened.getCachedAsset(id: legacy.id)?.isArchived, true)
        XCTAssertEqual(reopened.getCachedAsset(id: timeline.id)?.isArchived, false)
    }

    func testOldTimelineHintCannotUndoAnArchiveAcceptedBeforeRestoreAdmission() async throws {
        let fixture = try fixture()
        let photo = asset("already-archived", visibility: "timeline")
        try fixture.manager.setAssetVisibility([photo.id], to: "archive")
        markTrashed([photo.id])
        let model = fixture.model([photo])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())

        _ = await model.restore([photo.id], using: repository)

        XCTAssertEqual(fixture.reopen().getCachedAsset(id: photo.id)?.isArchived, true)
        XCTAssertTrue(fixture.reopen().archivedAssetIDs.contains(photo.id))
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty)
    }

    func testDirectRestoreHintCannotReleaseKnownPrivateProtection() throws {
        let fixture = try fixture()
        let photo = asset("private", visibility: "timeline")
        try fixture.manager.setAssetVisibility([photo.id], to: "locked")

        try fixture.manager.restoreToTimeline([photo])

        XCTAssertTrue(fixture.reopen().privateAssetIDs.contains(photo.id))
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty)
    }

    private func markTrashed(_ ids: [String]) {
        RemovedAssets.shared.remove(ids, reason: .trashed)
        DeletedServerAssetRegistry.shared.record(ids, permanently: false)
    }

    private func asset(_ id: String, visibility: String? = nil) -> AssetLite {
        AssetLite(id: id, isVideo: false, ratio: 1.5, thumbhash: "hash", createdAt: .distantPast,
            isFavorite: true, trashVisibility: visibility)
    }

    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        cleanup.append((fixture.directory, fixture.key))
        return fixture
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let key = "trash-lifecycle-\(UUID())"
        let manager: SwiftDataManager
        let assetRepository = LifecycleAssetRepository(api: makeStubAPIClient())

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("trash-lifecycle-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("journal.json"))
            XCTAssertTrue(manager.isPersistentStoreAvailable)
        }

        func model(_ assets: [AssetLite]) -> AssetGridViewModel {
            let model = AssetGridViewModel(assetRepo: assetRepository, albumRepo: AlbumRepository(api: makeStubAPIClient()),
                snapshotKey: key, dataManager: manager, loader: { assets })
            model.assets = assets
            model.phase = .loaded(())
            return model
        }

        func reopen() -> SwiftDataManager {
            SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                backupJournalURL: directory.appendingPathComponent("journal.json"))
        }
    }
}

@MainActor
private final class LifecycleTrashGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async throws {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resolve(throwing error: Error? = nil) {
        guard let continuation else { return XCTFail("The operation must reach the held response first") }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

private final class LifecycleTrashRepository: TrashRepository {
    private let gate: LifecycleTrashGate?
    private(set) var requests: [String] = []
    var error: Error?

    init(api: APIClient, gate: LifecycleTrashGate? = nil) {
        self.gate = gate
        super.init(api: api)
    }

    override func restore(_ ids: [String]) async throws { try await perform("restore:" + ids.joined(separator: ",")) }
    override func restoreAll() async throws { try await perform("restoreAll") }
    override func empty() async throws { try await perform("empty") }

    private func perform(_ operation: String) async throws {
        requests.append(operation)
        if let gate { try await gate.wait() }
        if let error { throw error }
    }
}

private final class LifecycleAssetRepository: AssetDetailRepository {
    private(set) var deleteRequests: [[String]] = []
    override func delete(_ ids: [String], force: Bool = false) async throws { deleteRequests.append(ids) }
}
