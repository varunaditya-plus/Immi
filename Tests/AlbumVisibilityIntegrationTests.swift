import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class AlbumVisibilityIntegrationTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testAlbumPagesKeepArchivedMembersAndExcludePrivateOrTrashedAssets() async throws {
        let api = try networkAPI()
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let body = self.body(request)
            bodies.append(body)
            let firstPage = body["page"] as? Int == 1
            let items = firstPage
                ? [self.asset("visible"), self.asset("archived", visibility: "archive", archived: true),
                   self.asset("hidden", visibility: "hidden")]
                : [self.asset("locked", visibility: "locked"), self.asset("trashed", trashed: true),
                   self.asset("legacy-archived", visibility: nil, archived: true)]
            return self.response(request, items: items, nextPage: firstPage ? "2" : nil)
        }

        let assets = try await TimelineRepository(api: api).albumAssets("album")

        XCTAssertEqual(assets.map(\.id), ["visible", "archived", "legacy-archived"])
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 2])
        XCTAssertTrue(bodies.allSatisfy { $0["visibility"] == nil })
        XCTAssertTrue(bodies.allSatisfy { $0["albumIds"] as? [String] == ["album"] })
    }

    func testAlbumCoverSearchContinuesPastPrivateOnlyPagesAndAllowsArchive() async throws {
        let repository = AlbumRepository(api: try networkAPI())
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let body = self.body(request)
            bodies.append(body)
            let firstPage = body["page"] as? Int == 1
            let items = firstPage
                ? [self.asset("hidden", visibility: "hidden"), self.asset("locked", visibility: "locked"),
                   self.asset("trashed", trashed: true)]
                : [self.asset("archived", visibility: "archive", archived: true), self.asset("visible")]
            return self.response(request, items: items, nextPage: firstPage ? "3" : nil)
        }

        let ids = try await repository.recentAssetIDs(in: "album", limit: 2)

        XCTAssertEqual(ids, ["archived", "visible"])
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 3])
        XCTAssertTrue(bodies.allSatisfy { $0["visibility"] == nil })
    }

    func testWidgetAlbumSearchRequestsTimelineAndRejectsPrivateResponseItems() async throws {
        let repository = AlbumRepository(api: try networkAPI())
        var bodies: [[String: Any]] = []
        MockURLProtocol.responseProvider = { request in
            let body = self.body(request)
            bodies.append(body)
            let firstPage = body["page"] as? Int == 1
            let items = firstPage
                ? [self.asset("archived", visibility: "archive", archived: true),
                   self.asset("legacy-archived", visibility: nil, archived: true),
                   self.asset("hidden", visibility: "hidden"), self.asset("locked", visibility: "locked"),
                   self.asset("trashed", trashed: true)]
                : [self.asset("visible")]
            return self.response(request, items: items, nextPage: firstPage ? "2" : nil)
        }

        let ids = await WidgetSnapshotExporter.albumAssetIDs(
            for: ["album", WidgetSnapshotExporter.favoritesID], repository: repository)

        XCTAssertEqual(ids, ["album": ["visible"]])
        XCTAssertEqual(bodies.compactMap { $0["page"] as? Int }, [1, 2])
        XCTAssertTrue(bodies.allSatisfy { $0["visibility"] as? String == "timeline" })
        XCTAssertTrue(bodies.allSatisfy { $0["albumIds"] as? [String] == ["album"] })
    }

    func testRepeatingPrivatePagesAreRejectedInsteadOfLooping() async throws {
        let repository = AlbumRepository(api: try networkAPI())
        var requests = 0
        MockURLProtocol.responseProvider = { request in
            requests += 1
            guard requests <= 2 else { return (nil, nil, URLError(.timedOut)) }
            return self.response(request, items: [self.asset("hidden", visibility: "hidden")],
                nextPage: String(requests + 1))
        }

        do {
            _ = try await repository.recentAssetIDs(in: "album", limit: 1)
            XCTFail("Repeating IDs cannot make pagination progress, even when they are filtered out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
        XCTAssertEqual(requests, 2)
    }

    private func networkAPI() throws -> APIClient {
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://album-visibility.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    private nonisolated func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? MockURLProtocol.lastRequestBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private nonisolated func asset(
        _ id: String, visibility: String? = "timeline", archived: Bool = false, trashed: Bool = false
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "type": "IMAGE", "originalFileName": "\(id).jpg",
            "fileCreatedAt": "2026-10-01T00:00:00.000Z", "localDateTime": "2026-10-01T00:00:00.000Z",
            "isFavorite": false, "isArchived": archived, "isTrashed": trashed,
        ]
        item["visibility"] = visibility
        return item
    }

    private nonisolated func response(
        _ request: URLRequest, items: [[String: Any]], nextPage: String?
    ) -> (Data?, HTTPURLResponse?, Error?) {
        let data = try! JSONSerialization.data(withJSONObject: [
            "assets": ["items": items, "total": 6, "nextPage": nextPage as Any? ?? NSNull()],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        return (data, response, nil)
    }
}
