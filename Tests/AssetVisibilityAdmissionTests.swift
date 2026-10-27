import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AssetVisibilityAdmissionTests: XCTestCase {
    override func setUp() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    override func tearDown() async throws {
        RemovedAssets.shared.clear()
        DeletedServerAssetRegistry.shared.clear()
    }

    func testFreshArchiveMetadataRefinesLegacyPrivacyWithoutASyncOrActionRevision() async throws {
        for source in AdmissionSource.allCases {
            let fixture = try AdmissionFixture()
            defer { fixture.cleanup() }
            try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
            fixture.api.items = [asset("photo", visibility: "archive")]
            let revision = fixture.store.assetMutationRevision
            XCTAssertFalse(AssetVisibilityPolicy(dataManager: fixture.store).allows(id: "photo"))

            let fetched = try await source.load(fixture)

            XCTAssertEqual(fetched.map(\.id), ["photo"], source.rawValue)
            XCTAssertEqual(fixture.store.archivedAssetIDs, ["photo"], source.rawValue)
            XCTAssertTrue(fixture.store.privateAssetIDs.isEmpty, source.rawValue)
            XCTAssertTrue(AssetVisibilityPolicy(dataManager: fixture.store).allows(id: "photo"), source.rawValue)
            XCTAssertEqual(fixture.store.assetMutationRevision, revision, source.rawValue)
            let reopened = fixture.reopen()
            XCTAssertEqual(reopened.archivedAssetIDs, ["photo"], source.rawValue)
            XCTAssertTrue(reopened.privateAssetIDs.isEmpty, source.rawValue)
        }
    }

    func testArchiveGridAcceptsItsFreshResultInsteadOfRejectingItsOwnCachePublication() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
        fixture.api.items = [asset("photo", visibility: "archive")]
        let repository = SearchRepository(api: fixture.api, dataManager: fixture.store)
        let model = AssetGridViewModel(assetRepo: AssetDetailRepository(api: fixture.api),
            albumRepo: AlbumRepository(api: fixture.api), dataManager: fixture.store) {
                try await repository.allMetadata(SearchRequestDTO(visibility: "archive")).map(AssetLite.init)
            }

        await model.load()

        XCTAssertEqual(AssetVisibilityPolicy(dataManager: fixture.store).filter(model.assets).map(\.id), ["photo"])
        if case .loaded = model.phase { } else { XCTFail("Fresh archive admission must not invalidate its own grid load") }
    }

    func testResponsesHeldBeforeALockCannotRefineTheNewPrivateState() async throws {
        for source in AdmissionSource.allCases {
            let fixture = try AdmissionFixture()
            defer { fixture.cleanup() }
            try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
            fixture.api.items = [asset("photo", visibility: "archive"), asset("other", visibility: "timeline")]
            let gate = AdmissionGate()
            fixture.api.beforeResponse = { await gate.wait() }
            let load = Task { try await source.load(fixture) }
            addTeardownBlock { await gate.close(); _ = try? await load.value }
            await fulfillment(of: [gate.started], timeout: 2)

            try fixture.store.setAssetVisibility(["photo"], to: "locked")
            gate.release()
            let fetched = try await load.value

            XCTAssertEqual(fixture.store.privateAssetIDs, ["photo"], source.rawValue)
            XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty, source.rawValue)
            let visible = AssetVisibilityPolicy(dataManager: fixture.store).filter(fetched)
            XCTAssertFalse(visible.contains { $0.id == "photo" }, source.rawValue)
            if source != .detail {
                XCTAssertEqual(visible.map(\.id), ["other"], "Unrelated public response items remain usable: \(source.rawValue)")
            }
        }
    }

    func testUnchangedPrivateObservationInvalidatesAnOlderArchiveResponseWithoutWritingTheStore() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
        let oldJournal = try Data(contentsOf: fixture.journalURL)
        let previousRevision = fixture.store.visibilityMutationRevision
        let gate = AdmissionGate()
        fixture.api.items = [asset("photo", visibility: "archive")]
        fixture.api.beforeResponse = { await gate.wait() }
        let oldLoad = Task { try await SearchRepository(api: fixture.api, dataManager: fixture.store)
            .metadataSearch(SearchRequestDTO()) }
        addTeardownBlock { await gate.close(); _ = try? await oldLoad.value }
        await fulfillment(of: [gate.started], timeout: 2)
        let currentAPI = AdmissionAPI(session: fixture.session)
        currentAPI.items = [asset("photo", visibility: "locked")]

        _ = try await SearchRepository(api: currentAPI, dataManager: fixture.store).metadataSearch(SearchRequestDTO())
        XCTAssertNotEqual(fixture.store.visibilityMutationRevision, previousRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal,
            "Unchanged privacy observations must not rewrite durable classifications")
        gate.release()
        _ = try await oldLoad.value

        XCTAssertEqual(fixture.store.privateAssetIDs, ["photo"])
        XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty)
    }

    func testAStalePaginatedQueryCannotRecaptureAuthorityOnALaterPage() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["first", "second"], inTimeline: false)
        let gate = AdmissionGate()
        fixture.api.responses = [response([asset("first", visibility: "archive")], total: 2, next: "2"),
                                 response([asset("second", visibility: "archive")], total: 2)]
        fixture.api.beforeResponse = { if fixture.api.requestCount == 1 { await gate.wait() } }
        let load = Task { try await SearchRepository(api: fixture.api, dataManager: fixture.store)
            .allMetadata(SearchRequestDTO()) }
        addTeardownBlock { await gate.close(); _ = try? await load.value }
        await fulfillment(of: [gate.started], timeout: 2)
        try fixture.store.setAssetVisibility(["first", "second"], to: "locked")
        gate.release()

        let raw = try await load.value

        XCTAssertEqual(raw.map(\.id), ["first", "second"])
        XCTAssertEqual(fixture.api.requestCount, 2)
        XCTAssertEqual(fixture.store.privateAssetIDs, ["first", "second"])
        XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty)
    }

    func testPaginatedQueryKeepsAuthorityAfterItsOwnPrivateObservation() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["archive"], inTimeline: false)
        fixture.api.responses = [response([asset("private", visibility: "locked")], total: 2, next: "2"),
                                 response([asset("archive", visibility: "archive")], total: 2)]

        let raw = try await SearchRepository(api: fixture.api, dataManager: fixture.store)
            .allMetadata(SearchRequestDTO())

        XCTAssertEqual(raw.map(\.id), ["private", "archive"])
        XCTAssertEqual(fixture.store.privateAssetIDs, ["private"])
        XCTAssertEqual(fixture.store.archivedAssetIDs, ["archive"])
    }

    func testAccountAndSnapshotChangesPreventVisibilityPublicationFromHeldResponses() async throws {
        for changeServer in [false, true] {
            let fixture = try AdmissionFixture()
            defer { fixture.cleanup() }
            try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
            fixture.api.items = [asset("photo", visibility: "archive")]
            let gate = AdmissionGate()
            fixture.api.beforeResponse = { await gate.wait() }
            let load = Task { try await SearchRepository(api: fixture.api, dataManager: fixture.store)
                .metadataSearch(SearchRequestDTO()) }
            addTeardownBlock { await gate.close(); _ = try? await load.value }
            await fulfillment(of: [gate.started], timeout: 2)
            if changeServer { try fixture.session.setServer("https://replacement-visibility.example") }
            else { LocalSnapshot.clearAll() }
            gate.release()
            _ = try await load.value

            XCTAssertEqual(fixture.store.privateAssetIDs, ["photo"])
            XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty)
        }
    }

    func testFailedArchiveAdmissionStaysPrivateAndTrashedMetadataCannotReleaseOrRestore() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["photo", "trashed"], inTimeline: false)
        DeletedServerAssetRegistry.shared.record(["deleted"], permanently: false)
        RemovedAssets.shared.remove(["deleted"], reason: .trashed)
        try FileManager.default.removeItem(at: fixture.journalURL)
        try FileManager.default.createDirectory(at: fixture.journalURL, withIntermediateDirectories: true)
        var trashed = makeTestAsset(id: "trashed", isTrashed: true)
        trashed.visibility = "timeline"
        fixture.api.items = [asset("photo", visibility: "archive"), trashed,
                             asset("deleted", visibility: "timeline"), asset("other", visibility: "timeline")]

        let raw = try await SearchRepository(api: fixture.api, dataManager: fixture.store)
            .metadataSearch(SearchRequestDTO())

        XCTAssertEqual(fixture.store.privateAssetIDs, ["photo", "trashed"])
        XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty)
        XCTAssertTrue(DeletedServerAssetRegistry.shared.isTrashed("deleted"))
        XCTAssertTrue(RemovedAssets.shared.ids.contains("deleted"))
        XCTAssertEqual(AssetVisibilityPolicy(dataManager: fixture.store)
            .filter(raw.assets.items.map(AssetLite.init)).map(\.id), ["other"])
    }

    func testPrivateEvidenceWinsRepeatedIDsRegardlessOfMemoryPayloadOrder() async throws {
        for privateFirst in [false, true] {
            let fixture = try AdmissionFixture()
            defer { fixture.cleanup() }
            try fixture.store.setTimelineVisibility(["photo"], inTimeline: false)
            let locked = asset("photo", visibility: "locked")
            let archive = asset("photo", visibility: "archive")
            fixture.api.items = privateFirst ? [locked, archive] : [archive, locked]

            _ = try await MemoriesRepository(api: fixture.api, dataManager: fixture.store).getMemories()

            XCTAssertEqual(fixture.store.privateAssetIDs, ["photo"])
            XCTAssertTrue(fixture.store.archivedAssetIDs.isEmpty)
        }
    }

    private func asset(_ id: String, visibility: String) -> AssetResponseDTO {
        var result = makeTestAsset(id: id, isArchived: visibility == "archive")
        result.visibility = visibility
        return result
    }

    private func response(_ items: [AssetResponseDTO], total: Int, next: String? = nil) -> SearchResponseDTO {
        SearchResponseDTO(assets: .init(items: items, total: total, nextPage: next))
    }
}

