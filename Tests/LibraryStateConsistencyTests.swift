import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class LibraryStateConsistencyTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    func testSameIDMetadataNotifiesObserversWhenFetchedBytesAreAlreadyOnDisk() async {
        let driver = LibraryConsistencyDriver()
        let model = model(driver)
        model.albums = [album("album", name: "Old", count: 1, cover: "old")]
        model.people = [person("person", name: "Old")]
        let fetchedAlbum = album("album", name: "New", count: 8, cover: "new", shared: true)
        let fetchedPerson = person("person", name: "New")
        LocalSnapshot.save([fetchedAlbum], for: LocalSnapshot.Key.libraryAlbums)
        LocalSnapshot.save([fetchedPerson], for: LocalSnapshot.Key.libraryPeople)
        XCTAssertFalse(LocalSnapshot.save([fetchedAlbum], for: LocalSnapshot.Key.libraryAlbums))
        XCTAssertFalse(LocalSnapshot.save([fetchedPerson], for: LocalSnapshot.Key.libraryPeople))
        driver.albums = { [fetchedAlbum] }
        driver.people = { [fetchedPerson] }
        let changed = LibraryPublicationProbe()
        withObservationTracking { _ = model.albums } onChange: {
            MainActor.assumeIsolated { changed.albums = true }
        }
        withObservationTracking { _ = model.people } onChange: {
            MainActor.assumeIsolated { changed.people = true }
        }

        await model.load()

        XCTAssertTrue(changed.albums)
        XCTAssertTrue(changed.people)
        XCTAssertEqual(model.albums.first?.albumName, "New")
        XCTAssertEqual(model.albums.first?.assetCount, 8)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "new")
        XCTAssertEqual(model.albums.first?.shared, true)
        XCTAssertEqual(model.people.first?.name, "New")
        XCTAssertTrue(model.hasLoaded)
    }

    func testAcceptedSectionsPublishEvenWhenSnapshotsCannotBeWritten() async throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("immich-snapshots")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory)
        let driver = LibraryConsistencyDriver()
        driver.albums = { [self.album("fetched")] }
        driver.people = { [self.person("fetched")] }
        let model = model(driver)

        await model.load()

        XCTAssertEqual(model.albums.map(\.id), ["fetched"])
        XCTAssertEqual(model.people.map(\.id), ["fetched"])
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums))
        XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople))
    }

    func testFailurePreservesSectionsButAuthoritativeEmptyResponseClearsThem() async {
        let driver = LibraryConsistencyDriver()
        let savedAlbum = album("saved")
        let savedPerson = person("saved")
        LocalSnapshot.save([savedAlbum], for: LocalSnapshot.Key.libraryAlbums)
        LocalSnapshot.save([savedPerson], for: LocalSnapshot.Key.libraryPeople)
        driver.albums = { throw APIError.unknown }
        driver.people = { throw APIError.unknown }
        let model = model(driver)

        await model.loadIfNeeded()

        XCTAssertEqual(model.albums.map(\.id), ["saved"])
        XCTAssertEqual(model.people.map(\.id), ["saved"])
        XCTAssertFalse(model.hasLoaded, "A disk fallback does not confirm empty sections from the server")
        XCTAssertEqual(cachedAlbums().map(\.id), ["saved"])
        XCTAssertEqual(cachedPeople().map(\.id), ["saved"])

        driver.albums = { [] }
        driver.people = { [] }
        await model.loadIfNeeded()

        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertEqual(driver.albumCalls, 2, "An entirely failed load must remain retryable")
        XCTAssertEqual(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums)?.count, 0)
        XCTAssertEqual(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople)?.count, 0)
        driver.albums = { throw APIError.unknown }
        driver.people = { throw APIError.unknown }
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(model.people.isEmpty)
    }

    func testOlderFullLoadCannotOverwriteANewerLoadOrItsSnapshots() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        let people = LibraryConsistencyGate<[PersonDTO]>()
        driver.albums = { [weak driver] in
            driver?.albumCalls == 1 ? try await albums.value() : [self.album("current")]
        }
        driver.people = { [weak driver] in
            driver?.peopleCalls == 1 ? try await people.value() : [self.person("current")]
        }
        let model = model(driver)
        let old = Task { await model.load() }
        addTeardownBlock {
            await albums.complete(.failure(CancellationError()))
            await people.complete(.failure(CancellationError()))
            await old.value
        }
        await fulfillment(of: [albums.started, people.started], timeout: 2)
        await model.load()
        albums.complete(.success([album("obsolete")]))
        people.complete(.success([person("obsolete")]))
        await old.value

        XCTAssertEqual(model.albums.map(\.id), ["current"])
        XCTAssertEqual(model.people.map(\.id), ["current"])
        XCTAssertEqual(cachedAlbums().map(\.id), ["current"])
        XCTAssertEqual(cachedPeople().map(\.id), ["current"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testConfirmedMetadataContentsAndPersonCallbacksRejectOlderFullLoadSections() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        let people = LibraryConsistencyGate<[PersonDTO]>()
        driver.albums = { try await albums.value() }
        driver.people = { try await people.value() }
        let model = model(driver)
        model.albums = [album("album", count: 9, cover: "removed", shared: true)]
        model.people = [person("person")]
        let old = Task { await model.load() }
        addTeardownBlock {
            await albums.complete(.failure(CancellationError()))
            await people.complete(.failure(CancellationError()))
            await old.value
        }
        await fulfillment(of: [albums.started, people.started], timeout: 2)
        var staleEditorValue = album("album", name: "Saved name", count: 9, cover: "removed")
        staleEditorValue.description = "Saved description"
        let remaining = AssetLite(makeTestAsset(id: "kept"))
        XCTAssertTrue(model.applyAlbumContents([remaining], to: "album"))
        model.applyAlbumUpdate(staleEditorValue)
        model.applyPersonRename("person", to: "Saved person name")
        albums.complete(.success([album("album", name: "Stale name", count: 9, cover: "removed")]))
        people.complete(.success([person("person", name: "Stale person name")]))
        await old.value

        XCTAssertEqual(model.albums.first?.albumName, "Saved name")
        XCTAssertEqual(model.albums.first?.description, "Saved description")
        XCTAssertEqual(model.albums.first?.assetCount, 1)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "kept")
        XCTAssertEqual(model.albums.first?.shared, true, "Metadata callbacks preserve newer sharing state")
        XCTAssertEqual(cachedAlbums().first?.assetCount, 1)
        XCTAssertEqual(cachedAlbums().first?.albumName, "Saved name")
        XCTAssertEqual(cachedAlbums().first?.description, "Saved description")
        XCTAssertEqual(model.people.first?.name, "Saved person name")
        XCTAssertEqual(cachedPeople().first?.name, "Saved person name")
    }

    func testAcceptedDeleteInvalidatesOnlyAlbumsInAHeldFullLoad() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { try await albums.value() }
        driver.people = { [self.person("fresh-person")] }
        let model = model(driver)
        model.albums = [album("deleted"), album("kept")]
        LocalSnapshot.save(["old-photo"], for: LocalSnapshot.Key.album("deleted"))
        let old = Task { await model.load() }
        addTeardownBlock { await albums.complete(.failure(CancellationError())); await old.value }
        await fulfillment(of: [albums.started], timeout: 2)
        await model.deleteAlbum("deleted")
        albums.complete(.success([album("deleted"), album("kept")]))
        await old.value

        XCTAssertEqual(model.albums.map(\.id), ["kept"])
        XCTAssertEqual(cachedAlbums().map(\.id), ["kept"])
        XCTAssertNil(LocalSnapshot.load([String].self, for: LocalSnapshot.Key.album("deleted")))
        XCTAssertEqual(model.people.map(\.id), ["fresh-person"], "An album action must not discard an independent People response")
        XCTAssertEqual(cachedPeople().map(\.id), ["fresh-person"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testMetadataCallbackAloneRejectsOlderAlbumLoad() async {
        let driver = LibraryConsistencyDriver()
        let listing = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { try await listing.value() }
        let model = model(driver)
        model.albums = [album("album", name: "Original name")]
        let loading = Task { await model.load() }
        addTeardownBlock { await listing.complete(.failure(CancellationError())); await loading.value }
        await fulfillment(of: [listing.started], timeout: 2)
        var confirmed = album("album", name: "Saved name")
        confirmed.description = "Saved description"

        model.applyAlbumUpdate(confirmed)
        listing.complete(.success([album("album", name: "Stale name"), album("obsolete")]))
        await loading.value

        XCTAssertEqual(model.albums.map(\.id), ["album"])
        XCTAssertEqual(model.albums.first?.albumName, "Saved name")
        XCTAssertEqual(model.albums.first?.description, "Saved description")
        XCTAssertEqual(cachedAlbums().map(\.id), ["album"])
        XCTAssertEqual(cachedAlbums().first?.albumName, "Saved name")
        XCTAssertEqual(cachedAlbums().first?.description, "Saved description")
    }

    func testAcceptedSharingPublishesAndPersistsWhenReconciliationFails() async {
        let driver = LibraryConsistencyDriver()
        var accepted = false
        driver.addUsers = { accepted = true }
        driver.albums = {
            XCTAssertTrue(accepted, "Reconciliation follows the confirmed sharing request")
            throw APIError.unknown
        }
        let model = model(driver)
        var original = album("album", name: "Kept name", count: 8, cover: "kept-cover")
        original.description = "Kept description"
        original.ownerId = "owner"
        model.albums = [original]
        LocalSnapshot.save([original], for: LocalSnapshot.Key.libraryAlbums)
        let changed = LibraryPublicationProbe()
        withObservationTracking { _ = model.albums } onChange: {
            MainActor.assumeIsolated { changed.albums = true }
        }

        await model.addUsers(["friend"], to: "album")

        XCTAssertTrue(accepted)
        XCTAssertTrue(changed.albums)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.albums.first?.shared, true)
        XCTAssertEqual(model.albums.first?.albumName, "Kept name")
        XCTAssertEqual(model.albums.first?.description, "Kept description")
        XCTAssertEqual(model.albums.first?.assetCount, 8)
        XCTAssertEqual(model.albums.first?.albumThumbnailAssetId, "kept-cover")
        XCTAssertEqual(model.albums.first?.ownerId, "owner")
        XCTAssertEqual(cachedAlbums().first?.shared, true)
        XCTAssertEqual(cachedAlbums().first?.albumName, "Kept name")
        XCTAssertEqual(driver.albumCalls, 1)
    }

    func testSharingSurvivesLaterCallbacksAndCannotRestoreAnAcceptedDeletion() async {
        for callback in ["metadata", "contents", "delete"] {
            LocalSnapshot.clearAll()
            let driver = LibraryConsistencyDriver()
            let reconciliation = LibraryConsistencyGate<[AlbumResponseDTO]>()
            driver.albums = { try await reconciliation.value() }
            let model = model(driver)
            model.albums = [album("album", name: "Old", count: 8, cover: "old-cover")]
            let share = Task { await model.addUsers(["friend"], to: "album") }
            addTeardownBlock {
                await reconciliation.complete(.failure(CancellationError()))
                await share.value
            }
            await fulfillment(of: [reconciliation.started], timeout: 2)
            XCTAssertEqual(model.albums.first?.shared, true, "Sharing is published before its read finishes")
            XCTAssertEqual(cachedAlbums().first?.shared, true)
            switch callback {
            case "metadata": model.applyAlbumUpdate(album("album", name: "Saved name"))
            case "contents":
                XCTAssertTrue(model.applyAlbumContents([AssetLite(makeTestAsset(id: "kept"))], to: "album"))
            default: await model.deleteAlbum("album")
            }
            reconciliation.complete(.success([album("album", name: "Obsolete", count: 99)]))
            await share.value

            XCTAssertNil(model.actionError)
            if callback == "delete" {
                XCTAssertTrue(model.albums.isEmpty)
                XCTAssertTrue(cachedAlbums().isEmpty)
            } else {
                XCTAssertEqual(model.albums.first?.shared, true)
                XCTAssertEqual(cachedAlbums().first?.shared, true)
                XCTAssertEqual(model.albums.first?.albumName, callback == "metadata" ? "Saved name" : "Old")
                XCTAssertEqual(model.albums.first?.assetCount, callback == "contents" ? 1 : 8)
                XCTAssertEqual(model.albums.first?.albumThumbnailAssetId,
                    callback == "contents" ? "kept" : "old-cover")
                XCTAssertEqual(cachedAlbums().first?.albumName, model.albums.first?.albumName)
                XCTAssertEqual(cachedAlbums().first?.assetCount, model.albums.first?.assetCount)
            }
        }
    }

    func testRejectedSharingDoesNotMarkTheAlbumSharedOrRequestReconciliation() async {
        let driver = LibraryConsistencyDriver()
        driver.addUsers = { throw APIError.unknown }
        let model = model(driver)
        model.albums = [album("album")]
        LocalSnapshot.save(model.albums, for: LocalSnapshot.Key.libraryAlbums)

        await model.addUsers(["friend"], to: "album")

        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.albums.first?.shared, false)
        XCTAssertEqual(cachedAlbums().first?.shared, false)
        XCTAssertEqual(driver.albumCalls, 0)
    }

    func testAcceptedDeleteDominatesALaterMetadataEdit() async {
        let driver = LibraryConsistencyDriver()
        let deletion = LibraryConsistencyGate<Void>()
        driver.delete = { _ in try await deletion.value() }
        let model = model(driver)
        model.albums = [album("deleted"), album("kept")]
        let deleting = Task { await model.deleteAlbum("deleted") }
        addTeardownBlock { await deletion.complete(.failure(CancellationError())); await deleting.value }
        await fulfillment(of: [deletion.started], timeout: 2)
        model.applyAlbumUpdate(album("deleted", name: "Accepted edit"))
        XCTAssertEqual(model.albums.first?.albumName, "Accepted edit")
        deletion.complete(.success(()))
        await deleting.value
        model.applyAlbumUpdate(album("deleted", name: "Late edit"))

        XCTAssertEqual(model.albums.map(\.id), ["kept"])
        XCTAssertEqual(cachedAlbums().map(\.id), ["kept"])
        XCTAssertNil(model.actionError)
    }

    func testAlbumOnlyRefreshSupersedesTheAlbumSectionOfAnOlderFullLoad() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { [weak driver] in
            driver?.albumCalls == 1 ? try await albums.value() : [self.album("refreshed")]
        }
        driver.people = { [self.person("full-load-person")] }
        let model = model(driver)
        let full = Task { await model.load() }
        addTeardownBlock { await albums.complete(.failure(CancellationError())); await full.value }
        await fulfillment(of: [albums.started], timeout: 2)
        await model.refreshAlbums()
        albums.complete(.success([album("obsolete")]))
        await full.value

        XCTAssertEqual(model.albums.map(\.id), ["refreshed"])
        XCTAssertEqual(cachedAlbums().map(\.id), ["refreshed"])
        XCTAssertEqual(model.people.map(\.id), ["full-load-person"])
        XCTAssertEqual(cachedPeople().map(\.id), ["full-load-person"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testFullLoadSupersedesAnOlderAlbumOnlyRefresh() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { [weak driver] in
            driver?.albumCalls == 1 ? try await albums.value() : [self.album("current")]
        }
        let model = model(driver)
        let refresh = Task { await model.refreshAlbums() }
        addTeardownBlock { await albums.complete(.failure(CancellationError())); await refresh.value }
        await fulfillment(of: [albums.started], timeout: 2)
        await model.load()
        albums.complete(.success([album("obsolete")]))
        await refresh.value

        XCTAssertEqual(model.albums.map(\.id), ["current"])
        XCTAssertEqual(cachedAlbums().map(\.id), ["current"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testRejectedMutationDoesNotDiscardAnOtherwiseValidPendingList() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { try await albums.value() }
        driver.delete = { _ in throw APIError.unknown }
        let model = model(driver)
        model.albums = [album("kept")]
        let load = Task { await model.load() }
        addTeardownBlock { await albums.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [albums.started], timeout: 2)
        await model.deleteAlbum("kept")
        XCTAssertNotNil(model.actionError)
        albums.complete(.success([album("kept", name: "Fresh metadata"), album("new")]))
        await load.value

        XCTAssertEqual(Set(model.albums.map(\.id)), ["kept", "new"])
        XCTAssertEqual(model.albums.first(where: { $0.id == "kept" })?.albumName, "Fresh metadata")
        XCTAssertEqual(Set(cachedAlbums().map(\.id)), ["kept", "new"])
    }

    func testCanceledFullLoadCannotPublishRepositoriesThatIgnoreCancellation() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        driver.albums = { try await albums.value() }
        driver.people = { [self.person("canceled")] }
        let model = model(driver)
        let load = Task { await model.load() }
        addTeardownBlock { await albums.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [albums.started], timeout: 2)
        load.cancel()
        albums.complete(.success([album("canceled")]))
        await load.value

        XCTAssertTrue(model.albums.isEmpty)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertNil(LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums))
        XCTAssertNil(LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople))
        driver.albums = { [self.album("retry")] }
        driver.people = { [self.person("retry")] }
        await model.loadIfNeeded()
        XCTAssertEqual(model.albums.map(\.id), ["retry"])
        XCTAssertEqual(model.people.map(\.id), ["retry"])
        XCTAssertTrue(model.hasLoaded)
    }

    func testAccountChangeRejectsHeldLoadsActionsAndCallbacksWithoutTouchingTheNextSnapshot() async {
        let driver = LibraryConsistencyDriver()
        let albums = LibraryConsistencyGate<[AlbumResponseDTO]>()
        let sharing = LibraryConsistencyGate<Void>()
        driver.albums = { try await albums.value() }
        driver.people = { [self.person("old-server-person")] }
        driver.addUsers = { try await sharing.value() }
        let model = model(driver)
        model.albums = [album("old")]
        model.people = [person("old")]
        let load = Task { await model.load() }
        let action = Task { await model.addUsers(["friend"], to: "old") }
        addTeardownBlock {
            await albums.complete(.failure(CancellationError()))
            await sharing.complete(.failure(CancellationError()))
            await load.value
            await action.value
        }
        await fulfillment(of: [albums.started, sharing.started], timeout: 2)
        LocalSnapshot.clearAll()
        LocalSnapshot.save([album("next")], for: LocalSnapshot.Key.libraryAlbums)
        LocalSnapshot.save([person("next")], for: LocalSnapshot.Key.libraryPeople)
        albums.complete(.success([album("old-server-album")]))
        sharing.complete(.success(()))
        await load.value
        await action.value
        model.applyAlbumUpdate(album("old", name: "Stale callback"))
        model.applyPersonRename("old", to: "Stale callback")
        _ = model.applyAlbumContents([], to: "old")
        await model.load()
        await model.refreshAlbums()

        XCTAssertEqual(model.albums.map(\.albumName), ["Album"])
        XCTAssertEqual(model.albums.first?.shared, false)
        XCTAssertEqual(model.people.map(\.name), ["Person"])
        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(driver.albumCalls, 1, "An old model cannot begin another account's load")
        XCTAssertEqual(cachedAlbums().map(\.id), ["next"])
        XCTAssertEqual(cachedPeople().map(\.id), ["next"])
    }

    private func model(_ driver: LibraryConsistencyDriver) -> LibraryViewModel {
        let api = APIClient(session: MockSessionManager())
        return LibraryViewModel(memoriesRepo: FailingConsistencyMemories(api: api),
            albumRepo: LibraryConsistencyAlbums(api: api, driver: driver),
            peopleRepo: LibraryConsistencyPeople(api: api, driver: driver),
            searchRepo: FailingConsistencySearch(api: api), assetRepo: AssetDetailRepository(api: api))
    }

    private func album(_ id: String, name: String = "Album", count: Int = 0, cover: String? = nil,
                       shared: Bool = false) -> AlbumResponseDTO {
        .init(id: id, albumName: name, description: nil, assetCount: count, albumThumbnailAssetId: cover,
            shared: shared, createdAt: Date(timeIntervalSince1970: 100), assets: nil)
    }

    private func person(_ id: String, name: String = "Person") -> PersonDTO {
        .init(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false)
    }

    private func cachedAlbums() -> [AlbumResponseDTO] {
        LocalSnapshot.load([AlbumResponseDTO].self, for: LocalSnapshot.Key.libraryAlbums) ?? []
    }

    private func cachedPeople() -> [PersonDTO] {
        LocalSnapshot.load([PersonDTO].self, for: LocalSnapshot.Key.libraryPeople) ?? []
    }
}

