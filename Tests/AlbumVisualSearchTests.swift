import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumVisualSearchTests: XCTestCase {
    private var directory: URL!
    private var manager: SwiftDataManager!
    private var transports: [URLSession] = []
    private var versionGates: [PeopleStateGate<ServerVersionDTO>] = []
    private var tasks: [Task<SearchResponseDTO, Error>] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-visual-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        PhotoSearchURLProtocol.statusCode = 200
    }

    override func tearDown() async throws {
        versionGates.forEach { $0.complete(.failure(CancellationError())) }
        for task in tasks { _ = try? await task.value }
        transports.forEach { $0.invalidateAndCancel() }
        PhotoSearchURLProtocol.handler = nil
        PhotoSearchURLProtocol.statusCode = 200
        let container = manager.modelContainer
        manager = nil
        try container.erase()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testStructuredAlbumVisualSearchFindsANonPartnerContributorAndKeepsEveryIndependentFilter() async throws {
        let session = AlbumVisualSearchSession()
        let ownOwner = UUID().uuidString, otherOwner = UUID().uuidString
        let album = UUID().uuidString, person = UUID().uuidString
        session.testAuthHeaders = ["X-Fixture-Owner": ownOwner]
        let api = try api(session: session)
        let foreignPhoto = AssetResponseDTO(id: UUID().uuidString, type: "IMAGE", originalFileName: "shore.jpg",
            fileCreatedAt: .now, isFavorite: true, isArchived: false, isTrashed: false, duration: nil,
            thumbhash: nil, localDateTime: .now, exifInfo: nil, people: nil, livePhotoVideoId: UUID().uuidString)
        let outsidePhoto = makeTestAsset(id: UUID().uuidString, isFavorite: true)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            let body = try log.record(request, data: bytes)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Fixture-Owner"), ownOwner)
            guard request.url?.lastPathComponent == "smart" else { return try Self.response([]) }
            if let filter = body["filter"] as? [String: Any] {
                let ids = (filter["albumIds"] as? [String: Any])?["all"] as? [String]
                // A fully confined structured scope searches authorized album members across owners.
                return try Self.response(ids == [album] ? [foreignPhoto] : [foreignPhoto, outsidePhoto], owner: otherOwner)
            }
            // The legacy service intersects the album with own/partner owners. This fixture has no partners.
            return try Self.response([])
        }
        var request = SearchRequestDTO(query: "sunset", albumIds: [album], type: "IMAGE", isMotion: true,
            isFavorite: true, takenAfter: "2020-01-01T00:00:00Z", takenBefore: "2030-01-01T00:00:00Z",
            city: "Paris", state: "Île-de-France", country: "France", personIds: [person])
        request.exclusiveTakenBefore = request.takenBefore

        let result = try await PhotoSearchRepository(api: api, dataManager: manager).search(request)

        XCTAssertEqual(result.assets.items.map(\.id), [foreignPhoto.id])
        XCTAssertEqual(result.assets.total, 1)
        XCTAssertNil(result.incompleteSources)
        XCTAssertEqual(session.versionCallCount, 1)
        let entries = log.entries
        XCTAssertEqual(entries.count, 4)
        let visual = try XCTUnwrap(entries.first { $0.path.hasSuffix("/smart") }?.body)
        XCTAssertEqual(Set(visual.keys), ["query", "size", "withExif", "filter"])
        XCTAssertEqual(visual["query"] as? String, "sunset")
        XCTAssertEqual(visual["size"] as? Int, 100)
        XCTAssertEqual(visual["withExif"] as? Bool, false)
        let filter = try XCTUnwrap(visual["filter"] as? [String: Any])
        XCTAssertEqual((filter["albumIds"] as? [String: Any])?["all"] as? [String], [album])
        XCTAssertEqual((filter["personIds"] as? [String: Any])?["all"] as? [String], [person])
        for (key, value) in [("type", "IMAGE"), ("city", "Paris"), ("state", "Île-de-France"),
                             ("country", "France"), ("visibility", "timeline")] {
            XCTAssertEqual((filter[key] as? [String: Any])?["eq"] as? String, value)
        }
        for key in ["isMotion", "isFavorite"] {
            XCTAssertEqual((filter[key] as? [String: Any])?["eq"] as? Bool, true)
        }
        let taken = try XCTUnwrap(filter["takenAt"] as? [String: Any])
        XCTAssertEqual(taken["gte"] as? String, request.takenAfter)
        XCTAssertEqual(taken["lt"] as? String, request.exclusiveTakenBefore)
        XCTAssertNil(taken["lte"])
        XCTAssertTrue((filter["trashedAt"] as? [String: Any])?["eq"] is NSNull)
        for entry in entries where !entry.path.hasSuffix("/smart") {
            XCTAssertNil(entry.body["filter"])
            XCTAssertEqual(entry.body["albumIds"] as? [String], [album])
            XCTAssertEqual(entry.body["personIds"] as? [String], [person])
            XCTAssertEqual(entry.body["takenBefore"] as? String, request.takenBefore)
        }
    }

    func testOlderAndPrereleaseServersKeepExactAlbumMatchesWithoutSendingAnUnsupportedVisualShape() async throws {
        for version in [ServerVersionDTO(major: 2, minor: 7, patch: 4), .init(major: 3, minor: 0, patch: 0),
                        .init(major: 3, minor: 1, patch: 9), .init(major: 3, minor: 2, patch: 0, prerelease: 1),
                        .init(major: 3, minor: 3, patch: 0, prerelease: 2), .init(major: 4, minor: 0, patch: 0)] {
            let session = AlbumVisualSearchSession()
            session.mockVersion = version
            try await assertExactMatchesSurviveUnsupportedVisualSearch(session: session)
            XCTAssertEqual(session.versionCallCount, 1)
        }
    }

    func testUnknownServerVersionKeepsExactAlbumMatchesAndDoesNotAttemptVisualSearch() async throws {
        let session = AlbumVisualSearchSession()
        session.versionFailure = APIError.notConnected
        try await assertExactMatchesSurviveUnsupportedVisualSearch(session: session)
    }

    func testCurrentVersionReadRejectsAStaleSupportedCompatibilityReportAfterAServerDowngrade() async throws {
        let session = AlbumVisualSearchSession()
        let api = try api(session: session)
        session.shouldSucceedPing = true
        _ = try await session.checkServerCompatibility()
        XCTAssertEqual(session.serverCompatibility?.version, .init(major: 3, minor: 3, patch: 5))
        session.mockVersion = .init(major: 3, minor: 1, patch: 0)

        try await assertExactMatchesSurviveUnsupportedVisualSearch(session: session, api: api)

        XCTAssertEqual(session.versionCallCount, 2, "An old login report cannot authorize a newer request shape")
    }

    func testStable32SupportsTheStructuredAlbumShapeAndDoesNotSendEmptyDateFilters() async throws {
        let session = AlbumVisualSearchSession()
        session.mockVersion = .init(major: 3, minor: 2, patch: 0)
        let api = try api(session: session)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }

        let repository = SearchRepository(api: api, dataManager: manager)
        _ = try await repository.smartSearch(SearchRequestDTO(query: "sunset", albumIds: [UUID().uuidString],
            isMotion: false, isFavorite: false, personIds: []))
        _ = try await repository.smartSearch(SearchRequestDTO(query: "sunset", albumIds: [UUID().uuidString],
            takenBefore: "2030-01-01T00:00:00Z"))

        let firstFilter = try XCTUnwrap(log.entries.first?.body["filter"] as? [String: Any])
        XCTAssertNil(firstFilter["takenAt"])
        XCTAssertNil(firstFilter["personIds"])
        XCTAssertEqual((firstFilter["isMotion"] as? [String: Any])?["eq"] as? Bool, false)
        XCTAssertEqual((firstFilter["isFavorite"] as? [String: Any])?["eq"] as? Bool, false)
        let body = try XCTUnwrap(log.entries.last?.body)
        let filter = try XCTUnwrap(body["filter"] as? [String: Any])
        let taken = try XCTUnwrap(filter["takenAt"] as? [String: Any])
        XCTAssertEqual(taken["lte"] as? String, "2030-01-01T00:00:00Z")
        XCTAssertNil(taken["lt"])
        XCTAssertNil(filter["personIds"])
        XCTAssertNil(filter["city"])
        XCTAssertEqual(log.entries.count, 2)
    }

    func testUnauthorizedAlbumCannotFallBackToAnUnscopedVisualOrMetadataSearch() async throws {
        let api = try api()
        let album = UUID().uuidString
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.statusCode = 403
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return Data(#"{"message":"Album access denied"}"#.utf8)
        }

        do {
            _ = try await PhotoSearchRepository(api: api, dataManager: manager)
                .search(SearchRequestDTO(query: "sunset", albumIds: [album]))
            XCTFail("An unauthorized album must not expose another search universe")
        } catch APIError.server(let status, _) { XCTAssertEqual(status, 403) }
        catch { XCTFail("Expected the server's access failure, received \(error)") }

        XCTAssertEqual(log.entries.count, 4)
        for entry in log.entries {
            if entry.path.hasSuffix("/smart") {
                let filter = try XCTUnwrap(entry.body["filter"] as? [String: Any])
                XCTAssertEqual((filter["albumIds"] as? [String: Any])?["all"] as? [String], [album])
                XCTAssertNil(entry.body["albumIds"])
            } else {
                XCTAssertEqual(entry.body["albumIds"] as? [String], [album])
                XCTAssertNil(entry.body["filter"])
            }
        }
    }

    func testRawAlbumVisualOCRCriteriaRemainLiteralAndUnsupportedMetadataOnlyFieldsAreNotMixedIn() async throws {
        let api = try api()
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }
        let request = SearchRequestDTO(query: "sunset", page: nil, albumIds: [UUID().uuidString],
            order: "asc", isNotInAlbum: true, ocr: "invoice_100%", withPeople: true)

        let repository = SearchRepository(api: api, dataManager: manager)
        _ = try await repository.smartSearch(request)

        let body = try XCTUnwrap(log.entries.first?.body)
        let filter = try XCTUnwrap(body["filter"] as? [String: Any])
        XCTAssertEqual((filter["ocr"] as? [String: Any])?["matches"] as? String, "invoice_100%")
        XCTAssertNil(filter["hasAlbums"], "Legacy isNotInAlbum is ignored inside an explicit album scope")
        XCTAssertNil(body["ocr"])
        XCTAssertNil(body["order"])
        XCTAssertNil(body["withPeople"])
        XCTAssertNil(body["page"])
        var emptyOCR = request
        emptyOCR.ocr = ""
        _ = try await repository.smartSearch(emptyOCR)
        let emptyFilter = try XCTUnwrap(log.entries.last?.body["filter"] as? [String: Any])
        XCTAssertNil(emptyFilter["ocr"], "An empty legacy OCR value did not add a predicate")
        XCTAssertEqual(log.entries.count, 2)
    }

    func testRawAlbumVisualSearchRejectsContinuationAndInvalidPagesBeforeVersionOrAssetReads() async throws {
        let session = AlbumVisualSearchSession()
        let api = try api(session: session)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }
        let repository = SearchRepository(api: api, dataManager: manager)
        for page in [0, -1, 2, Int.max] {
            do {
                _ = try await repository.smartSearch(SearchRequestDTO(query: "sunset", page: page,
                    albumIds: [UUID().uuidString]))
                XCTFail("A non-first structured visual page cannot silently repeat page one")
            } catch PhotoSearchError.incompletePage {}
            catch { XCTFail("Expected the unsupported-page failure, received \(error)") }
        }
        XCTAssertEqual(session.versionCallCount, 0)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testRawAlbumVisualTrashFiltersPreserveDefaultExclusionAndExplicitLegacyInclusion() async throws {
        let api = try api()
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }
        let repository = SearchRepository(api: api, dataManager: manager)
        for withDeleted in [nil, false, true] as [Bool?] {
            for after in [nil, "2020-01-01T00:00:00Z"] as [String?] {
                _ = try await repository.smartSearch(SearchRequestDTO(query: "sunset", albumIds: [UUID().uuidString],
                    withDeleted: withDeleted, trashedAfter: after))
                let body = try XCTUnwrap(log.entries.last?.body)
                let filter = try XCTUnwrap(body["filter"] as? [String: Any])
                let trash = filter["trashedAt"] as? [String: Any]
                if let after {
                    XCTAssertEqual(trash?["gte"] as? String, after)
                    XCTAssertNil(trash?["eq"])
                } else if withDeleted == true {
                    XCTAssertNil(trash)
                } else {
                    XCTAssertTrue(trash?["eq"] is NSNull)
                }
                XCTAssertNil(body["withDeleted"])
                XCTAssertNil(body["trashedAfter"])
            }
        }
        XCTAssertEqual(log.entries.count, 6)
    }

    func testRawVisibilityOmissionKeepsServerPolicyWhileTheNativeSearchStillForcesTimeline() async throws {
        let api = try api()
        let album = UUID().uuidString
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }
        let repository = SearchRepository(api: api, dataManager: manager)
        for visibility in [nil, "archive"] as [String?] {
            _ = try await repository.smartSearch(SearchRequestDTO(query: "sunset", albumIds: [album], visibility: visibility))
        }
        _ = try await PhotoSearchRepository(api: api, dataManager: manager)
            .search(SearchRequestDTO(query: "sunset", albumIds: [album], visibility: nil))

        let visuals = log.entries.filter { $0.path.hasSuffix("/smart") }
        XCTAssertEqual(visuals.count, 3)
        let filters = try visuals.map { try XCTUnwrap($0.body["filter"] as? [String: Any]) }
        let expected: [String?] = [nil, "archive", "timeline"]
        for (filter, visibility) in zip(filters, expected) {
            if let visibility {
                XCTAssertEqual((filter["visibility"] as? [String: Any])?["eq"] as? String, visibility)
            } else {
                XCTAssertNil(filter["visibility"], "An omitted raw criterion delegates to the server's locked-asset policy")
            }
        }
        let metadata = log.entries.filter { $0.path.hasSuffix("/metadata") }
        XCTAssertEqual(metadata.count, 3)
        XCTAssertTrue(metadata.allSatisfy { $0.body["visibility"] as? String == "timeline" })
    }

    func testAContextChangeDuringTheVersionReadCannotSendTheAlbumVisualRequest() async throws {
        let session = AlbumVisualSearchSession()
        let gate = PeopleStateGate<ServerVersionDTO>()
        versionGates.append(gate)
        session.versionOperation = { try await gate.value() }
        let api = try api(session: session)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            _ = try log.record(request, data: bytes)
            return try Self.response([])
        }
        let pending = Task {
            try await PhotoSearchRepository(api: api, dataManager: manager)
                .search(SearchRequestDTO(query: "sunset", albumIds: [UUID().uuidString]))
        }
        tasks.append(pending)
        await fulfillment(of: [gate.started], timeout: 2)

        try session.setServer("https://different-album-search.example")
        gate.complete(.success(.init(major: 3, minor: 3, patch: 5)))

        do { _ = try await pending.value; XCTFail("An obsolete version lookup must cancel the search") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, received \(error)") }
        XCTAssertFalse(log.entries.contains { $0.path.hasSuffix("/smart") })
    }

    private func assertExactMatchesSurviveUnsupportedVisualSearch(session: AlbumVisualSearchSession,
                                                                 api suppliedAPI: APIClient? = nil) async throws {
        let api = try suppliedAPI ?? api(session: session)
        let album = UUID().uuidString, caption = makeTestAsset(id: UUID().uuidString)
        let log = PhotoSearchRequestLog()
        PhotoSearchURLProtocol.handler = { request, bytes in
            let body = try log.record(request, data: bytes)
            return try Self.response(body["description"] == nil ? [] : [caption])
        }

        let result = try await PhotoSearchRepository(api: api, dataManager: manager)
            .search(SearchRequestDTO(query: "sunset", albumIds: [album]))

        XCTAssertEqual(result.assets.items.map(\.id), [caption.id])
        XCTAssertEqual(result.assets.total, 1)
        XCTAssertEqual(result.incompleteSources, ["smart"])
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertTrue(log.entries.allSatisfy { $0.path.hasSuffix("/metadata") })
        XCTAssertTrue(log.entries.allSatisfy { $0.body["albumIds"] as? [String] == [album] && $0.body["filter"] == nil })
    }

    private func api(session provided: AlbumVisualSearchSession? = nil) throws -> APIClient {
        let session = provided ?? AlbumVisualSearchSession()
        try session.setServer("https://album-visual.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoSearchURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        transports.append(transport)
        return APIClient(session: session, urlSession: transport)
    }

    private nonisolated static func response(_ assets: [AssetResponseDTO], owner: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(assets)) as? [[String: Any]])
        if let owner { for index in values.indices { values[index]["ownerId"] = owner } }
        return try JSONSerialization.data(withJSONObject: ["assets": ["items": values, "total": values.count, "nextPage": NSNull()]])
    }
}

@MainActor
private final class AlbumVisualSearchSession: MockSessionManager {
    var versionFailure: Error?
    var versionOperation: (() async throws -> ServerVersionDTO)?

    override init() {
        super.init()
        mockVersion = .init(major: 3, minor: 3, patch: 5)
    }

    override func serverVersion() async throws -> ServerVersionDTO {
        if let versionFailure { throw versionFailure }
        if let versionOperation { return try await versionOperation() }
        return try await super.serverVersion()
    }
}
