import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumResolutionTests: XCTestCase {
    private var fixtures: [AlbumResolutionFixture] = []
    private var closeGates: [() -> Void] = []
    private var savedDefaults: [String: Any] = [:]
    private let defaultKeys = ["backup.enabled", "backup.syncAlbums"]

    override func setUp() async throws {
        try await super.setUp()
        for key in defaultKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() async throws {
        closeGates.forEach { $0() }
        closeGates.removeAll()
        for fixture in fixtures { fixture.cleanup() }
        fixtures.removeAll()
        for key in defaultKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
        try await super.tearDown()
    }

    func testConcurrentSameNameWaitersShareHeldLookupAndCreation() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        let lookup: AlbumResolutionGate<[AlbumResponseDTO]> = gate()
        let creation: AlbumResolutionGate<AlbumResponseDTO> = gate()
        let extraLookup = expectation(description: "A same-name waiter must not issue another GET")
        let extraCreation = expectation(description: "A same-name waiter must not issue another POST")
        extraLookup.isInverted = true
        extraCreation.isInverted = true
        fixture.driver.list = { [weak driver = fixture.driver] in
            if driver?.lookups == 2 { extraLookup.fulfill() }
            return try await lookup.value()
        }
        fixture.driver.create = { [weak driver = fixture.driver] name in
            XCTAssertEqual(name, "Camera")
            if driver?.createdNames.count == 2 { extraCreation.fulfill() }
            return try await creation.value()
        }
        let first = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [lookup.started], timeout: 2)
        let second = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [extraLookup], timeout: 0.05)
        lookup.complete(.success([]))
        await fulfillment(of: [creation.started], timeout: 2)
        let third = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [extraCreation], timeout: 0.05)
        creation.complete(.success(resolutionAlbum("created-camera", name: "Camera")))
        let results = await [first.value, second.value, third.value]

        XCTAssertEqual(results, ["created-camera", "created-camera", "created-camera"])
        XCTAssertEqual(fixture.driver.lookups, 1)
        XCTAssertEqual(fixture.driver.createdNames, ["Camera"])
        let cached = await fixture.service.albumID(named: "Camera", ownership: ownership)
        XCTAssertEqual(cached, "created-camera")
        XCTAssertEqual(fixture.driver.lookups, 1)
    }

    func testDifferentNamesCanResolveWhileAnotherNameIsStillWaiting() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        let firstLookup: AlbumResolutionGate<[AlbumResponseDTO]> = gate()
        fixture.driver.list = { [weak driver = fixture.driver] in
            if driver?.lookups == 1 { return try await firstLookup.value() }
            return []
        }
        let waiting = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [firstLookup.started], timeout: 2)

        let other = await fixture.service.albumID(named: "Screenshots", ownership: ownership)

        XCTAssertEqual(other, "created-Screenshots")
        XCTAssertEqual(fixture.driver.createdNames, ["Screenshots"])
        firstLookup.complete(.success([]))
        let camera = await waiting.value
        XCTAssertEqual(camera, "created-Camera")
        XCTAssertEqual(fixture.driver.lookups, 2)
        XCTAssertEqual(fixture.driver.createdNames, ["Screenshots", "Camera"])
    }

    func testExistingAlbumIsReusedWithoutCreation() async throws {
        let fixture = try fixture()
        fixture.driver.list = { [resolutionAlbum("different", name: "Other"), resolutionAlbum("existing", name: "Camera")] }
        fixture.driver.create = { _ in XCTFail("A successful matching lookup must not create another album"); throw APIError.unknown }
        let ownership = try fixture.ownership()

        let first = await fixture.service.albumID(named: "Camera", ownership: ownership)
        let second = await fixture.service.albumID(named: "Camera", ownership: ownership)

        XCTAssertEqual(first, "existing")
        XCTAssertEqual(second, "existing")
        XCTAssertEqual(fixture.driver.lookups, 1)
        XCTAssertTrue(fixture.driver.createdNames.isEmpty)
    }

    func testFailedLookupCannotCreateAnAlbumAndFreshRetryCanResolveIt() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        fixture.driver.list = { throw URLError(.notConnectedToInternet) }

        let failed = await fixture.service.albumID(named: "Camera", ownership: ownership)

        XCTAssertNil(failed)
        XCTAssertEqual(fixture.driver.lookups, 1)
        XCTAssertTrue(fixture.driver.createdNames.isEmpty, "A failed GET does not prove that an album is absent")
        fixture.driver.list = { [] }
        let retried = await fixture.service.albumID(named: "Camera", ownership: ownership)
        XCTAssertEqual(retried, "created-Camera")
        XCTAssertEqual(fixture.driver.lookups, 2)
        XCTAssertEqual(fixture.driver.createdNames, ["Camera"])
    }

    func testFailedCreationIsNotCachedAndCanBeRetried() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        fixture.driver.create = { _ in throw APIError.server(status: 500, message: "Creation failed") }
        let failed = await fixture.service.albumID(named: "Camera", ownership: ownership)
        XCTAssertNil(failed)
        fixture.driver.create = { name in resolutionAlbum("retry-created", name: name) }

        let retried = await fixture.service.albumID(named: "Camera", ownership: ownership)

        XCTAssertEqual(retried, "retry-created")
        XCTAssertEqual(fixture.driver.lookups, 2)
        XCTAssertEqual(fixture.driver.createdNames, ["Camera", "Camera"])
    }

    func testCancelingTheInitiatingWaiterDoesNotCancelAnotherWaitersAlbum() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        let held: AlbumResolutionGate<[AlbumResponseDTO]> = gate()
        fixture.driver.list = { try await held.value() }
        let first = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [held.started], timeout: 2)
        let second = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        first.cancel()
        held.complete(.success([]))
        let canceled = await first.value
        let retained = await second.value

        XCTAssertNil(canceled)
        XCTAssertEqual(retained, "created-Camera")
        XCTAssertEqual(fixture.driver.lookups, 1)
        XCTAssertEqual(fixture.driver.createdNames, ["Camera"])
        let cached = await fixture.service.albumID(named: "Camera", ownership: ownership)
        XCTAssertEqual(cached, retained)
        XCTAssertEqual(fixture.driver.lookups, 1)
    }

    func testOldAccountResponsesCannotCreateOrCacheAcrossANewerSameNameLookup() async throws {
        for holdCreation in [false, true] {
            let fixture = try fixture()
            let oldOwnership = try fixture.ownership()
            let oldLookup: AlbumResolutionGate<[AlbumResponseDTO]> = gate()
            let oldCreation: AlbumResolutionGate<AlbumResponseDTO> = gate()
            fixture.driver.list = { holdCreation ? [] : try await oldLookup.value() }
            fixture.driver.create = { _ in try await oldCreation.value() }
            let oldDriver = fixture.driver
            let old = Task { await fixture.service.albumID(named: "Camera", ownership: oldOwnership) }
            await fulfillment(of: [holdCreation ? oldCreation.started : oldLookup.started], timeout: 2)
            let currentDriver = AlbumResolutionDriver()
            let currentLookup: AlbumResolutionGate<[AlbumResponseDTO]> = gate()
            let extraLookup = expectation(description: "Old cleanup cannot remove the new owner's active lookup")
            extraLookup.isInverted = true
            currentDriver.list = { [weak currentDriver] in
                if currentDriver?.lookups == 2 { extraLookup.fulfill() }
                return try await currentLookup.value()
            }
            currentDriver.create = { name in resolutionAlbum("current-owner-album", name: name) }
            try fixture.replaceSession(owner: .init(server: "https://other-albums.example/api", userID: "other-user"),
                                       driver: currentDriver)
            let currentOwnership = try fixture.ownership()
            XCTAssertNotEqual(currentOwnership, oldOwnership)
            let current = Task { await fixture.service.albumID(named: "Camera", ownership: currentOwnership) }
            await fulfillment(of: [currentLookup.started], timeout: 2)

            if holdCreation { oldCreation.complete(.success(resolutionAlbum("old-owner-album", name: "Camera"))) }
            else { oldLookup.complete(.success([])) }
            let obsolete = await old.value
            XCTAssertNil(obsolete)
            XCTAssertEqual(oldDriver.createdNames.count, holdCreation ? 1 : 0)
            let joined = Task { await fixture.service.albumID(named: "Camera", ownership: currentOwnership) }
            await fulfillment(of: [extraLookup], timeout: 0.05)
            currentLookup.complete(.success([]))
            let currentResult = await current.value
            let joinedResult = await joined.value
            XCTAssertEqual(currentResult, "current-owner-album")
            XCTAssertEqual(joinedResult, currentResult)
            XCTAssertEqual(currentDriver.lookups, 1)
            XCTAssertEqual(currentDriver.createdNames, ["Camera"])
            let cached = await fixture.service.albumID(named: "Camera", ownership: currentOwnership)
            XCTAssertEqual(cached, "current-owner-album")
            XCTAssertEqual(currentDriver.lookups, 1)
        }
    }

    func testSettledAlbumCacheDoesNotCrossAccounts() async throws {
        let fixture = try fixture()
        let first = await fixture.service.albumID(named: "Camera", ownership: try fixture.ownership())
        XCTAssertEqual(first, "created-Camera")
        let next = AlbumResolutionDriver()
        next.list = { [resolutionAlbum("different-account-camera", name: "Camera")] }
        try fixture.replaceSession(owner: .init(server: "https://album-resolution.example/api", userID: "different-user"), driver: next)

        let second = await fixture.service.albumID(named: "Camera", ownership: try fixture.ownership())

        XCTAssertEqual(second, "different-account-camera")
        XCTAssertEqual(next.lookups, 1)
        XCTAssertTrue(next.createdNames.isEmpty)
    }

    func testAuthenticationPauseRejectsHeldCreationEvenWhenSameAccountKeepsItsQueueGeneration() async throws {
        let fixture = try fixture()
        let ownership = try fixture.ownership()
        let held: AlbumResolutionGate<AlbumResponseDTO> = gate()
        fixture.driver.create = { _ in try await held.value() }
        let old = Task { await fixture.service.albumID(named: "Camera", ownership: ownership) }
        await fulfillment(of: [held.started], timeout: 2)
        fixture.service.pauseForAuthentication()
        let next = AlbumResolutionDriver()
        next.list = { [resolutionAlbum("renewed-session-camera", name: "Camera")] }
        try fixture.replaceSession(owner: ownership.owner, driver: next)
        XCTAssertEqual(try fixture.ownership(), ownership)
        let current = await fixture.service.albumID(named: "Camera", ownership: ownership)
        held.complete(.success(resolutionAlbum("obsolete-session-camera", name: "Camera")))
        let obsolete = await old.value

        XCTAssertNil(obsolete)
        XCTAssertEqual(current, "renewed-session-camera")
        let cached = await fixture.service.albumID(named: "Camera", ownership: ownership)
        XCTAssertEqual(cached, current)
        XCTAssertEqual(next.lookups, 1)
        XCTAssertTrue(next.createdNames.isEmpty)
    }

    private func fixture() throws -> AlbumResolutionFixture {
        let fixture = try AlbumResolutionFixture()
        fixtures.append(fixture)
        return fixture
    }

    private func gate<Value>() -> AlbumResolutionGate<Value> {
        let gate = AlbumResolutionGate<Value>()
        closeGates.append { gate.complete(.failure(CancellationError())) }
        return gate
    }

}

