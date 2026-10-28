import XCTest
@testable import ImmichApp

@MainActor
final class SharedLinksConsistencyTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LocalSnapshot.clearAll()
    }

    override func tearDown() async throws {
        LocalSnapshot.clearAll()
        try await super.tearDown()
    }

    func testNewestListPublishesSortedRowsAndRejectsAnOlderResponse() async throws {
        let driver = SharedListDriver()
        let old = SharedListGate<[SharedLinkDTO]>()
        driver.list = { [weak driver] in
            if driver?.listCalls == 1 { return try await old.value() }
            return [try self.link("older", date: "2026-01-01T00:00:00.000Z"),
                    try self.link("newer", date: "2026-02-01T00:00:00.000Z")]
        }
        let model = model(driver)
        let first = Task { await model.load() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await first.value }
        await fulfillment(of: [old.started], timeout: 2)
        await model.load()
        old.complete(.success([try link("obsolete")]))
        await first.value

        XCTAssertEqual(model.links.map(\.id), ["newer", "older"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertEqual(driver.listCalls, 2)
    }

    func testOlderFailureCannotChangeANewerSuccessfulRefresh() async throws {
        let driver = SharedListDriver()
        let old = SharedListGate<[SharedLinkDTO]>()
        driver.list = { [weak driver] in driver?.listCalls == 1 ? try await old.value() : [] }
        let model = model(driver)
        let first = Task { await model.load() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await first.value }
        await fulfillment(of: [old.started], timeout: 2)
        let refreshError = await model.refresh()
        old.complete(.failure(APIError.unknown))
        await first.value

        XCTAssertNil(refreshError)
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
    }

    func testAcceptedDeletionCannotBeUndoneByAnOlderRefresh() async throws {
        let driver = SharedListDriver()
        let old = SharedListGate<[SharedLinkDTO]>()
        driver.list = { try await old.value() }
        let model = model(driver)
        let initial = [try link("deleted"), try link("kept")]
        model.links = initial
        model.phase = .loaded(())
        let refresh = Task { await model.refresh() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); _ = await refresh.value }
        await fulfillment(of: [old.started], timeout: 2)
        let deletionError = await model.delete("deleted")
        old.complete(.success(initial))
        let refreshError = await refresh.value

        XCTAssertNil(deletionError)
        XCTAssertNil(refreshError)
        XCTAssertEqual(model.links.map(\.id), ["kept"])
        XCTAssertNotNil(model.phase.value)
    }

    func testARefreshStartedDuringDeletionCannotRestoreTheDeletedLink() async throws {
        let driver = SharedListDriver()
        let deletion = SharedListGate<Void>()
        let read = SharedListGate<[SharedLinkDTO]>()
        driver.delete = { _ in try await deletion.value() }
        driver.list = { try await read.value() }
        let model = model(driver)
        let initial = [try link("deleted")]
        model.links = initial
        let delete = Task { await model.delete("deleted") }
        addTeardownBlock { await deletion.complete(.failure(CancellationError())); _ = await delete.value }
        await fulfillment(of: [deletion.started], timeout: 2)
        let refresh = Task { await model.refresh() }
        addTeardownBlock { await read.complete(.failure(CancellationError())); _ = await refresh.value }
        await fulfillment(of: [read.started], timeout: 2)
        deletion.complete(.success(()))
        _ = await delete.value
        read.complete(.success(initial))
        _ = await refresh.value

        XCTAssertTrue(model.links.isEmpty)
        XCTAssertNotNil(model.phase.value)
    }

    func testAcceptedEditSurvivesAnOlderListAndKeepsOmittedRelationships() async throws {
        let driver = SharedListDriver()
        let old = SharedListGate<[SharedLinkDTO]>()
        driver.list = { try await old.value() }
        driver.update = { _, _ in try self.link("link", description: "Saved", type: "ALBUM") }
        let model = model(driver)
        let original = try link("link", description: "Old", albumID: "related-album")
        model.links = [original]
        let load = Task { await model.load() }
        addTeardownBlock { await old.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [old.started], timeout: 2)
        let error = await model.update("link", edit: .init(description: .some("Saved")))
        old.complete(.success([original]))
        await load.value

        XCTAssertNil(error)
        XCTAssertEqual(model.links.first?.description, "Saved")
        XCTAssertEqual(model.links.first?.album?.id, "related-album")
        XCTAssertEqual(model.links.first?.type, "ALBUM")
    }

    func testARejectedMutationDoesNotInvalidateFreshListData() async throws {
        let driver = SharedListDriver()
        let read = SharedListGate<[SharedLinkDTO]>()
        driver.list = { try await read.value() }
        driver.delete = { _ in throw APIError.unknown }
        let model = model(driver)
        model.links = [try link("kept", description: "Old")]
        let refresh = Task { await model.refresh() }
        addTeardownBlock { await read.complete(.failure(CancellationError())); _ = await refresh.value }
        await fulfillment(of: [read.started], timeout: 2)
        let deletionError = await model.delete("kept")
        read.complete(.success([try link("kept", description: "Current")]))
        _ = await refresh.value

        XCTAssertNotNil(deletionError)
        XCTAssertEqual(model.links.first?.description, "Current")
        XCTAssertNotNil(model.phase.value)
    }

    func testAnOlderEditCannotOverwriteTheLatestEditOrResurrectADeletedRow() async throws {
        for delete in [false, true] {
            let driver = SharedListDriver()
            let old = SharedListGate<SharedLinkDTO>()
            driver.update = { _, edit in
                if edit.description == .some(.some("Old submitted")) { return try await old.value() }
                return try self.link("link", description: "Latest")
            }
            let model = model(driver)
            model.links = [try link("link")]
            let edit = Task { await model.update("link", edit: .init(description: .some("Old submitted"))) }
            addTeardownBlock { await old.complete(.failure(CancellationError())); _ = await edit.value }
            await fulfillment(of: [old.started], timeout: 2)
            if delete { _ = await model.delete("link") }
            else { _ = await model.update("link", edit: .init(description: .some("Latest"))) }
            old.complete(.success(try link("link", description: "Old submitted")))
            _ = await edit.value

            XCTAssertEqual(model.links.map(\.id), delete ? [] : ["link"])
            if !delete { XCTAssertEqual(model.links.first?.description, "Latest") }
        }
    }

    func testCanceledLoadPreservesAnAlreadyVerifiedEmptyList() async throws {
        let driver = SharedListDriver()
        let read = SharedListGate<[SharedLinkDTO]>()
        driver.list = { try await read.value() }
        let model = model(driver)
        model.phase = .loaded(())
        let load = Task { await model.load() }
        addTeardownBlock { await read.complete(.failure(CancellationError())); await load.value }
        await fulfillment(of: [read.started], timeout: 2)
        load.cancel()
        read.complete(.success([try link("canceled")]))
        await load.value

        XCTAssertTrue(model.links.isEmpty)
        XCTAssertNotNil(model.phase.value)
        XCTAssertNil(model.phase.errorMessage)
        driver.list = { [try self.link("next")] }
        await model.load()
        XCTAssertEqual(model.links.map(\.id), ["next"])
    }

    func testRefreshFailureKeepsLoadedRowsAndReturnsTheError() async throws {
        let driver = SharedListDriver()
        driver.list = { throw APIError.unknown }
        let model = model(driver)
        model.links = [try link("visible")]
        model.phase = .loaded(())

        let error = await model.refresh()

        XCTAssertNotNil(error)
        XCTAssertEqual(model.links.map(\.id), ["visible"])
        XCTAssertNotNil(model.phase.value)
        await model.load()
        XCTAssertNotNil(model.phase.errorMessage, "An explicit initial/retry load still exposes its failure")
    }

    func testAccountChangesRejectPendingListAndUpdatePublication() async throws {
        let driver = SharedListDriver()
        let read = SharedListGate<[SharedLinkDTO]>()
        let updated = SharedListGate<SharedLinkDTO>()
        driver.list = { try await read.value() }
        driver.update = { _, _ in try await updated.value() }
        let model = model(driver)
        model.links = [try link("old", description: "Existing")]
        let load = Task { await model.load() }
        let update = Task { await model.update("old", edit: .init(description: .some("Submitted"))) }
        addTeardownBlock {
            await read.complete(.failure(CancellationError())); await updated.complete(.failure(CancellationError()))
            await load.value; _ = await update.value
        }
        await fulfillment(of: [read.started, updated.started], timeout: 2)
        LocalSnapshot.clearAll()
        read.complete(.success([try link("other")]))
        updated.complete(.success(try link("old", description: "Late accepted")))
        await load.value
        _ = await update.value

        XCTAssertEqual(model.links.map(\.id), ["old"])
        XCTAssertEqual(model.links.first?.description, "Existing")
        let oldCalls = driver.listCalls
        await model.load()
        XCTAssertEqual(driver.listCalls, oldCalls, "An old model cannot start requests for the next account")
    }

    private func model(_ driver: SharedListDriver) -> SharedLinksViewModel {
        SharedLinksViewModel(repo: ConsistencySharedRepository(api: APIClient(session: MockSessionManager()), driver: driver))
    }

    private func link(_ id: String, description: String? = nil, albumID: String? = nil,
                      type: String = "INDIVIDUAL", date: String = "2026-01-01T00:00:00.000Z") throws -> SharedLinkDTO {
        var json: [String: Any] = ["id": id, "key": "key-\(id)", "type": albumID == nil ? type : "ALBUM", "createdAt": date]
        json["description"] = description
        if let albumID {
            json["album"] = ["id": albumID, "albumName": "Album", "assetCount": 1, "shared": false, "createdAt": date]
        }
        return try JSONDecoder.immich.decode(SharedLinkDTO.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
private final class SharedListDriver {
    var list: @MainActor () async throws -> [SharedLinkDTO] = { [] }
    var update: @MainActor (String, SharedLinkEditDTO) async throws -> SharedLinkDTO = { _, _ in throw APIError.unknown }
    var delete: @MainActor (String) async throws -> Void = { _ in }
    private(set) var listCalls = 0
    func all() async throws -> [SharedLinkDTO] { listCalls += 1; return try await list() }
}

private final class ConsistencySharedRepository: SharedLinkRepository {
    let driver: SharedListDriver
    init(api: APIClient, driver: SharedListDriver) { self.driver = driver; super.init(api: api) }
    override func all() async throws -> [SharedLinkDTO] { try await driver.all() }
    override func update(_ id: String, edit: SharedLinkEditDTO) async throws -> SharedLinkDTO {
        try await driver.update(id, edit)
    }
    override func delete(_ id: String) async throws { try await driver.delete(id) }
}

@MainActor
private final class SharedListGate<Value> {
    let started = XCTestExpectation(description: "A shared link request reached its held response")
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
