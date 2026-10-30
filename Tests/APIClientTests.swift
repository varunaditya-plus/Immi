import XCTest
@testable import ImmichApp

@MainActor
final class APIClientTests: XCTestCase {
    var mockSession: MockSessionManager!
    var apiClient: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()

        mockSession = MockSessionManager()
        try mockSession.setServer("https://test.example.com")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        apiClient = APIClient(session: mockSession, urlSession: URLSession(configuration: config))
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func stub(status: Int, data: Data) {
        MockURLProtocol.mockData = data
        MockURLProtocol.mockResponse = HTTPURLResponse(
            url: URL(string: "https://test.example.com/api")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )
    }

    func testTransportFailuresKeepTheirCauseAcrossDataFileAndStreamRequests() async throws {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, expected("No internet connection.", "Aucune connexion Internet.")),
            (.cannotConnectToHost, expected("Couldn't reach that server.", "Impossible de joindre ce serveur.")),
            (.cannotFindHost, expected("Couldn't reach that server.", "Impossible de joindre ce serveur.")),
            (.dnsLookupFailed, expected("Couldn't reach that server.", "Impossible de joindre ce serveur.")),
            (.timedOut, expected("The server took too long to respond. Try again.",
                "Le serveur a mis trop de temps à répondre. Réessayez.")),
            (.networkConnectionLost, expected("The connection to the server was lost. Try again.",
                "La connexion au serveur a été interrompue. Réessayez.")),
            (.dataNotAllowed, expected("Network access is restricted. Check your connection settings.",
                "L'accès au réseau est restreint. Vérifiez vos réglages de connexion.")),
            (.internationalRoamingOff, expected("Network access is restricted. Check your connection settings.",
                "L'accès au réseau est restreint. Vérifiez vos réglages de connexion."))
        ]
        for kind in ["data", "file", "stream"] {
            for (code, message) in cases {
                MockURLProtocol.mockError = URLError(code)
                do {
                    try await request(kind)
                    XCTFail("\(kind) must report \(code)")
                } catch let error as APIError {
                    if code == .notConnectedToInternet {
                        guard case .notConnected = error else { return XCTFail("Expected offline error: \(error)") }
                    } else {
                        guard case .connectionFailed(let underlying) = error else {
                            return XCTFail("Expected server connection error for \(code): \(error)")
                        }
                        XCTAssertEqual(underlying.code, code)
                    }
                    XCTAssertEqual(error.localizedDescription, message, "\(kind): \(code)")
                    XCTAssertEqual(BackupUploadFailureDisposition.classify(error), .retryNetwork)
                    XCTAssertFalse(error.meansAssetIsUnreadable)
                } catch {
                    XCTFail("Unexpected \(kind) error for \(code): \(error)")
                }
            }
        }
    }

    func testCancellationAndUnclassifiedTransportErrorsAreNotRelabeledOffline() async {
        for kind in ["data", "file", "stream"] {
            for code: URLError.Code in [.cancelled, .badServerResponse, .serverCertificateUntrusted] {
                MockURLProtocol.mockError = URLError(code)
                do {
                    try await request(kind)
                    XCTFail("The injected transport error must fail")
                } catch let error as URLError {
                    XCTAssertEqual(error.code, code)
                } catch {
                    XCTFail("\(kind) changed \(code) to \(error)")
                }
            }
        }
    }

    private func request(_ kind: String) async throws {
        let endpoint = Endpoint(path: "/server/ping")
        switch kind {
        case "data": _ = try await apiClient.rawData(endpoint)
        case "file": _ = try await apiClient.rawFile(endpoint)
        case "stream": _ = try await apiClient.streamLines(endpoint)
        default: preconditionFailure("Unknown test transport")
        }
    }

    private func expected(_ english: String, _ french: String) -> String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? french : english
    }

    func testPingSuccess() async throws {
        stub(status: 200, data: #"{"res":"pong"}"#.data(using: .utf8)!)

        let result: ServerPingDTO = try await apiClient.send(.init(path: "/server/ping"))
        XCTAssertEqual(result.res, "pong")
    }

    func testUnauthorizedError() async throws {
        stub(status: 401, data: Data())

        do {
            let _: LoginResponseDTO = try await apiClient.send(.init(path: "/auth/login", method: .post))
            XCTFail("Should throw unauthorized")
        } catch let error as APIError {
            if case .unauthorized = error {
                // Success
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testServerError() async throws {
        stub(status: 400, data: #"{"message":"Invalid credentials"}"#.data(using: .utf8)!)

        do {
            let _: LoginResponseDTO = try await apiClient.send(.init(path: "/auth/login", method: .post))
            XCTFail("Should throw server error")
        } catch let error as APIError {
            if case .server(let status, let msg) = error {
                XCTAssertEqual(status, 400)
                XCTAssertEqual(msg, "Invalid credentials")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testDecodingError() async throws {
        stub(status: 200, data: #"{"invalid":"json""#.data(using: .utf8)!)

        do {
            let _: ServerPingDTO = try await apiClient.send(.init(path: "/server/ping"))
            XCTFail("Should throw decoding error")
        } catch let error as APIError {
            if case .decoding = error {
                // Success
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testRawDataSuccess() async throws {
        let expectedData = Data([1, 2, 3, 4, 5])
        stub(status: 200, data: expectedData)

        let result = try await apiClient.rawData(.init(path: "/assets/123/thumbnail"))
        XCTAssertEqual(result, expectedData)
    }

    func testAuthHeadersAttached() async throws {
        mockSession.testAuthHeaders = ["Authorization": "Bearer test-token"]
        stub(status: 200, data: #"{"res":"pong"}"#.data(using: .utf8)!)

        let _: ServerPingDTO = try await apiClient.send(.init(path: "/server/ping"))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testRequestURLBuiltFromBase() async throws {
        stub(status: 200, data: #"{"res":"pong"}"#.data(using: .utf8)!)

        let _: ServerPingDTO = try await apiClient.send(.init(
            path: "/server/ping",
            query: [URLQueryItem(name: "foo", value: "bar")]))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://test.example.com/api/server/ping"))
        XCTAssertTrue(url.query?.contains("foo=bar") ?? false)
    }

    func testMissingBaseURLThrowsInvalidURL() async throws {
        let session = MockSessionManager() // no setServer -> baseURL nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(session: session, urlSession: URLSession(configuration: config))

        do {
            let _: ServerPingDTO = try await client.send(.init(path: "/server/ping"))
            XCTFail("Should throw invalidURL")
        } catch let error as APIError {
            if case .invalidURL = error {
                // Success
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}

final class MockURLProtocol: URLProtocol {
    typealias ResponseProvider = (URLRequest) -> (Data?, URLResponse?, Error?)

    static var mockData: Data?
    static var mockResponse: URLResponse?
    static var mockError: Error?
    static var responseProvider: ResponseProvider?
    static var lastRequest: URLRequest?
    static var lastRequestBody: Data?

    static func reset() {
        mockData = nil
        mockResponse = nil
        mockError = nil
        responseProvider = nil
        lastRequest = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)

        if let responseProvider = Self.responseProvider {
            let (data, response, error) = responseProvider(request)
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if let error = Self.mockError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let response = Self.mockResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        if let data = Self.mockData {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession memindahkan `httpBody` ke stream sebelum menyerahkannya ke
    /// URLProtocol. Simpan byte-nya agar contract test bisa memeriksa JSON yang
    /// benar-benar dikirim, bukan request sebelum transport memprosesnya.
    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
