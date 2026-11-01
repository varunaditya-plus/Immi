import Synchronization
import XCTest
@testable import ImmichApp

@MainActor
final class NetworkFailureLifecycleTests: XCTestCase {
    func testAPreviousServerFailureIsCancelledBeforeItCanPublishFeedback() async throws {
        for kind in ["data", "file", "stream"] {
            let probe = HeldConnectionFailureProbe(started: expectation(description: "\(kind) started"))
            HeldConnectionFailureProtocol.probe = probe
            defer { HeldConnectionFailureProtocol.probe = nil }
            let session = MockSessionManager()
            try session.setServer("https://previous-feedback.example")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeldConnectionFailureProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let api = APIClient(session: session, urlSession: transport)
            let request = Task {
                let endpoint = Endpoint(path: "/server/ping")
                switch kind {
                case "data": _ = try await api.rawData(endpoint)
                case "file": _ = try await api.rawFile(endpoint)
                default: _ = try await api.streamLines(endpoint)
                }
            }
            await fulfillment(of: [probe.started], timeout: 2)
            try session.setServer("https://current-feedback.example")
            try probe.fail(URLError(.cannotConnectToHost))
            do {
                try await request.value
                XCTFail("A stale connection must not succeed")
            } catch is CancellationError {
            } catch {
                XCTFail("A previous server must not report feedback in the current session: \(error)")
            }
            XCTAssertEqual(session.baseURL?.host, "current-feedback.example")
        }
    }
}

private final class HeldConnectionFailureProbe: Sendable {
    let started: XCTestExpectation
    private let heldConnection = Mutex<HeldConnectionFailureProtocol?>(nil)

    init(started: XCTestExpectation) { self.started = started }
    func receive(_ connection: HeldConnectionFailureProtocol) {
        heldConnection.withLock { $0 = connection }
        started.fulfill()
    }

    func fail(_ error: Error) throws {
        let connection = heldConnection.withLock { value in
            defer { value = nil }
            return value
        }
        try XCTUnwrap(connection).fail(error)
    }
}

private final class HeldConnectionFailureProtocol: URLProtocol {
    private static let currentProbe = Mutex<HeldConnectionFailureProbe?>(nil)
    static var probe: HeldConnectionFailureProbe? {
        get { currentProbe.withLock { $0 } }
        set { currentProbe.withLock { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.probe?.receive(self)
    }
    override func stopLoading() {}
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}
