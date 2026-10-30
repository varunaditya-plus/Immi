import XCTest
@testable import ImmichApp

@MainActor
final class AlbumPresentationContractTests: XCTestCase {
    private var api: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        let session = MockSessionManager()
        try session.setServer("https://test.example.com")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = APIClient(session: session, urlSession: URLSession(configuration: configuration))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testKeyPhotoPatchDoesNotOverwriteAlbumNameDescriptionOrMembers() async throws {
        stub(status: 200, json: "{}")
        try await AlbumRepository(api: api).setKeyPhoto("chosen-photo", for: "album")

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/albums/album")
        let body = try body(request)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["albumThumbnailAssetId"] as? String, "chosen-photo")
    }

    func testActivityReadIsScopedToTheRequestedAlbum() async throws {
        stub(status: 200, json: "[\(activityJSON)]")
        let result = try await AlbumActivityRepository(api: api).all(in: "shared-album")

        XCTAssertEqual(result.map(\.id), ["activity"])
        XCTAssertEqual(result.first?.comment, "A real comment")
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/activities")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "albumId" })?.value, "shared-album")
    }

    func testCommentsLikesAndDeletionUseTheirActualServerContracts() async throws {
        let repository = AlbumActivityRepository(api: api)
        stub(status: 201, json: activityJSON)
        _ = try await repository.comment("Preserve this text", in: "album")
        var request = try XCTUnwrap(MockURLProtocol.lastRequest)
        var payload = try body(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(payload["albumId"] as? String, "album")
        XCTAssertEqual(payload["type"] as? String, "comment")
        XCTAssertEqual(payload["comment"] as? String, "Preserve this text")
        XCTAssertNil(payload["assetId"])

        _ = try await repository.like("album")
        request = try XCTUnwrap(MockURLProtocol.lastRequest)
        payload = try body(request)
        XCTAssertEqual(payload["type"] as? String, "like")
        XCTAssertNil(payload["comment"])

        stub(status: 204, json: "")
        try await repository.delete("activity")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/activities/activity")
    }

    func testRejectedKeyPhotoMutationIsReportedAsAnError() async {
        stub(status: 403, json: "{\"message\":\"Not allowed\"}")
        do {
            try await AlbumRepository(api: api).setKeyPhoto("photo", for: "album")
            XCTFail("A rejected key-photo patch must not appear to save")
        } catch {
            guard case APIError.server(let status, _) = error else { return XCTFail("Expected the server rejection") }
            XCTAssertEqual(status, 403)
        }
    }

    private var activityJSON: String {
        """
        {"id":"activity","assetId":null,"comment":"A real comment","createdAt":"2026-10-29T10:00:00Z","type":"comment",
         "user":{"id":"user","name":"Person","email":"user@example.test"}}
        """
    }

    private func stub(status: Int, json: String) {
        MockURLProtocol.mockData = Data(json.utf8)
        MockURLProtocol.mockResponse = HTTPURLResponse(url: URL(string: "https://test.example.com/api")!,
            statusCode: status, httpVersion: nil, headerFields: nil)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? MockURLProtocol.lastRequestBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
