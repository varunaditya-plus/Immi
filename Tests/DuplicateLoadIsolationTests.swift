import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class DuplicateLoadIsolationTests: XCTestCase {
    private var directories: [URL] = []
    private var clients: [HeldDuplicateLoadAPI] = []

    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        clients.forEach { $0.close() }
        clients.removeAll()
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    func testLateLoadCannotRestoreAResolvedOrDismissedGroup() async throws {
        for keepAll in [false, true] {
            let fixture = try fixture()
            fixture.model.groups = [fixture.group]
            let load = Task { await fixture.model.load() }
            try await fixture.api.waitForLoad(0, testCase: self)

            if keepAll { await fixture.model.keepAll(fixture.group) }
            else { await fixture.model.resolve(fixture.group, keeping: [fixture.ids[0]]) }
            XCTAssertTrue(fixture.model.groups.isEmpty)
            try fixture.api.complete(0, groups: [fixture.group])
            await load.value
            // Restoring the photos cannot revive a group the server resolved.
            RemovedAssets.shared.restore(fixture.ids)

            XCTAssertTrue(fixture.model.groups.isEmpty)
            XCTAssertNil(fixture.model.actionError)
            assertLoaded(fixture.model)
        }
    }

    func testLateLoadFailureCannotReplaceASuccessfulDismissal() async throws {
        let fixture = try fixture()
        fixture.model.groups = [fixture.group]
        let load = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(0, testCase: self)
        await fixture.model.keepAll(fixture.group)

        try fixture.api.fail(0)
        await load.value

        XCTAssertTrue(fixture.model.groups.isEmpty)
        XCTAssertNil(fixture.model.actionError)
        assertLoaded(fixture.model)
    }

    func testRejectedResolutionDoesNotDiscardALegitimatePendingLoad() async throws {
        let fixture = try fixture()
        fixture.model.groups = [fixture.group]
        let load = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(0, testCase: self)
        fixture.api.rejectResolution = true

        await fixture.model.resolve(fixture.group, keeping: [fixture.ids[0]])
        let updated = DuplicateGroupDTO(duplicateId: fixture.group.id,
            assets: fixture.ids.map { makeTestAsset(id: $0) }, suggestedKeepAssetIds: [fixture.ids[2]])
        try fixture.api.complete(0, groups: [updated])
        await load.value

        XCTAssertEqual(fixture.model.groups.first?.assets.count, 3)
        XCTAssertEqual(fixture.model.groups.first?.suggestedKeepAssetIds, [fixture.ids[2]])
        XCTAssertEqual(fixture.model.actionError, "Resolution rejected")
        assertLoaded(fixture.model)
    }

    func testLatestLoadWinsAndCanceledLoadCanBeRetried() async throws {
        let fixture = try fixture()
        let old = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(0, testCase: self)
        let current = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(1, testCase: self)
        let updated = DuplicateGroupDTO(duplicateId: fixture.group.id,
            assets: fixture.ids.map { makeTestAsset(id: $0) })
        try fixture.api.complete(1, groups: [updated])
        await current.value
        try fixture.api.complete(0, groups: [fixture.group])
        await old.value
        XCTAssertEqual(fixture.model.groups.first?.assets.count, 3)

        let canceled = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(2, testCase: self)
        canceled.cancel()
        try fixture.api.complete(2, groups: [])
        await canceled.value
        XCTAssertEqual(fixture.model.groups.first?.assets.count, 3)
        let retry = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(3, testCase: self)
        try fixture.api.complete(3, groups: [fixture.group])
        await retry.value
        XCTAssertEqual(fixture.model.groups.first?.assets.count, 2)
        assertLoaded(fixture.model)
    }

    func testRetainedGroupsObserveLocksAndDeletionsWhileKeepingKnownArchives() async throws {
        let fixture = try fixture()
        let retained = DuplicateGroupDTO(duplicateId: fixture.group.id,
            assets: fixture.ids.map { makeTestAsset(id: $0) }, suggestedKeepAssetIds: [fixture.ids[0]])
        fixture.model.groups = [retained]
        try fixture.manager.setAssetVisibility([fixture.ids[0]], to: "archive")
        XCTAssertEqual(fixture.model.groups.first?.assets.count, 3)
        let changed = expectation(description: "Duplicate groups observe a lock from another screen")
        withObservationTracking { _ = fixture.model.groups } onChange: { changed.fulfill() }

        try fixture.manager.setAssetVisibility([fixture.ids[1]], to: "locked")

        XCTAssertEqual(fixture.model.groups.first?.assets.map(\.id), [fixture.ids[0], fixture.ids[2]])
        XCTAssertEqual(fixture.model.groups.first?.id, fixture.group.id)
        XCTAssertEqual(fixture.model.groups.first?.suggestedKeepAssetIds, [fixture.ids[0]])
        await fulfillment(of: [changed], timeout: 2)
        try fixture.manager.purgeAssets([fixture.ids[2]], reason: .trashed)
        XCTAssertTrue(fixture.model.groups.isEmpty, "A single remaining photo is no longer a duplicate group")
        let other = DuplicateGroupDTO(duplicateId: UUID().uuidString,
            assets: [makeTestAsset(id: UUID().uuidString), makeTestAsset(id: UUID().uuidString)])
        fixture.model.groups = [retained, other]
        await fixture.model.keepAll(other)
        XCTAssertTrue(fixture.model.groups.isEmpty)
        XCTAssertEqual(fixture.api.dismissedGroupIDs, [other.id])
        RemovedAssets.shared.restore([fixture.ids[2]])
        XCTAssertEqual(fixture.model.groups.first?.assets.map(\.id), [fixture.ids[0], fixture.ids[2]])
        XCTAssertEqual(fixture.api.loadCount, 0)
    }

    func testRawPrivateDuplicateAssetsAreHiddenBeforeCachingAndFreshArchivesRemainEligible() async throws {
        let fixture = try fixture()
        let visibility = ["timeline", "archive", "locked", "hidden", "future-private"]
        let photos = visibility.map { value in
            var asset = makeTestAsset(id: UUID().uuidString)
            asset.visibility = value
            asset.isArchived = value != "timeline"
            return asset
        }
        let group = DuplicateGroupDTO(duplicateId: fixture.group.id, assets: photos,
            suggestedKeepAssetIds: [photos[1].id])
        XCTAssertTrue(photos.allSatisfy { fixture.manager.getCachedAsset(id: $0.id) == nil })
        fixture.model.groups = [group]
        XCTAssertEqual(fixture.model.groups.first?.assets.map(\.id), Array(photos.prefix(2)).map(\.id),
            "Raw private evidence must be honored before the visibility index knows those IDs")

        let load = Task { await fixture.model.load() }
        try await fixture.api.waitForLoad(0, testCase: self)
        try fixture.api.complete(0, groups: [group])
        await load.value

        XCTAssertEqual(fixture.model.groups.first?.assets.map(\.id), Array(photos.prefix(2)).map(\.id))
        XCTAssertEqual(fixture.model.groups.first?.initialKeepAssetIDs, [photos[1].id])
        XCTAssertEqual(fixture.manager.archivedAssetIDs, [photos[1].id])
        XCTAssertEqual(fixture.manager.privateAssetIDs, Set(photos.dropFirst(2).map(\.id)))
        assertLoaded(fixture.model)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-load-\(UUID())")
        directories.append(directory)
        let manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        XCTAssertTrue(manager.isPersistentStoreAvailable)
        let ids = (0..<3).map { _ in UUID().uuidString }
        for id in ids { try manager.insertOrUpdateCachedAsset(CachedAsset(id: id, assetId: id, type: "IMAGE")) }
        let group = DuplicateGroupDTO(duplicateId: UUID().uuidString,
            assets: ids.prefix(2).map { makeTestAsset(id: $0) })
        let api = HeldDuplicateLoadAPI(groupID: group.id)
        clients.append(api)
        let model = DuplicatesViewModel(repository: DuplicateRepository(api: api, dataManager: manager),
            assetRepository: AssetDetailRepository(api: api, dataManager: manager),
            usesResolveEndpoint: true, dataManager: manager)
        return Fixture(manager: manager, api: api, model: model, group: group, ids: ids)
    }

    private func assertLoaded(_ model: DuplicatesViewModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .loaded = model.phase {} else { XCTFail("Expected loaded phase", file: file, line: line) }
    }

    private struct Fixture {
        let manager: SwiftDataManager
        let api: HeldDuplicateLoadAPI
        let model: DuplicatesViewModel
        let group: DuplicateGroupDTO
        let ids: [String]
    }
}

