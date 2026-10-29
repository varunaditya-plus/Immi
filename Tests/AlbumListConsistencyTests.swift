import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumListConsistencyTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    func testSameIDMetadataPublishesWhenAnotherModelAlreadySavedTheFetchedBytes() async {
        let driver = AlbumListDriver()
        let model = model(driver)
        model.albums = [album("one", name: "Old", count: 1, cover: "old-cover")]
        let fetched = album("one", name: "Renamed", count: 7, cover: "new-cover")
        LocalSnapshot.save([fetched], for: LocalSnapshot.Key.albumsList)
        XCTAssertFalse(LocalSnapshot.save([fetched], for: LocalSnapshot.Key.albumsList))
        driver.list = { [fetched] }
        let changed = AlbumPublicationProbe()
        withObservationTracking {
            _ = model.albums
        } onChange: { MainActor.assumeIsolated { changed.didPublish = true } }

        await model.loadAlbums()

        XCTAssertTrue(changed.didPublish, "Fresh same-ID metadata must invalidate the rendered list")
        XCTAssertEqual(model.albums.first?.albumName, "Renamed")
        XCTAssertEqual(model.albums.first?.assetCount, 7)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "new-cover")
        XCTAssertEqual(cached().first?.albumName, "Renamed")
    }

    func testValidFetchedDataStillPublishesWhenSnapshotCannotBeWritten() async throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("immich-snapshots")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory)
        let driver = AlbumListDriver()
        let model = model(driver)
        model.albums = [album("old")]
        driver.list = { [self.album("new", name: "Fetched despite disk failure")] }

        await model.loadAlbums()

        XCTAssertEqual(model.albums.map(\.id), ["new"])
        XCTAssertEqual(model.albums.first?.albumName, "Fetched despite disk failure")
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList))
    }

    func testAnAuthoritativeEmptyListIsNotRehydratedFromAStaleSnapshotOnLaterLoads() async {
        for delete in [false, true] {
            LocalSnapshot.clearAll()
            let oldAlbum = album("removed")
            LocalSnapshot.save([oldAlbum], for: LocalSnapshot.Key.albumsList)
            let driver = AlbumListDriver()
            driver.list = { delete ? [oldAlbum] : [] }
            let model = model(driver)
            await model.loadAlbums()
            if delete { await model.deleteAlbum("removed") }
            XCTAssertTrue(model.albums.isEmpty)
            XCTAssertNotNil(model.phase.value)

            // An older caller may leave readable bytes after this model has
            // already confirmed an empty response or a successful deletion.
            LocalSnapshot.save([oldAlbum], for: LocalSnapshot.Key.albumsList)
            let held = ConsistencyGate<[AlbumResponseDTO]>()
            driver.list = { try await held.value() }
            let reload = Task { await model.loadAlbums() }
            addTeardownBlock { await held.complete(.failure(CancellationError())); await reload.value }
            await fulfillment(of: [held.started], timeout: 2)

            XCTAssertTrue(model.albums.isEmpty, "Later loads preserve the authoritative in-memory result")
            XCTAssertNotNil(model.phase.value)
            held.complete(.failure(APIError.unknown))
            await reload.value
            XCTAssertTrue(model.albums.isEmpty)
            XCTAssertNotNil(model.phase.value, "A network failure does not erase a previously verified empty list")

            driver.list = { [self.album("fresh")] }
            await model.loadAlbums()
            XCTAssertEqual(model.albums.map(\.id), ["fresh"])
            XCTAssertEqual(cached().map(\.id), ["fresh"])
        }
    }

    func testNewerLoadWinsOverAnOlderSuccessAndItsDiskWrite() async throws {
        let driver = AlbumListDriver()
        let old = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { [weak driver] in
            driver?.listCalls == 1 ? try await old.value() : [self.album("current", name: "Current")]
        }
        let model = model(driver)
        let first = Task { await model.loadAlbums() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await first.value }
        await fulfillment(of: [old.started], timeout: 2)
        await model.loadAlbums()
        old.complete(.success([album("obsolete")]))
        await first.value

        XCTAssertEqual(model.albums.map(\.id), ["current"])
        XCTAssertEqual(cached().map(\.id), ["current"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertEqual(driver.listCalls, 2)
    }

    func testOlderFailureCannotReplaceANewerLoadedPhase() async {
        let driver = AlbumListDriver()
        let old = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { [weak driver] in driver?.listCalls == 1 ? try await old.value() : [] }
        let model = model(driver)
        let first = Task { await model.loadAlbums() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await first.value }
        await fulfillment(of: [old.started], timeout: 2)
        await model.loadAlbums()
        old.complete(.failure(APIError.unknown))
        await first.value

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
    }

    func testCanceledCurrentLoadCannotPublishAnIgnoredCancellationResponse() async {
        let driver = AlbumListDriver()
        let held = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { try await held.value() }
        let model = model(driver)
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [held.started], timeout: 2)
        load.cancel()
        held.complete(.success([album("canceled")]))
        await load.value

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(model.phase.isIdle)
        XCTAssertTrue(cached().isEmpty)
        driver.list = { [self.album("retry")] }
        await model.loadAlbums()
        XCTAssertEqual(model.albums.map(\.id), ["retry"])
    }

    func testAcceptedDeletionCannotBeUndoneByAHeldOlderList() async {
        let driver = AlbumListDriver()
        let held = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { try await held.value() }
        let model = model(driver)
        let initial = [album("deleted"), album("kept")]
        model.albums = initial
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [held.started], timeout: 2)
        await model.deleteAlbum("deleted")
        held.complete(.success(initial))
        await load.value

        XCTAssertEqual(model.albums.map(\.id), ["kept"])
        XCTAssertEqual(cached().map(\.id), ["kept"])
        XCTAssertNil(model.actionError)
    }

    func testAListStartedDuringDeletionAlsoCannotRestoreTheAcceptedDeletion() async {
        let driver = AlbumListDriver()
        let deletion = ConsistencyGate<Void>()
        let listing = ConsistencyGate<[AlbumResponseDTO]>()
        driver.delete = { _ in try await deletion.value() }
        driver.list = { try await listing.value() }
        let model = model(driver)
        let initial = [album("deleted"), album("kept")]
        model.albums = initial
        let delete = Task { await model.deleteAlbum("deleted") }
        addTeardownBlock { await deletion.complete(.failure(CancellationError())); _ = await delete.value }
        await fulfillment(of: [deletion.started], timeout: 2)
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await listing.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [listing.started], timeout: 2)
        deletion.complete(.success(()))
        let confirmed = await delete.value
        XCTAssertTrue(confirmed)
        listing.complete(.success(initial))
        await load.value

        XCTAssertEqual(model.albums.map(\.id), ["kept"])
        XCTAssertEqual(cached().map(\.id), ["kept"])
    }

    func testARejectedMutationLeavesAValidListResponseUsable() async {
        let driver = AlbumListDriver()
        let held = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { try await held.value() }
        driver.delete = { _ in throw APIError.unknown }
        let model = model(driver)
        model.albums = [album("original")]
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [held.started], timeout: 2)
        await model.deleteAlbum("original")
        XCTAssertNotNil(model.actionError)
        held.complete(.success([album("original", name: "Fresh server metadata"), album("new")]))
        await load.value

        XCTAssertEqual(model.albums.map(\.id), ["original", "new"])
        XCTAssertEqual(model.albums.first?.albumName, "Fresh server metadata")
        XCTAssertEqual(cached().map(\.id), ["original", "new"])
    }

    func testCreateAndMetadataCallbackEachInvalidateAPreviousListResponse() async {
        for create in [false, true] {
            LocalSnapshot.clearAll()
            let driver = AlbumListDriver()
            let held = ConsistencyGate<[AlbumResponseDTO]>()
            driver.list = { try await held.value() }
            driver.create = { self.album("created", name: "Created") }
            let model = model(driver)
            model.albums = [album("existing", name: "Old")]
            let load = Task { await model.loadAlbums() }
            addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
            await fulfillment(of: [held.started], timeout: 2)
            if create {
                let error = await model.createAlbum(name: "Created", description: "", assetIds: [])
                XCTAssertNil(error)
            } else {
                var updated = album("existing", name: "Renamed")
                updated.description = "Saved"
                model.applyAlbumUpdate(updated)
            }
            held.complete(.success([album("existing", name: "Old")]))
            await load.value

            XCTAssertEqual(model.albums.map(\.albumName), create ? ["Old", "Created"] : ["Renamed"])
            XCTAssertEqual(cached().map(\.albumName), model.albums.map(\.albumName))
            if !create { XCTAssertEqual(model.albums.first?.description, "Saved") }
        }
    }

    func testContentsAndMetadataCallbacksPreserveEachOthersConfirmedFieldsAndRejectOldLists() async {
        let driver = AlbumListDriver()
        let held = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { try await held.value() }
        let model = model(driver)
        let capturedEdit = album("album", name: "New Name", count: 9, cover: "removed")
        model.albums = [album("album", name: "Old", count: 9, cover: "removed")]
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [held.started], timeout: 2)
        let content = AssetLite(id: "kept", isVideo: false, ratio: 1, thumbhash: nil, createdAt: .distantPast)
        model.applyContents([content], to: "album")
        model.applyAlbumUpdate(capturedEdit)
        held.complete(.success([album("album", name: "Old", count: 9, cover: "removed")]))
        await load.value

        XCTAssertEqual(model.albums.first?.albumName, "New Name")
        XCTAssertEqual(model.albums.first?.assetCount, 1)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "kept")
        XCTAssertEqual(cached().first?.albumName, "New Name")
        XCTAssertEqual(cached().first?.assetCount, 1)
        XCTAssertEqual(cached().first?.albumThumbnailAssetId, "kept")
    }

    func testDeletionCallbackInvalidatesOldListsAndRemovesItsSnapshot() async {
        let driver = AlbumListDriver()
        let held = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { try await held.value() }
        let model = model(driver)
        model.albums = [album("deleted")]
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await held.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [held.started], timeout: 2)
        model.removeDeletedAlbum("deleted")
        held.complete(.success([album("deleted")]))
        await load.value

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(cached().isEmpty)
        XCTAssertNotNil(model.phase.value)
    }

    func testAcceptedSharingRefreshesAfterInvalidatingTheOlderPersonalAlbumList() async {
        let driver = AlbumListDriver()
        let old = ConsistencyGate<[AlbumResponseDTO]>()
        driver.list = { [weak driver] in
            driver?.listCalls == 1 ? try await old.value() : [self.album("album", name: "Shared", shared: true)]
        }
        let model = model(driver)
        model.albums = [album("album", name: "Personal")]
        let load = Task { await model.loadAlbums() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [old.started], timeout: 2)
        await model.addUsers(["friend"], to: "album")
        old.complete(.success([album("album", name: "Personal")]))
        await load.value

        XCTAssertEqual(model.albums.map(\.id), ["album"])
        XCTAssertEqual(model.albums.first?.shared, true)
        XCTAssertEqual(model.albums.first?.albumName, "Shared")
        XCTAssertEqual(cached().first?.shared, true)
        XCTAssertEqual(driver.listCalls, 2)
    }

    func testAcceptedSharingPublishesAndPersistsWhenReconciliationFails() async {
        let driver = AlbumListDriver()
        var accepted = false
        driver.addUsers = { accepted = true }
        driver.list = {
            XCTAssertTrue(accepted, "Reconciliation follows the confirmed sharing request")
            throw APIError.unknown
        }
        let model = model(driver)
        var original = album("album", name: "Kept name", count: 8, cover: "kept-cover")
        original.description = "Kept description"
        original.ownerId = "owner"
        model.albums = [original]
        LocalSnapshot.save([original], for: LocalSnapshot.Key.albumsList)
        let changed = AlbumPublicationProbe()
        withObservationTracking { _ = model.albums } onChange: {
            MainActor.assumeIsolated { changed.didPublish = true }
        }

        await model.addUsers(["friend"], to: "album")

        XCTAssertTrue(accepted)
        XCTAssertTrue(changed.didPublish)
        XCTAssertNil(model.actionError, "A failed read must not report that the accepted sharing request failed")
        XCTAssertEqual(model.albums.map(\.id), ["album"])
        XCTAssertEqual(model.albums.first?.shared, true)
        XCTAssertEqual(model.albums.first?.albumName, "Kept name")
        XCTAssertEqual(model.albums.first?.description, "Kept description")
        XCTAssertEqual(model.albums.first?.assetCount, 8)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "kept-cover")
        XCTAssertEqual(model.albums.first?.ownerId, "owner")
        XCTAssertEqual(cached().first?.shared, true)
        XCTAssertEqual(cached().first?.albumName, "Kept name")
        XCTAssertEqual(driver.listCalls, 1)
    }

    func testSharingSurvivesLaterCallbacksAndCannotRestoreAnAcceptedDeletion() async {
        for callback in ["metadata", "contents", "delete"] {
            LocalSnapshot.clearAll()
            let driver = AlbumListDriver()
            let reconciliation = ConsistencyGate<[AlbumResponseDTO]>()
            driver.list = { try await reconciliation.value() }
            let model = model(driver)
            model.albums = [album("album", name: "Old", count: 8, cover: "old-cover")]
            let share = Task { await model.addUsers(["friend"], to: "album") }
            addTeardownBlock {
                await reconciliation.complete(.failure(CancellationError()))
                await share.value
            }
            await fulfillment(of: [reconciliation.started], timeout: 2)
            XCTAssertEqual(model.albums.first?.shared, true, "Sharing is published before its read finishes")
            XCTAssertEqual(cached().first?.shared, true)
            switch callback {
            case "metadata": model.applyAlbumUpdate(album("album", name: "Saved name"))
            case "contents":
                model.applyContents([AssetLite(makeTestAsset(id: "kept"))], to: "album")
            default: await model.deleteAlbum("album")
            }
            reconciliation.complete(.success([album("album", name: "Obsolete", count: 99)]))
            await share.value

            XCTAssertNil(model.actionError)
            if callback == "delete" {
                XCTAssertTrue(model.albums.isEmpty)
                XCTAssertTrue(cached().isEmpty)
            } else {
                XCTAssertEqual(model.albums.first?.shared, true)
                XCTAssertEqual(cached().first?.shared, true)
                XCTAssertEqual(model.albums.first?.albumName, callback == "metadata" ? "Saved name" : "Old")
                XCTAssertEqual(model.albums.first?.assetCount, callback == "contents" ? 1 : 8)
                XCTAssertEqual(model.albums.first?.albumThumbnailAssetId,
                    callback == "contents" ? "kept" : "old-cover")
                XCTAssertEqual(cached().first?.albumName, model.albums.first?.albumName)
                XCTAssertEqual(cached().first?.assetCount, model.albums.first?.assetCount)
            }
        }
    }

    func testRejectedSharingDoesNotMarkTheAlbumSharedOrRequestReconciliation() async {
        let driver = AlbumListDriver()
        driver.addUsers = { throw APIError.unknown }
        let model = model(driver)
        model.albums = [album("album")]
        LocalSnapshot.save(model.albums, for: LocalSnapshot.Key.albumsList)

        await model.addUsers(["friend"], to: "album")

        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.albums.first?.shared, false)
        XCTAssertEqual(cached().first?.shared, false)
        XCTAssertEqual(driver.listCalls, 0)
    }

    func testMetadataCallbackCannotResurrectADeletedAlbum() async {
        let driver = AlbumListDriver()
        let model = model(driver)
        model.albums = [album("deleted"), album("kept")]
        let deleted = await model.deleteAlbum("deleted")
        XCTAssertTrue(deleted)

        model.applyAlbumUpdate(album("deleted", name: "Late edit"))

        XCTAssertEqual(model.albums.map(\.id), ["kept"])
        XCTAssertEqual(cached().map(\.id), ["kept"])
    }

    func testAccountChangesRejectHeldLoadsAndActionResults() async {
        let driver = AlbumListDriver()
        let read = ConsistencyGate<[AlbumResponseDTO]>()
        let create = ConsistencyGate<AlbumResponseDTO>()
        driver.list = { try await read.value() }
        driver.create = { try await create.value() }
        let model = model(driver)
        let loading = Task { await model.loadAlbums() }
        let creating = Task { await model.createAlbum(name: "Old account", description: "", assetIds: []) }
        addTeardownBlock {
            await read.complete(.failure(CancellationError())); await create.complete(.failure(CancellationError()))
            await loading.value; _ = await creating.value
        }
        await fulfillment(of: [read.started, create.started], timeout: 2)
        LocalSnapshot.clearAll()
        let current = album("new-account")
        LocalSnapshot.save([current], for: LocalSnapshot.Key.albumsList)
        read.complete(.success([album("old-account")]))
        create.complete(.success(album("old-create")))
        await loading.value
        _ = await creating.value
        model.removeDeletedAlbum("new-account")

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertEqual(cached().map(\.id), ["new-account"])
        XCTAssertNil(model.actionError)
    }

    private func model(_ driver: AlbumListDriver) -> AlbumListViewModel {
        AlbumListViewModel(repo: ConsistencyAlbumRepository(api: APIClient(session: MockSessionManager()), driver: driver))
    }

    private func cached() -> [AlbumResponseDTO] {
        LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.albumsList) ?? []
    }

    private func album(_ id: String, name: String = "Album", count: Int = 0, cover: String? = nil,
                       shared: Bool = false) -> AlbumResponseDTO {
        .init(id: id, albumName: name, description: nil, assetCount: count, albumThumbnailAssetId: cover,
            shared: shared, createdAt: Date(timeIntervalSince1970: 100), assets: nil)
    }
}