@MainActor
private final class LibraryConsistencyDriver {
    var albums: @MainActor () async throws -> [AlbumResponseDTO] = { [] }
    var people: @MainActor () async throws -> [PersonDTO] = { [] }
    var delete: @MainActor (String) async throws -> Void = { _ in }
    var addUsers: @MainActor () async throws -> Void = {}
    private(set) var albumCalls = 0
    private(set) var peopleCalls = 0

    func getAlbums() async throws -> [AlbumResponseDTO] { albumCalls += 1; return try await albums() }
    func getPeople() async throws -> [PersonDTO] { peopleCalls += 1; return try await people() }
}

@MainActor
private final class LibraryPublicationProbe {
    var albums = false
    var people = false
}

private final class LibraryConsistencyAlbums: AlbumRepository {
    private let driver: LibraryConsistencyDriver
    init(api: APIClient, driver: LibraryConsistencyDriver) { self.driver = driver; super.init(api: api) }
    override func all() async throws -> [AlbumResponseDTO] { try await driver.getAlbums() }
    override func delete(_ id: String) async throws { try await driver.delete(id) }
    override func addUsers(_ userIds: [String], to albumId: String) async throws { try await driver.addUsers() }
}

private final class LibraryConsistencyPeople: PeopleRepository {
    private let driver: LibraryConsistencyDriver
    init(api: APIClient, driver: LibraryConsistencyDriver) { self.driver = driver; super.init(api: api) }
    override func all(size: Int? = nil) async throws -> [PersonDTO] {
        XCTAssertEqual(size, 15)
        return try await driver.getPeople()
    }
}

private final class FailingConsistencyMemories: MemoriesRepository {
    override func getMemories() async throws -> [MemoryDTO] { throw APIError.unknown }
}

private final class FailingConsistencySearch: SearchRepository {
    override func metadataSearch(_ request: SearchRequestDTO) async throws -> SearchResponseDTO { throw APIError.unknown }
}

@MainActor
private final class LibraryConsistencyGate<Value> {
    let started = XCTestExpectation(description: "A Library request reached its held response")
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
