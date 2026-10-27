import XCTest
@testable import ImmichApp

@MainActor
final class AlbumMutationResultTests: XCTestCase {
    private var session: MockSessionManager!
    private var repository: AlbumRepository!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        session = MockSessionManager()
        try session.setServer("https://test.example.com")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        repository = AlbumRepository(api: APIClient(
            session: session, urlSession: URLSession(configuration: config)))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        repository = nil
        session = nil
        try await super.tearDown()
    }

    func testAddReturnsOnlyRequestedDuplicatesInRequestOrder() async throws {
        stub("""
        [{"id":"b","success":false,"error":"duplicate"},
         {"id":"a","success":true},
         {"id":"c","success":false,"error":"duplicate"},
         {"id":"unrequested","success":false,"error":"duplicate"}]
        """)

        let duplicates = try await repository.addAssets(["c", "a", "b", "c"], to: "album")

        XCTAssertEqual(duplicates, ["c", "b"])
        try assertRequest(method: "PUT", ids: ["c", "a", "b", "c"])
    }

    func testMixedAddFailureCarriesConfirmedSuccessesAndDuplicates() async throws {
        stub("""
        [{"id":"added","success":true},
         {"id":"existing","success":false,"error":"duplicate"},
         {"id":"denied","success":false,"error":"no_permission"}]
        """)
        do {
            try await repository.addAssets(["added", "existing", "denied"], to: "album")
            XCTFail("A 200 response containing a rejected item must not report complete success")
        } catch let error as AlbumMutationError {
            XCTAssertEqual(error.succeededIDs, ["added"])
            XCTAssertEqual(error.duplicateIDs, ["existing"])
            XCTAssertEqual(error.failedIDs, ["denied"])
        }
    }

    func testRemoveDecodesPerItemFailuresInsteadOfTrustingHTTP200() async throws {
        stub("""
        [{"id":"removed","success":true},
         {"id":"denied","success":false,"error":"no_permission"}]
        """)
        do {
            try await repository.removeAssets(["removed", "denied"], from: "album")
            XCTFail("Rejected removals must stay visible")
        } catch let error as AlbumMutationError {
            XCTAssertEqual(error.succeededIDs, ["removed"])
            XCTAssertTrue(error.duplicateIDs.isEmpty)
            XCTAssertEqual(error.failedIDs, ["denied"])
        }
        try assertRequest(method: "DELETE", ids: ["removed", "denied"])
    }

    func testOmittedResultsAreFailuresForBothOperations() async throws {
        for isRemoval in [false, true] {
            stub("""
            [{"id":"confirmed","success":true},{"id":"other","success":true}]
            """)
            do {
                if isRemoval {
                    try await repository.removeAssets(["confirmed", "missing"], from: "album")
                } else {
                    try await repository.addAssets(["confirmed", "missing"], to: "album")
                }
                XCTFail("An unrelated result cannot confirm a missing requested item")
            } catch let error as AlbumMutationError {
                XCTAssertEqual(error.succeededIDs, ["confirmed"])
                XCTAssertEqual(error.failedIDs, ["missing"])
                XCTAssertTrue(error.duplicateIDs.isEmpty)
            }
        }
    }

    func testEmptyResponseDoesNotConfirmAnyRequestedItem() async throws {
        for isRemoval in [false, true] {
            stub("[]")
            do {
                if isRemoval {
                    try await repository.removeAssets(["a", "b"], from: "album")
                } else {
                    try await repository.addAssets(["a", "b"], to: "album")
                }
                XCTFail("An empty response does not establish success")
            } catch let error as AlbumMutationError {
                XCTAssertTrue(error.succeededIDs.isEmpty)
                XCTAssertEqual(error.failedIDs, ["a", "b"])
            }
        }
    }

    func testConflictingResultsNeverConfirmTheAffectedID() async throws {
        for isRemoval in [false, true] {
            stub("""
            [{"id":"a","success":true},
             {"id":"a","success":false,"error":"no_permission"},
             {"id":"b","success":true}]
            """)
            do {
                if isRemoval {
                    try await repository.removeAssets(["a", "b"], from: "album")
                } else {
                    try await repository.addAssets(["a", "b"], to: "album")
                }
                XCTFail("Contradictory results cannot be treated as confirmed success")
            } catch let error as AlbumMutationError {
                XCTAssertEqual(error.succeededIDs, ["b"])
                XCTAssertEqual(error.failedIDs, ["a"])
            }
        }
    }

    func testDuplicateIsNotASuccessfulRemoval() async throws {
        stub(#"[{"id":"a","success":false,"error":"duplicate"}]"#)
        do {
            try await repository.removeAssets(["a"], from: "album")
            XCTFail("Duplicate is only an accepted add outcome")
        } catch let error as AlbumMutationError {
            XCTAssertTrue(error.succeededIDs.isEmpty)
            XCTAssertTrue(error.duplicateIDs.isEmpty)
            XCTAssertEqual(error.failedIDs, ["a"])
        }
    }

    func testAllConfirmedOperationsSucceed() async throws {
        stub(#"[{"id":"b","success":true},{"id":"a","success":true}]"#)
        let duplicates = try await repository.addAssets(["a", "b"], to: "album")
        XCTAssertTrue(duplicates.isEmpty)
        try await repository.removeAssets(["a", "b"], from: "album")
    }

    func testEmptyInputDoesNotSendAMutation() async throws {
        let duplicates = try await repository.addAssets([], to: "album")
        try await repository.removeAssets([], from: "album")
        XCTAssertTrue(duplicates.isEmpty)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testMalformedRemoveResponseThrowsInsteadOfReportingSuccess() async throws {
        stub(#"{"unexpected":true}"#)
        do {
            try await repository.removeAssets(["a"], from: "album")
            XCTFail("The server response must be decodable before local removal")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func stub(_ json: String) {
        MockURLProtocol.mockData = Data(json.utf8)
        MockURLProtocol.mockResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com/api/albums/album/assets")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)
    }

    private func assertRequest(method: String, ids: [String]) throws {
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, method)
        XCTAssertEqual(request.url?.path, "/api/albums/album/assets")
        let body = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["ids"] as? [String], ids)
    }
}