private func resolutionAlbum(_ id: String, name: String) -> AlbumResponseDTO {
    AlbumResponseDTO(id: id, albumName: name, description: nil, assetCount: 0,
                     albumThumbnailAssetId: nil, shared: false, createdAt: .distantPast, assets: nil)
}

@MainActor
private final class AlbumResolutionDriver {
    var list: () async throws -> [AlbumResponseDTO] = { [] }
    var create: (String) async throws -> AlbumResponseDTO = { resolutionAlbum("created-\($0)", name: $0) }
    private(set) var lookups = 0
    private(set) var createdNames: [String] = []

    func all() async throws -> [AlbumResponseDTO] {
        lookups += 1
        return try await list()
    }
    func createAlbum(_ name: String) async throws -> AlbumResponseDTO {
        createdNames.append(name)
        return try await create(name)
    }
}

private final class AlbumResolutionRepository: AlbumRepository {
    private let driver: AlbumResolutionDriver
    @MainActor init(api: APIClient, driver: AlbumResolutionDriver) {
        self.driver = driver
        super.init(api: api)
    }
    override func ownedAlbum(named name: String, ownerID: String) async throws -> AlbumResponseDTO? {
        try await driver.all().first { $0.albumName == name }
    }
    override func create(name: String, description: String?, assetIds: [String]) async throws -> AlbumResponseDTO {
        try await driver.createAlbum(name)
    }
}