@MainActor
private final class AlbumListDriver {
    var list: @MainActor () async throws -> [AlbumResponseDTO] = { [] }
    var create: @MainActor () async throws -> AlbumResponseDTO = { throw APIError.unknown }
    var delete: @MainActor (String) async throws -> Void = { _ in }
    var addUsers: @MainActor () async throws -> Void = {}
    private(set) var listCalls = 0
    func all() async throws -> [AlbumResponseDTO] { listCalls += 1; return try await list() }
}

@MainActor
private final class AlbumPublicationProbe {
    var didPublish = false
}

private final class ConsistencyAlbumRepository: AlbumRepository {
    let driver: AlbumListDriver
    init(api: APIClient, driver: AlbumListDriver) { self.driver = driver; super.init(api: api) }
    override func all() async throws -> [AlbumResponseDTO] { try await driver.all() }
    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        try await driver.create()
    }
    override func delete(_ id: String) async throws { try await driver.delete(id) }
    override func addUsers(_ userIds: [String], to albumId: String) async throws { try await driver.addUsers() }
}

@MainActor
private final class ConsistencyGate<Value> {
    let started = XCTestExpectation(description: "An album request reached its held response")
    private var hasStarted = false
    private var result: Result<Value, Error>?
    private var continuations: [CheckedContinuation<Value, Error>] = []
    func value() async throws -> Value {
        if !hasStarted { hasStarted = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(_ value: Result<Value, Error>) {
        guard result == nil else { return }
        result = value
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(with: value) }
    }
}