@MainActor
private final class HeldDuplicateLoadAPI: APIClient {
    let groupID: String
    var rejectResolution = false
    private(set) var loadCount = 0
    private(set) var dismissedGroupIDs: [String] = []
    private var pending: [Int: CheckedContinuation<[DuplicateGroupDTO], Error>] = [:]
    private var observers: [Int: XCTestExpectation] = [:]

    init(groupID: String) {
        self.groupID = groupID
        super.init(session: MockSessionManager())
    }

    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        if endpoint.path == "/duplicates" {
            let index = loadCount
            loadCount += 1
            let groups: [DuplicateGroupDTO] = try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                observers.removeValue(forKey: index)?.fulfill()
            }
            return try XCTUnwrap(groups as? T)
        }
        guard endpoint.path == "/duplicates/resolve" else { throw URLError(.unsupportedURL) }
        if rejectResolution { throw APIError.server(status: 200, message: "Resolution rejected") }
        return try JSONDecoder().decode(T.self, from: Data("[{\"id\":\"\(groupID)\",\"success\":true}]".utf8))
    }

    override func sendVoid(_ endpoint: Endpoint) async throws {
        XCTAssertEqual(endpoint.method, .delete)
        XCTAssertTrue(endpoint.path.hasPrefix("/duplicates/"))
        dismissedGroupIDs.append(String(endpoint.path.dropFirst("/duplicates/".count)))
    }

    func waitForLoad(_ index: Int, testCase: XCTestCase) async throws {
        let started = XCTestExpectation(description: "Duplicate load \(index) started")
        if loadCount > index { started.fulfill() } else { observers[index] = started }
        await testCase.fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(pending[index])
    }

    func complete(_ index: Int, groups: [DuplicateGroupDTO]) throws {
        try XCTUnwrap(pending.removeValue(forKey: index)).resume(returning: groups)
    }

    func fail(_ index: Int) throws {
        try XCTUnwrap(pending.removeValue(forKey: index))
            .resume(throwing: APIError.server(status: 503, message: "Old duplicate load failed"))
    }

    func close() {
        let continuations = Array(pending.values)
        pending.removeAll()
        observers.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}