@MainActor
private final class AlbumResolutionFixture {
    let directory: URL
    let manager: SwiftDataManager
    let queue: BackupQueueStore
    let service: BackupService
    private let slot: RepositorySlot
    private var sessions: [AlbumResolutionSession]
    var driver: AlbumResolutionDriver { slot.driver }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-resolution-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
                                   backupJournalURL: directory.appendingPathComponent("backup.json"))
        queue = BackupQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let slot = RepositorySlot()
        self.slot = slot
        let session = try AlbumResolutionSession(owner: .init(server: "https://album-resolution.example/api", userID: "user"), manager: manager)
        sessions = [session]
        service = BackupService(dataManager: manager, queue: queue, makeAlbumRepository: {
            AlbumResolutionRepository(api: $0, driver: slot.driver)
        })
        service.configure(session: session)
        XCTAssertTrue(manager.isPersistentStoreAvailable)
    }

    func ownership() throws -> BackupUploadOwnership { try XCTUnwrap(queue.ownership) }
    func replaceSession(owner: BackupQueueOwner, driver: AlbumResolutionDriver) throws {
        slot.driver = driver
        let session = try AlbumResolutionSession(owner: owner, manager: manager)
        sessions.append(session)
        service.configure(session: session)
    }
    func cleanup() {
        service.resetForLogout()
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private final class RepositorySlot { var driver = AlbumResolutionDriver() }
}

@MainActor
private final class AlbumResolutionSession: SessionManager {
    private let owner: BackupQueueOwner
    override var backupQueueOwner: BackupQueueOwner? { owner }
    override var authHeaders: [String: String] { ["Authorization": "Bearer album-resolution-token"] }

    init(owner: BackupQueueOwner, manager: SwiftDataManager) throws {
        self.owner = owner
        super.init(dataManager: manager, restoresSession: false)
        try setServer(URL(string: owner.server)!.deletingLastPathComponent().absoluteString)
        isLoggedIn = true
    }
}

@MainActor
private final class AlbumResolutionGate<Value> {
    let started = XCTestExpectation(description: "An album API operation is held")
    private var waiters: [CheckedContinuation<Value, Error>] = []
    private var result: Result<Value, Error>?
    private var hasStarted = false

    func value() async throws -> Value {
        if !hasStarted { hasStarted = true; started.fulfill() }
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func complete(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}
