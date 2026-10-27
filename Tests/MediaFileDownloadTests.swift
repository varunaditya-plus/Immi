import XCTest
@testable import ImmichApp

@MainActor
final class MediaFileDownloadTests: XCTestCase {
    private var session: MockSessionManager!
    private var client: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        session = MockSessionManager()
        try session.setServer("https://media.example.com")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = APIClient(session: session, urlSession: URLSession(configuration: config))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        client = nil
        session = nil
        try await super.tearDown()
    }

    func testDownloadWritesOriginalBytesToAFileAndKeepsResponseMetadata() async throws {
        let bytes = Data(repeating: 0x35, count: 2 * 1024 * 1024 + 17)
        stub(status: 200, bytes: bytes, headers: [
            "Content-Type": "video/mp4",
            "Content-Disposition": "inline; filename*=UTF-8''Holiday%20clip.mp4",
        ])
        session.testAuthHeaders = ["x-api-key": "test-media-key"]

        let download = try await client.rawFile(.init(path: "/assets/movie/original"))
        defer { try? FileManager.default.removeItem(at: download.url) }

        XCTAssertTrue(download.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: download.url), bytes)
        XCTAssertEqual(download.response.mimeType, "video/mp4")
        XCTAssertEqual(download.response.suggestedFilename, "Holiday clip.mp4")
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/assets/movie/original")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-media-key")
    }

    func testDownloadPropagatesServerErrorInsteadOfReturningAnErrorDocumentAsMedia() async throws {
        stub(status: 403, bytes: Data(#"{"message":"Download denied"}"#.utf8))
        do {
            let download = try await client.rawFile(.init(path: "/assets/movie/original"))
            try? FileManager.default.removeItem(at: download.url)
            XCTFail("An HTTP error cannot be shared as a photo/video")
        } catch let error as APIError {
            guard case .server(let status, let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Download denied")
        }
    }

    func testCanceledDownloadDoesNotStartATransfer() async {
        let task = Task { try await client.rawFile(.init(path: "/assets/movie/original")) }
        task.cancel()
        do {
            let download = try await task.value
            try? FileManager.default.removeItem(at: download.url)
            XCTFail("Canceled download must not produce a file")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    private func stub(status: Int, bytes: Data, headers: [String: String] = [:]) {
        MockURLProtocol.mockData = bytes
        MockURLProtocol.mockResponse = HTTPURLResponse(
            url: URL(string: "https://media.example.com/api/assets/movie/original")!,
            statusCode: status, httpVersion: nil, headerFields: headers)
    }
}