private enum AdmissionSource: String, CaseIterable {
    case smart, metadata, allMetadata, album, cover, memories, detail

    @MainActor
    func load(_ fixture: AdmissionFixture) async throws -> [AssetLite] {
        switch self {
        case .smart:
            return try await SearchRepository(api: fixture.api, dataManager: fixture.store)
                .smartSearch(SearchRequestDTO()).assets.items.map(AssetLite.init)
        case .metadata:
            return try await SearchRepository(api: fixture.api, dataManager: fixture.store)
                .metadataSearch(SearchRequestDTO()).assets.items.map(AssetLite.init)
        case .allMetadata:
            return try await SearchRepository(api: fixture.api, dataManager: fixture.store)
                .allMetadata(SearchRequestDTO()).map(AssetLite.init)
        case .album:
            return try await TimelineRepository(api: fixture.api, dataManager: fixture.store).albumAssets("album")
        case .cover:
            return try await AlbumRepository(api: fixture.api, dataManager: fixture.store)
                .recentAssetIDs(in: "album", limit: 8).map { AssetLite(makeTestAsset(id: $0)) }
        case .memories:
            return try await MemoriesRepository(api: fixture.api, dataManager: fixture.store)
                .getMemories().flatMap(\.assets).map(AssetLite.init)
        case .detail:
            return [AssetLite(try await AssetDetailRepository(api: fixture.api, dataManager: fixture.store).fetchAsset("photo"))]
        }
    }
}

