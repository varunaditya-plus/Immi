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

        let succeeded = await model.restore([archive.id, timeline.id, legacy.id], using: repository)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(repository.requests, ["restore:archive,timeline,legacy"])
        XCTAssertTrue(model.assets.isEmpty)
        let reopened = fixture.reopen()
        XCTAssertEqual(Set(reopened.timelineAssets().map(\.asset.id)), [timeline.id])
        XCTAssertEqual(reopened.archivedAssetIDs, [archive.id, legacy.id])
        XCTAssertEqual(reopened.getCachedAsset(id: archive.id)?.isArchived, true)
        XCTAssertEqual(reopened.getCachedAsset(id: legacy.id)?.isArchived, true)
        XCTAssertEqual(reopened.getCachedAsset(id: timeline.id)?.isArchived, false)
    }

    func testStaleRestoreHintCannotUndoNewerArchiveOrPrivateState() async throws {
        for visibility in ["archive", "locked"] {
            let fixture = try fixture()
            let photo = asset("changed-\(visibility)", visibility: "timeline")
            markTrashed([photo.id])
            let model = fixture.model([photo])
            let gate = LifecycleTrashGate(started: expectation(description: "Restore is held"))
            let repository = LifecycleTrashRepository(api: makeStubAPIClient(), gate: gate)
            let pending = Task { await model.restore([photo.id], using: repository) }
            await fulfillment(of: [gate.started], timeout: 2)
            try fixture.manager.setAssetVisibility([photo.id], to: visibility)
            gate.resolve()
            let succeeded = await pending.value

            XCTAssertTrue(succeeded)
            XCTAssertTrue(fixture.manager.timelineAssets().isEmpty)
            XCTAssertFalse(DeletedServerAssetRegistry.shared.isTrashed(photo.id))
            XCTAssertTrue(RemovedAssets.shared.contains(photo.id, scope: .trash))
            if visibility == "locked" {
                XCTAssertTrue(fixture.manager.privateAssetIDs.contains(photo.id))
                XCTAssertNil(fixture.manager.getCachedAsset(id: photo.id), "Private metadata must not be reconstructed from a public snapshot")
            } else {
                XCTAssertEqual(fixture.reopen().getCachedAsset(id: photo.id)?.isArchived, true)
            }
        }
    }

    func testUnrelatedVisibilityChangeDuringRestoreCannotRecreateAnArchivedPhotoInTimeline() async throws {
        let fixture = try fixture()
        let archived = asset("unknown-archive", visibility: "archive")
        markTrashed([archived.id])
        let model = fixture.model([archived])
        let gate = LifecycleTrashGate(started: expectation(description: "Archive restore is held"))
        let repository = LifecycleTrashRepository(api: makeStubAPIClient(), gate: gate)
        let pending = Task { await model.restore([archived.id], using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        try fixture.manager.setAssetVisibility(["unrelated-photo"], to: "archive")
        gate.resolve()
        let succeeded = await pending.value

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertFalse(DeletedServerAssetRegistry.shared.isTrashed(archived.id))
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty,
            "An unrelated mutation must never turn a restored archived photo into a public timeline row")
        XCTAssertNil(fixture.manager.getCachedAsset(id: archived.id),
            "An unclassified row waits for authoritative sync after its hint context changes")
    }

    func testOldTimelineHintCannotUndoAnArchiveAcceptedBeforeRestoreAdmission() async throws {
        let fixture = try fixture()
        let photo = asset("already-archived", visibility: "timeline")
        try fixture.manager.setAssetVisibility([photo.id], to: "archive")
        markTrashed([photo.id])
        let model = fixture.model([photo])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())

        let succeeded = await model.restore([photo.id], using: repository)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fixture.reopen().getCachedAsset(id: photo.id)?.isArchived, true)
        XCTAssertTrue(fixture.reopen().archivedAssetIDs.contains(photo.id))
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty)
    }

    func testStaleTrashWindowCannotWriteARestoredRowBackToTheOfflineSnapshot() async throws {
        let fixture = try fixture()
        defer { LocalSnapshot.remove(LocalSnapshot.Key.trash) }
        let restored = asset("restored-elsewhere"), remaining = asset("remaining-trash")
        markTrashed([restored.id, remaining.id])
        let model = AssetGridViewModel(assetRepo: fixture.assetRepository,
            albumRepo: AlbumRepository(api: makeStubAPIClient()), snapshotKey: LocalSnapshot.Key.trash,
            dataManager: fixture.manager, loader: { [restored, remaining] })
        model.assets = [restored, remaining]
        RemovedAssets.shared.restoreFromTrash([restored.id])
        DeletedServerAssetRegistry.shared.restore([restored.id])
        LocalSnapshot.save([remaining], for: LocalSnapshot.Key.trash)
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())

        let succeeded = await model.restore([remaining.id], using: repository)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.assets.map(\.id), [restored.id], "The other window can retain old in-memory input")
        RemovedAssets.shared.clear()
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: LocalSnapshot.Key.trash)?.count, 0,
            "A later persistence operation must not resurrect the restored row on the next offline launch")
    }

    func testDirectRestoreHintCannotReleaseKnownPrivateProtection() throws {
        let fixture = try fixture()
        let photo = asset("private", visibility: "timeline")
        try fixture.manager.setAssetVisibility([photo.id], to: "locked")

        try fixture.manager.restoreToTimeline([photo])

        XCTAssertTrue(fixture.reopen().privateAssetIDs.contains(photo.id))
        XCTAssertTrue(fixture.reopen().timelineAssets().isEmpty)
    }

    func testRestoredPhotoInAnotherWindowCannotBeRestoredOrPermanentlyDeletedAgain() async throws {
        let fixture = try fixture()
        let photo = asset("two-windows")
        try fixture.manager.linkDeviceAsset(localIdentifier: "local-restored", to: photo.id)
        markTrashed([photo.id])
        let first = fixture.model([photo]), second = fixture.model([photo])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())
        let firstResult = await first.restore([photo.id], using: repository)
        XCTAssertTrue(firstResult)

        let secondRestore = await second.restore([photo.id], using: repository)
        let secondDelete = await second.delete([photo.id], permanently: true)

        XCTAssertFalse(secondRestore)
        XCTAssertFalse(secondDelete)
        XCTAssertEqual(repository.requests, ["restore:two-windows"])
        XCTAssertTrue(fixture.assetRepository.deleteRequests.isEmpty)
        let library = AssetVisibilityPolicy(dataManager: fixture.manager)
        let trash = AssetVisibilityPolicy(removalScope: .trash, dataManager: fixture.manager)
        XCTAssertTrue(library.allows(id: photo.id))
        XCTAssertFalse(trash.allows(id: photo.id))
        XCTAssertTrue(library.allows(id: "device:local-restored"))
        XCTAssertFalse(trash.allows(id: "device:local-restored"), "Point checks must not bypass the mapped restored marker")
        XCTAssertTrue(trash.filter([asset("device:local-restored")]).isEmpty)
        XCTAssertNotNil(fixture.reopen().getCachedAsset(id: photo.id))
    }

    func testOnlyFreshTrashEvidenceReadmitsRestoredRowsAndUnavailableRowsStayHidden() {
        let removed = RemovedAssets()
        removed.remove(["restored"], reason: .trashed)
        let stale = removed.trashRevision
        removed.restoreFromTrash(["restored"])
        XCTAssertFalse(removed.confirmTrashed(["restored"], expectedRevision: stale))
        XCTAssertTrue(removed.contains("restored", scope: .trash))
        let fresh = removed.trashRevision
        XCTAssertTrue(removed.confirmTrashed(["restored"], expectedRevision: fresh))
        XCTAssertFalse(removed.contains("restored", scope: .trash))
        XCTAssertTrue(removed.contains("restored", scope: .library))
        removed.remove(["unavailable"], reason: .unavailable)
        XCTAssertTrue(removed.confirmTrashed(["unavailable"], expectedRevision: removed.trashRevision))
        XCTAssertTrue(removed.contains("unavailable", scope: .trash))
    }

    func testHeldBulkActionsDoNotReleaseOrPermanentlyDeleteNewTrashOrSameIDRetrash() async throws {
        for empty in [false, true] {
            let fixture = try fixture()
            let original = asset("original-\(empty)")
            let retrash = asset("retrash-\(empty)")
            let new = asset("new-\(empty)")
            let discovered = asset("discovered-\(empty)")
            markTrashed([original.id, retrash.id])
            let model = fixture.model([original, retrash])
            let gate = LifecycleTrashGate(started: expectation(description: "Bulk operation is held"))
            let repository = LifecycleTrashRepository(api: makeStubAPIClient(), gate: gate)
            let pending = Task {
                if empty { return await model.emptyTrash(using: repository) }
                return await model.restoreAll(using: repository)
            }
            await fulfillment(of: [gate.started], timeout: 2)
            RemovedAssets.shared.restoreFromTrash([retrash.id])
            DeletedServerAssetRegistry.shared.restore([retrash.id])
            markTrashed([retrash.id, new.id])
            // A row fetched while the original bulk request was held must also
            // survive if it was trashed after that request began.
            model.assets.append(new)
            // Another read can discover server Trash while this response is
            // held. That read supplies no evidence it belonged to the bulk's
            // starting membership, even without a local mutation stamp.
            XCTAssertTrue(RemovedAssets.shared.confirmTrashed([discovered.id],
                expectedRevision: RemovedAssets.shared.trashRevision))
            DeletedServerAssetRegistry.shared.record([discovered.id], permanently: false)
            model.assets.append(discovered)
            gate.resolve()
            let succeeded = await pending.value

            XCTAssertTrue(succeeded)
            XCTAssertEqual(Set(model.assets.map(\.id)), [retrash.id, new.id, discovered.id])
            for photo in [retrash, new, discovered] {
                XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(photo.id))
                XCTAssertFalse(DeletedServerAssetRegistry.shared.isPermanentlyDeleted(photo.id))
                XCTAssertFalse(RemovedAssets.shared.contains(photo.id, scope: .trash))
                XCTAssertNil(fixture.manager.getCachedAsset(id: photo.id))
            }
            if empty {
                XCTAssertTrue(DeletedServerAssetRegistry.shared.isPermanentlyDeleted(original.id))
                XCTAssertTrue(RemovedAssets.shared.contains(original.id, scope: .trash))
            } else {
                XCTAssertFalse(DeletedServerAssetRegistry.shared.isTrashed(original.id))
                XCTAssertTrue(RemovedAssets.shared.contains(original.id, scope: .trash))
                XCTAssertNotNil(fixture.reopen().getCachedAsset(id: original.id))
            }
        }
    }

    func testAcceptedBulkWithNoKnownRowsStillInvalidatesHeldQueries() async throws {
        let fixture = try fixture()
        let model = fixture.model([])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())
        let beforeRestore = RemovedAssets.shared.trashRevision
        let restored = await model.restoreAll(using: repository)
        XCTAssertTrue(restored)
        XCTAssertNotEqual(RemovedAssets.shared.trashRevision, beforeRestore)
        let beforeEmpty = RemovedAssets.shared.trashRevision
        let emptied = await model.emptyTrash(using: repository)
        XCTAssertTrue(emptied)
        XCTAssertNotEqual(RemovedAssets.shared.trashRevision, beforeEmpty)
        XCTAssertEqual(repository.requests, ["restoreAll", "empty"])
    }

    func testEmptyTrashPurgesCachedMetadataAndMakesOnlyConfirmedRowsPermanentlyUnavailable() async throws {
        let fixture = try fixture()
        let photo = asset("cached-trash")
        try fixture.manager.restoreToTimeline([photo])
        markTrashed([photo.id])
        let model = fixture.model([photo])
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())

        let succeeded = await model.emptyTrash(using: repository)

        XCTAssertTrue(succeeded)
        XCTAssertNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertTrue(DeletedServerAssetRegistry().isPermanentlyDeleted(photo.id))
        XCTAssertTrue(RemovedAssets.shared.contains(photo.id, scope: .trash))
    }

    func testCancelledActionsDoNotAdmitRequestsOrApplyLateSuccessfulCallbacks() async throws {
        let fixture = try fixture()
        let photo = asset("cancelled")
        markTrashed([photo.id])
        let model = fixture.model([photo])
        let gate = LifecycleTrashGate(started: expectation(description: "Cancelled restore started"))
        let repository = LifecycleTrashRepository(api: makeStubAPIClient(), gate: gate)
        let before = fixture.manager.assetMutationRevision
        let pending = Task { await model.restore([photo.id], using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        pending.cancel()
        gate.resolve()
        let succeeded = await pending.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.assets.map(\.id), [photo.id])
        XCTAssertNil(model.actionError)
        XCTAssertEqual(fixture.manager.assetMutationRevision, before)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(photo.id))
        XCTAssertFalse(RemovedAssets.shared.contains(photo.id, scope: .trash))

        let cancelled = Task { () -> [Bool] in
            withUnsafeCurrentTask { $0?.cancel() }
            return [await model.restore([photo.id], using: repository),
                await model.restoreAll(using: repository), await model.emptyTrash(using: repository),
                await model.delete([photo.id], permanently: true)]
        }
        let results = await cancelled.value
        XCTAssertEqual(results, [false, false, false, false])
        XCTAssertEqual(repository.requests, ["restore:cancelled"])
        XCTAssertTrue(fixture.assetRepository.deleteRequests.isEmpty)
    }

    func testLatePreviousAccountFailureCannotPublishAnActionError() async throws {
        let fixture = try fixture()
        let photo = asset("old-account")
        markTrashed([photo.id])
        let model = fixture.model([photo])
        let gate = LifecycleTrashGate(started: expectation(description: "Old restore is held"))
        let repository = LifecycleTrashRepository(api: makeStubAPIClient(), gate: gate)
        let pending = Task { await model.restore([photo.id], using: repository) }
        await fulfillment(of: [gate.started], timeout: 2)
        LocalSnapshot.clearAll()
        DeletedServerAssetRegistry.shared.clear()
        DeletedServerAssetRegistry.shared.record(["current-account"], permanently: false)
        gate.resolve(throwing: APIError.server(status: 403, message: "Old error"))
        let succeeded = await pending.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(model.actionError)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("current-account"))
        XCTAssertNil(fixture.manager.getCachedAsset(id: photo.id))
    }

    func testFailedRestoreReturnsFalsePreservesSnapshotAndAllowsSuccessfulRetry() async throws {
        let fixture = try fixture()
        let photo = asset("retry")
        markTrashed([photo.id])
        let model = fixture.model([photo])
        LocalSnapshot.save([photo], for: fixture.key)
        let repository = LifecycleTrashRepository(api: makeStubAPIClient())
        repository.error = APIError.server(status: 403, message: "Restore rejected")
        let failed = await model.restore([photo.id], using: repository)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.actionError, "Restore rejected")
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.key)?.map(\.id), [photo.id])
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed(photo.id))
        repository.error = nil

        let succeeded = await model.restore([photo.id], using: repository)

        XCTAssertTrue(succeeded)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: fixture.key)?.count, 0)
        XCTAssertNotNil(fixture.reopen().getCachedAsset(id: photo.id))
        XCTAssertEqual(repository.requests, ["restore:retry", "restore:retry"])
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
