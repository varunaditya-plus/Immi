import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumMediaRetrievalTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testRecentAlbumIDsUseBoundedNewestFirstMetadataSearch() async throws {
        let repository = try networkRepository()
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (self.responseData(ids: (0..<12).map { "asset-\($0)" }, nextPage: "2"), response, nil)
        }

        for limit in [1, 8] {
            let ids = try await repository.recentAssetIDs(in: "selected-album", limit: limit)

            XCTAssertEqual(ids, (0..<limit).map { "asset-\($0)" })
            let request = try XCTUnwrap(MockURLProtocol.lastRequest)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/search/metadata")
            let body = try requestBody()
            XCTAssertEqual(body["albumIds"] as? [String], ["selected-album"])
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertEqual(body["page"] as? Int, 1)
            XCTAssertEqual(body["size"] as? Int, limit)
            XCTAssertEqual(body["withExif"] as? Bool, false)
        }
        XCTAssertEqual(requests, 2, "A cover or widget needs its bounded first page, not the full album")
    }

    func testAlbumPreviewFollowsCappedPagesDeduplicatesAndStopsAtItsLimit() async throws {
        let repository = try networkRepository()
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let data = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            bodies.append(body)
            let first = body["page"] as? Int == 1
            let ids = first ? ["newest", "overlap"] : ["overlap", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (self.responseData(ids: ids, nextPage: first ? "3" : "4"), response, nil)
        }

        let ids = try await repository.recentAssetIDs(in: "capped", limit: 8)

        XCTAssertEqual(ids, ["newest", "overlap", "third", "fourth", "fifth", "sixth", "seventh", "eighth"])
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 3])
        XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 8 })
        XCTAssertTrue(bodies.allSatisfy { $0["albumIds"] as? [String] == ["capped"] && $0["order"] as? String == "desc" })
    }

    func testAlbumPreviewStopsAtAnActualEndBeforeItsLimit() async throws {
        let repository = try networkRepository()
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (self.responseData(ids: ["one", "two"], nextPage: nil), response, nil)
        }

        let ids = try await repository.recentAssetIDs(in: "small", limit: 8)

        XCTAssertEqual(ids, ["one", "two"])
        XCTAssertEqual(requests, 1)
    }

    func testAlbumPreviewRejectsAdvertisedContinuationWithoutProgress() async throws {
        for scenario in ["empty", "repeat", "backward", "invalid"] {
            let repository = try networkRepository()
            var requests = 0
            MockURLProtocol.responseProvider = { request in
                requests += 1
                if requests > 2 { return (nil, nil, URLError(.badServerResponse)) }
                let ids = scenario == "empty" ? [] : ["same-item"]
                let next = scenario == "backward" ? "1" : scenario == "invalid" ? "invalid-page" : String(requests + 1)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
                return (self.responseData(ids: ids, nextPage: next), response, nil)
            }

            do {
                _ = try await repository.recentAssetIDs(in: "broken", limit: 8)
                XCTFail("An advertised \(scenario) continuation must not become a cached empty or partial preview")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
            }
            XCTAssertEqual(requests, scenario == "repeat" ? 2 : 1)
        }
    }

    func testV3AlbumWithoutEmbeddedAssetsResolvesAndCachesItsCover() async throws {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        repository.fetch = { _, _ in ["newest"] }
        let data = Data("""
        {"id":"11111111-1111-4111-8111-111111111111","albumName":"V3 album",
         "assetCount":40,"shared":false,"createdAt":"2026-08-08T01:00:00.000Z"}
        """.utf8)
        let album = try JSONDecoder.immich.decode(AlbumResponseDTO.self, from: data)

        await store.resolveCover(for: album, repository: repository)
        await store.resolveCover(for: album, repository: repository)

        XCTAssertEqual(store.coverID(for: album), "newest")
        XCTAssertEqual(repository.requests, [.init(albumID: album.id, limit: 1)])
    }

    func testExplicitCoverAndKnownEmptyAlbumAvoidSearchRequests() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let explicit = album(id: "explicit", count: 100, cover: "chosen-cover")
        let empty = album(id: "empty", count: 0)

        await store.resolveCover(for: explicit, repository: repository)
        await store.resolveCover(for: empty, repository: repository)

        XCTAssertEqual(store.coverID(for: explicit), "chosen-cover")
        XCTAssertNil(store.coverID(for: empty))
        XCTAssertTrue(repository.requests.isEmpty)
    }

    func testEmptySearchResultIsRememberedWithoutRepeatedRequests() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let album = album(count: 10)

        await store.resolveCover(for: album, repository: repository)
        await store.resolveCover(for: album, repository: repository)

        XCTAssertNil(store.coverID(for: album))
        XCTAssertEqual(repository.requests.count, 1)
    }

    func testEmptyAlbumAndEmptySearchAreResolvedAgainAfterTheCountChanges() async {
        for originalCount in [0, 10] {
            let store = AlbumCoverStore()
            let repository = ControlledAlbumMediaRepository()
            let original = album(count: originalCount)
            await store.resolveCover(for: original, repository: repository)
            XCTAssertNil(store.coverID(for: original))
            XCTAssertEqual(repository.requests.count, originalCount == 0 ? 0 : 1)
            repository.fetch = { _, _ in ["added-photo"] }
            let populated = album(count: originalCount + 1)

            await store.resolveCover(for: populated, repository: repository)

            XCTAssertEqual(store.coverID(for: populated), "added-photo")
            XCTAssertEqual(repository.requests.count, originalCount == 0 ? 1 : 2)
        }
    }

    func testCachedCoverIsRefetchedWhenItsAlbumCountChanges() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        repository.fetch = { _, _ in ["previous-cover"] }
        let previous = album(count: 10)
        await store.resolveCover(for: previous, repository: repository)
        XCTAssertEqual(store.coverID(for: previous), "previous-cover")
        let changed = album(count: 11)
        XCTAssertNil(store.coverID(for: changed), "The old fallback belongs to a different album count")
        repository.fetch = { _, _ in ["updated-cover"] }

        await store.resolveCover(for: changed, repository: repository)

        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertEqual(store.coverID(for: changed), "updated-cover")
    }

    func testFailedSearchDoesNotPermanentlyCacheAnEmptyCover() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        var attempt = 0
        repository.fetch = { _, _ in
            attempt += 1
            if attempt == 1 { throw URLError(.notConnectedToInternet) }
            return ["recovered-cover"]
        }
        let album = album(count: 10)

        await store.resolveCover(for: album, repository: repository)
        XCTAssertNil(store.coverID(for: album))
        await store.resolveCover(for: album, repository: repository)

        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertEqual(store.coverID(for: album), "recovered-cover")
    }

    func testConcurrentCoverRequestsShareTheSameSearch() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let held = HeldAlbumMedia()
        var attempt = 0
        repository.fetch = { _, _ in
            attempt += 1
            return attempt == 1 ? try await held.value() : ["duplicate-request"]
        }
        let album = album(count: 10)
        let first = Task { await store.resolveCover(for: album, repository: repository) }
        defer { first.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        let secondStarted = expectation(description: "The second card is resolving the same album")
        let second = Task {
            secondStarted.fulfill()
            await store.resolveCover(for: album, repository: repository)
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        held.finish(["shared-cover"])
        await first.value
        await second.value

        XCTAssertEqual(repository.requests.count, 1)
        XCTAssertEqual(store.coverID(for: album), "shared-cover")
    }

    func testInvalidatingAHeldRequestDoesNotReplaceItsNewCover() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let held = HeldAlbumMedia()
        var attempt = 0
        repository.fetch = { _, _ in
            attempt += 1
            return attempt == 1 ? try await held.value() : ["fresh-cover"]
        }
        let album = album(count: 10)
        let stale = Task { await store.resolveCover(for: album, repository: repository) }
        defer { stale.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)

        store.invalidate(album.id)
        let refreshed = expectation(description: "The invalidated cover resolves without the old request")
        let replacement = Task {
            await store.resolveCover(for: album, repository: repository)
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(store.coverID(for: album), "fresh-cover")
        held.finish(["stale-cover"])
        await stale.value
        await replacement.value

        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertEqual(store.coverID(for: album), "fresh-cover")
    }

    func testCountChangeReplacesAHeldSearchWithoutPublishingItsStaleResult() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let held = HeldAlbumMedia()
        var attempt = 0
        repository.fetch = { _, _ in
            attempt += 1
            return attempt == 1 ? try await held.value() : ["updated-cover"]
        }
        let previous = album(count: 10)
        let stale = Task { await store.resolveCover(for: previous, repository: repository) }
        defer { stale.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        let changed = album(count: 11)

        let refreshed = expectation(description: "A changed count starts a fresh cover request")
        let replacement = Task {
            await store.resolveCover(for: changed, repository: repository)
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(store.coverID(for: changed), "updated-cover")
        held.finish(["stale-cover"])
        await stale.value
        await replacement.value

        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertEqual(store.coverID(for: changed), "updated-cover")
    }

    func testClearingAHeldRequestDoesNotRestoreThePreviousGeneration() async {
        let store = AlbumCoverStore()
        let repository = ControlledAlbumMediaRepository()
        let held = HeldAlbumMedia()
        var attempt = 0
        repository.fetch = { _, _ in
            attempt += 1
            return attempt == 1 ? try await held.value() : ["current-cover"]
        }
        let album = album(count: 10)
        let stale = Task { await store.resolveCover(for: album, repository: repository) }
        defer { stale.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)

        store.clear()
        let refreshed = expectation(description: "The cleared cover resolves without the old generation")
        let replacement = Task {
            await store.resolveCover(for: album, repository: repository)
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 2)
        held.finish(["previous-cover"])
        await stale.value
        await replacement.value

        XCTAssertEqual(repository.requests.count, 2)
        XCTAssertEqual(store.coverID(for: album), "current-cover")
    }

    func testWidgetsFetchEightAssetsOnlyForSelectedAlbumsAndSkipFavorites() async throws {
        let repository = try networkRepository()
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let data = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            bodies.append(body)
            let albumID = (body["albumIds"] as? [String])?.first ?? "missing"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (self.responseData(ids: (0..<12).map { "\(albumID)-\($0)" }, nextPage: "2"), response, nil)
        }

        let ids = await WidgetSnapshotExporter.albumAssetIDs(
            for: ["one", "two", WidgetSnapshotExporter.favoritesID], repository: repository)

        XCTAssertEqual(ids, ["one": (0..<8).map { "one-\($0)" }, "two": (0..<8).map { "two-\($0)" }])
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(Set(bodies.compactMap { ($0["albumIds"] as? [String])?.first }), ["one", "two"])
        XCTAssertTrue(bodies.allSatisfy { $0["size"] as? Int == 8 && $0["order"] as? String == "desc" })
    }

    func testOneWidgetAlbumFailureDoesNotDiscardAnotherAlbumsImages() async {
        let repository = ControlledAlbumMediaRepository()
        repository.fetch = { albumID, _ in
            if albumID == "offline" { throw URLError(.timedOut) }
            return ["available-image"]
        }

        let ids = await WidgetSnapshotExporter.albumAssetIDs(
            for: ["offline", "available"], repository: repository)

        XCTAssertEqual(ids, ["available": ["available-image"]])
        XCTAssertEqual(Set(repository.requests.map(\.albumID)), ["offline", "available"])
        XCTAssertTrue(repository.requests.allSatisfy { $0.limit == 8 })
    }

    private func album(id: String = "album", count: Int, cover: String? = nil) -> AlbumResponseDTO {
        AlbumResponseDTO(id: id, albumName: id, description: nil, assetCount: count,
            albumThumbnailAssetId: cover, shared: false, createdAt: .distantPast, assets: nil)
    }

    private func networkRepository() throws -> AlbumRepository {
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://album-retrieval.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return AlbumRepository(api: APIClient(session: session, urlSession: URLSession(configuration: configuration)))
    }

    private func requestBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated func responseData(ids: [String], nextPage: String?) -> Data {
        let items = ids.map { id in
            ["id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
             "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
             "isFavorite": false, "isArchived": false, "isTrashed": false] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "assets": ["items": items, "total": 10_000, "nextPage": nextPage as Any? ?? NSNull()]
        ])
    }
}

@MainActor
private final class ControlledAlbumMediaRepository: AlbumRepository {
    struct Request: Equatable {
        let albumID: String
        let limit: Int
    }
    private(set) var requests: [Request] = []
    var fetch: (String, Int) async throws -> [String] = { _, _ in [] }

    init() { super.init(api: APIClient(session: SessionManager())) }

    override func recentAssetIDs(in albumID: String, limit: Int) async throws -> [String] {
        requests.append(Request(albumID: albumID, limit: limit))
        return try await fetch(albumID, limit)
    }
}

@MainActor
private final class HeldAlbumMedia {
    let started = XCTestExpectation(description: "The production cover store is awaiting an album search")
    private var continuation: CheckedContinuation<[String], Error>?
    private var cancelled = false

    func value() async throws -> [String] {
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(_ ids: [String]) {
        guard let continuation else { return XCTFail("The album search did not reach its held boundary") }
        self.continuation = nil
        continuation.resume(returning: ids)
    }

    func cancelIfWaiting() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
