import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class MetadataCollectionPaginationTests: XCTestCase {
    private var directory: URL!
    private var store: SwiftDataManager!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-pages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        store = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try await super.tearDown()
    }

    func testActualContinuationPagesAndOriginalFiltersArePreserved() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var bodies: [[String: Any]] = []
            MockURLProtocol.responseProvider = { request in
                let body = Self.body(request)
                bodies.append(body)
                let page = body["page"] as? Int ?? 0
                switch page {
                case 1: return Self.response(request, ids: ["first"], next: "4", total: 1)
                case 4: return Self.response(request, ids: ["second"], next: "8", total: 1)
                case 8: return Self.response(request, ids: ["last"], next: nil, total: 50_000)
                default: return (nil, nil, URLError(.unsupportedURL))
                }
            }

            let assets = try await source.load(api: api, store: store)

            XCTAssertEqual(assets.map(\.id), ["first", "second", "last"], source.rawValue)
            XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 4, 8])
            XCTAssertTrue(bodies.allSatisfy { $0["withExif"] as? Bool == true })
            switch source {
            case .album:
                XCTAssertTrue(bodies.allSatisfy { $0["albumIds"] as? [String] == ["album"] })
                XCTAssertTrue(bodies.allSatisfy { $0["order"] as? String == "desc" })
                XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 1_000 })
                XCTAssertTrue(bodies.allSatisfy { $0["visibility"] == nil })
            case .metadata:
                XCTAssertTrue(bodies.allSatisfy { $0["personIds"] as? [String] == ["person"] })
                XCTAssertTrue(bodies.allSatisfy { $0["city"] as? String == "Lisbon" })
                XCTAssertTrue(bodies.allSatisfy { $0["visibility"] as? String == "archive" })
                XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 17 })
            }
        }
    }

    func testTerminalResponseWinsOverAStaleTotalWithoutAnotherRequest() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var requests = 0
            MockURLProtocol.responseProvider = { request in
                requests += 1
                return Self.response(request, ids: ["only"], next: nil, total: 99_000)
            }
            let assets = try await source.load(api: api, store: store)
            XCTAssertEqual(assets.map(\.id), ["only"])
            XCTAssertEqual(requests, 1, source.rawValue)
        }
    }

    func testEmptyTerminalPageIsAValidCompleteResult() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var pages: [Int] = []
            MockURLProtocol.responseProvider = { request in
                let page = Self.body(request)["page"] as? Int ?? 0
                pages.append(page)
                return Self.response(request, ids: page == 1 ? ["kept"] : [],
                    next: page == 1 ? "3" : nil, total: 20_000)
            }
            let assets = try await source.load(api: api, store: store)
            XCTAssertEqual(assets.map(\.id), ["kept"])
            XCTAssertEqual(pages, [1, 3])
        }
    }

    func testAuthoritativeEmptyFirstPageDoesNotUseCountsToInventMorePages() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var requests = 0
            MockURLProtocol.responseProvider = { request in
                requests += 1
                return Self.response(request, ids: [], next: nil, total: 50_000)
            }
            let assets = try await source.load(api: api, store: store)
            XCTAssertTrue(assets.isEmpty)
            XCTAssertEqual(requests, 1)
        }
    }

    func testDuplicatesWithinAndAcrossPagesAppearOnlyOnceInServerOrder() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var requests = 0
            MockURLProtocol.responseProvider = { request in
                requests += 1
                return Self.response(request,
                    ids: requests == 1 ? ["first", "first", "overlap"] : ["overlap", "last", "last"],
                    next: requests == 1 ? "2" : nil)
            }
            let assets = try await source.load(api: api, store: store)
            XCTAssertEqual(assets.map(\.id), ["first", "overlap", "last"])
            XCTAssertEqual(requests, 2)
        }
    }

    func testUniquePrivateOnlyPagesStillMakeProgressAndAlbumKeepsArchivedMembers() async throws {
        let api = try networkAPI()
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            let items: [[String: Any]]
            switch page {
            case 1: items = [Self.asset("locked", visibility: "locked")]
            case 4: items = [Self.asset("hidden", visibility: "hidden"), Self.asset("trashed", trashed: true)]
            default: items = [Self.asset("archived", visibility: "archive"), Self.asset("visible")]
            }
            return Self.response(request, items: items, next: page == 1 ? "4" : page == 4 ? "9" : nil)
        }

        let assets = try await TimelineRepository(api: api, dataManager: store).albumAssets("album")

        XCTAssertEqual(assets.map(\.id), ["archived", "visible"])
        XCTAssertEqual(pages, [1, 4, 9])
        XCTAssertEqual(store.privateAssetIDs, ["locked", "hidden"])
        XCTAssertEqual(store.archivedAssetIDs, ["archived"])
    }

    func testMalformedOrNonforwardContinuationIsRejectedBeforeAnotherRequest() async throws {
        for source in CollectionPageSource.allCases {
            for next in ["", "not-a-page", "0", "-1", "1", "1.5", String(repeating: "9", count: 30)] {
                let api = try networkAPI()
                var requests = 0
                MockURLProtocol.responseProvider = { request in
                    requests += 1
                    guard requests == 1 else { return (nil, nil, URLError(.unsupportedURL)) }
                    return Self.response(request, ids: ["first"], next: next)
                }
                await expectBadResponse { try await source.load(api: api, store: self.store) }
                XCTAssertEqual(requests, 1, "\(source.rawValue): \(next)")
            }
        }
    }

    func testBackwardContinuationOnALaterPageCannotBeFollowed() async throws {
        for source in CollectionPageSource.allCases {
            let api = try networkAPI()
            var pages: [Int] = []
            MockURLProtocol.responseProvider = { request in
                let page = Self.body(request)["page"] as? Int ?? 0
                pages.append(page)
                guard pages.count <= 2 else { return (nil, nil, URLError(.unsupportedURL)) }
                return Self.response(request, ids: ["asset-\(page)"], next: page == 1 ? "4" : "2")
            }
            await expectBadResponse { try await source.load(api: api, store: self.store) }
            XCTAssertEqual(pages, [1, 4])
        }
    }

    func testAdvertisedEmptyOrRepeatedPagesCannotSucceedAsPartialCollections() async throws {
        for source in CollectionPageSource.allCases {
            for scenario in ["empty", "repeat", "private-repeat"] {
                let api = try networkAPI()
                var requests = 0
                MockURLProtocol.responseProvider = { request in
                    requests += 1
                    guard requests <= 2 else { return (nil, nil, URLError(.unsupportedURL)) }
                    let items = scenario == "empty" ? [] : [Self.asset("same",
                        visibility: scenario == "private-repeat" ? "locked" : "timeline")]
                    return Self.response(request, items: items, next: String(requests + 1))
                }
                await expectBadResponse { try await source.load(api: api, store: self.store) }
                XCTAssertEqual(requests, scenario == "empty" ? 1 : 2,
                    "No-progress detection must use raw IDs even when the album filters them out")
            }
        }
    }

    func testLaterPageFailurePreservesTheAlbumsWorkingSnapshotAndAllowsRetry() async throws {
        let api = try networkAPI()
        let key = LocalSnapshot.Key.album("pagination-failure")
        addTeardownBlock { await LocalSnapshot.remove(key) }
        LocalSnapshot.save([AssetLite(makeTestAsset(id: "offline"))], for: key)
        let model = AlbumDetailViewModel(timelineRepo: TimelineRepository(api: api, dataManager: store),
            albumRepo: AlbumRepository(api: api), assetRepo: AssetDetailRepository(api: api), dataManager: store)
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            if page == 1 { return Self.response(request, ids: ["partial"], next: "3") }
            return (Data("unavailable".utf8), HTTPURLResponse(url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil), nil)
        }

        let loaded = await model.loadAlbumDetail("pagination-failure")

        XCTAssertFalse(loaded)
        XCTAssertEqual(pages, [1, 3])
        XCTAssertEqual(model.assets.map(\.id), ["offline"])
        XCTAssertNotNil(model.phase.value)
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["offline"])
        MockURLProtocol.responseProvider = { Self.response($0, ids: ["complete"], next: nil) }
        let retried = await model.loadAlbumDetail("pagination-failure")
        XCTAssertTrue(retried)
        XCTAssertEqual(model.assets.map(\.id), ["complete"])
        XCTAssertEqual(LocalSnapshot.load([AssetLite].self, for: key)?.map(\.id), ["complete"])
    }

    func testMetadataPaginationPreservesANondefaultStartingPage() async throws {
        let api = try networkAPI()
        var pages: [Int] = []
        MockURLProtocol.responseProvider = { request in
            let page = Self.body(request)["page"] as? Int ?? 0
            pages.append(page)
            return Self.response(request, ids: ["asset-\(page)"], next: page == 3 ? "7" : nil)
        }
        let assets = try await SearchRepository(api: api, dataManager: store)
            .allMetadata(SearchRequestDTO(page: 3, visibility: "archive"))
        XCTAssertEqual(assets.map(\.id), ["asset-3", "asset-7"])
        XCTAssertEqual(pages, [3, 7])
    }

    func testAlreadyCanceledAlbumQueryCannotStartTheTransport() async {
        let api = CanceledAlbumPageAPI()
        let repository = TimelineRepository(api: api, dataManager: store)
        let load = Task { try await repository.albumAssets("album") }
        load.cancel()
        do {
            _ = try await load.value
            XCTFail("A canceled query must not send a request")
        } catch is CancellationError {
        } catch { XCTFail("Expected cancellation, received \(error)") }
        XCTAssertEqual(api.requests, 0)
    }

    private func networkAPI() throws -> APIClient {
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://collection-pagination.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    private func expectBadResponse(_ load: () async throws -> [AssetLite],
        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await load()
            XCTFail("A broken continuation must not publish a partial collection", file: file, line: line)
        } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse, file: file, line: line) }
    }

    private nonisolated static func body(_ request: URLRequest) -> [String: Any] {
        let bytes = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }

    private nonisolated static func asset(_ id: String, visibility: String = "timeline", trashed: Bool = false) -> [String: Any] {
        ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
         "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
         "isFavorite": false, "isArchived": visibility == "archive", "visibility": visibility, "isTrashed": trashed]
    }

    private nonisolated static func response(_ request: URLRequest, ids: [String], next: String?, total: Int = 1)
        -> (Data?, HTTPURLResponse?, Error?) {
        response(request, items: ids.map { asset($0) }, next: next, total: total)
    }

    private nonisolated static func response(_ request: URLRequest, items: [[String: Any]], next: String?, total: Int = 1)
        -> (Data?, HTTPURLResponse?, Error?) {
        let bytes = try! JSONSerialization.data(withJSONObject: [
            "assets": ["items": items, "total": total, "nextPage": next as Any? ?? NSNull()],
        ])
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
    }
}

private enum CollectionPageSource: String, CaseIterable {
    case album, metadata

    @MainActor
    func load(api: APIClient, store: SwiftDataManager) async throws -> [AssetLite] {
        switch self {
        case .album: return try await TimelineRepository(api: api, dataManager: store).albumAssets("album")
        case .metadata:
            return try await SearchRepository(api: api, dataManager: store).allMetadata(
                SearchRequestDTO(city: "Lisbon", personIds: ["person"], size: 17, visibility: "archive"))
                .map(AssetLite.init)
        }
    }
}

private final class CanceledAlbumPageAPI: APIClient {
    private(set) var requests = 0

    @MainActor
    init() { super.init(session: MockSessionManager()) }

    override func send<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        requests += 1
        let response = SearchResponseDTO(assets: .init(items: [makeTestAsset(id: "canceled")], total: 1, nextPage: nil))
        return try XCTUnwrap(response as? T)
    }
}
