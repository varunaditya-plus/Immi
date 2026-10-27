import Foundation
import Network
import XCTest

final class ServerTransportPolicyTests: XCTestCase {
    func testBuiltNetworkingBundlesAllowHTTPWithoutConflictingATSOverrides() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundles = [
            Bundle.main,
            try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("SelfPhotosShareExtension.appex"))),
            try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("SelfPhotosUploadAction.appex"))),
        ]

        for bundle in bundles {
            let info = try infoDictionary(in: bundle)
            let policy = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
            XCTAssertEqual(policy["NSAllowsArbitraryLoads"] as? Bool, true, bundle.bundleURL.path)
            // Fine-grained keys would override this flag and block public HTTP hosts.
            XCTAssertEqual(Set(policy.keys), ["NSAllowsArbitraryLoads"], bundle.bundleURL.path)
        }
    }

    func testBuiltWidgetRetainsDefaultTransportPolicy() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("ImmichWidgets.appex")))

        XCTAssertNil(try infoDictionary(in: widget)["NSAppTransportSecurity"])
    }

    func testLocalNetworkPurposeIsPackagedForEverySupportedLanguage() throws {
        let info = try infoDictionary(in: .main)
        let purpose = try XCTUnwrap(info["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let languages = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertFalse(languages.isEmpty)

        for language in languages {
            let stringsURL = Bundle.main.bundleURL
                .appendingPathComponent("\(language).lproj/InfoPlist.strings")
            let strings = try propertyList(at: stringsURL)
            let localizedPurpose = try XCTUnwrap(
                strings["NSLocalNetworkUsageDescription"] as? String, language)
            XCTAssertFalse(
                localizedPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                language)
        }
    }

    func testConfiguredHTTPServerRespondsOverIPv4() async throws {
        try await assertHTTPResponse(host: "127.0.0.1", urlHost: "127.0.0.1")
    }

    func testConfiguredHTTPServerRespondsOverIPv6() async throws {
        try await assertHTTPResponse(host: "::1", urlHost: "[::1]")
    }

    private func assertHTTPResponse(host: String, urlHost: String) async throws {
        let ready = expectation(description: "Loopback HTTP listener is ready")
        let served = expectation(description: "Loopback HTTP response was sent")
        let body = Data("SelfPhotos HTTP response from \(host)".utf8) + Data([0, 255])
        let server = try LoopbackHTTPServer(host: host, body: body, ready: ready, served: served)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let url = try XCTUnwrap(URL(string: "http://\(urlHost):\(port)/api/server/ping"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // A URLProtocol stub would bypass the transport policy under test.
        let (data, response) = try await session.data(from: url)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 202)
        XCTAssertEqual(http.url, url)
        XCTAssertEqual(data, body)
        await fulfillment(of: [served], timeout: 5)
    }

    private func infoDictionary(in bundle: Bundle) throws -> [String: Any] {
        try propertyList(at: bundle.bundleURL.appendingPathComponent("Info.plist"))
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(value as? [String: Any], url.path)
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ServerTransportPolicyTests.HTTP")
    // These properties are confined to queue, including cleanup in stop().
    private var reportedStartup = false
    private var connections: [NWConnection] = []

    var port: UInt16? { listener.port?.rawValue }

    init(host: String, body: Data, ready: XCTestExpectation, served: XCTestExpectation) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
        let response = Data((
            "HTTP/1.1 202 Accepted\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Connection: close\r\n\r\n"
        ).utf8) + body

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.reportedStartup else { return }
            switch state {
            case .ready:
                self.reportedStartup = true
                ready.fulfill()
            case .failed(let error):
                self.reportedStartup = true
                XCTFail("Loopback listener failed: \(error)")
                ready.fulfill()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                data, _, _, error in
                guard error == nil, let data, !data.isEmpty else {
                    connection.cancel()
                    return
                }
                connection.send(content: response, completion: .contentProcessed { error in
                    if let error { XCTFail("Loopback response failed: \(error)") }
                    else { served.fulfill() }
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