@MainActor
private final class AdmissionFixture {
    let directory: URL
    let store: SwiftDataManager
    let session: MockSessionManager
    let api: AdmissionAPI
    var journalURL: URL { directory.appendingPathComponent("backup.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        store.modelContext.autosaveEnabled = false
        session = MockSessionManager()
        try session.setServer("https://visibility-admission.example")
        api = AdmissionAPI(session: session)
    }

    func reopen() -> SwiftDataManager {
        SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"), backupJournalURL: journalURL)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class AdmissionGate {
    let started = XCTestExpectation(description: "A visibility response reached its hold boundary")
    private var continuation: CheckedContinuation<Void, Never>?
    private var closed = false

    func wait() async {
        guard !closed else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func release() {
        XCTAssertNotNil(continuation, "The request must reach its response boundary first")
        continuation?.resume()
        continuation = nil
    }

    func close() {
        closed = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AdmissionAPI: APIClient {
    var items: [AssetResponseDTO] = []
    var responses: [SearchResponseDTO] = []
    var beforeResponse: (@MainActor () async -> Void)?
    private(set) var requestCount = 0

    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        requestCount += 1
        let response = responses.isEmpty
            ? SearchResponseDTO(assets: .init(items: items, total: items.count, nextPage: nil))
            : responses.removeFirst()
        await beforeResponse?()
        let value: Any
        switch endpoint.path {
        case "/search/smart", "/search/metadata": value = response
        case "/memories":
            value = [MemoryDTO(id: "memory", type: "on_this_day", memoryAt: Date(),
                assets: response.assets.items, data: nil)]
        case "/assets/photo": value = try XCTUnwrap(response.assets.items.first)
        default: throw URLError(.unsupportedURL)
        }
        return try XCTUnwrap(value as? T)
    }
}
