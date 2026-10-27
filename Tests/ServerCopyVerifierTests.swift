import CryptoKit
import XCTest
@testable import ImmichApp

@MainActor
final class ServerCopyVerifierTests: XCTestCase {
    private let image = Data("current photo original".utf8)
    private let motion = Data("current live photo motion".utf8)

    func testMatchingOriginalIsDownloadedAndTemporaryFileIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("photo", bytes: image)

        let verified = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))

        XCTAssertNotNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 1)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let requests = fixture.server.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/assets/photo", "/api/assets/photo/original", "/api/assets/photo"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer current-token" })
        let original = try XCTUnwrap(requests.first { $0.url!.path.hasSuffix("/original") })
        XCTAssertEqual(URLComponents(url: original.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [.init(name: "edited", value: "false")])
    }

    func testMatchingVideoRequiresVideoMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("video", bytes: motion, type: "VIDEO")

        let wrongType = try await fixture.verifier.verify(assetID: "video", primaryChecksum: sha1(motion))
        XCTAssertNil(wrongType)
        XCTAssertTrue(fixture.api.downloads.isEmpty)
        let verified = try await fixture.verifier.verify(
            assetID: "video", primaryChecksum: sha1(motion), primaryIsVideo: true)
        XCTAssertNotNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 1)
    }

    func testTrashedOfflineMismatchedAndIncompleteRecordsCannotProveBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let valid = metadata("photo", bytes: image)
        let variants: [[String: Any]] = [
            valid.merging(["isTrashed": true]) { _, new in new },
            valid.merging(["isOffline": true]) { _, new in new },
            valid.merging(["id": "another-photo"]) { _, new in new },
            valid.merging(["type": "AUDIO"]) { _, new in new },
            valid.merging(["checksum": "not-a-sha1"]) { _, new in new },
            valid.merging(["checksum": Data(repeating: 1, count: 20).base64EncodedString()]) { _, new in new },
        ]
        for object in variants {
            fixture.server.reply("/assets/photo", json: object)
            let verified = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))
            XCTAssertNil(verified, "Unsafe metadata must not count as a server copy: \(object)")
        }
        var incomplete = valid
        incomplete.removeValue(forKey: "isOffline")
        fixture.server.reply("/assets/photo", json: incomplete)
        do {
            _ = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))
            XCTFail("Missing availability proof must fail closed")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(fixture.api.downloads.isEmpty)
    }

    func testOriginalBytesMustMatchEvenWhenMetadataClaimsTheRightChecksum() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("photo", bytes: image)
        fixture.server.reply("/assets/photo/original", bytes: Data("truncated or wrong file".utf8))

        let verified = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))

        XCTAssertNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 1)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testEmptyOriginalCannotAuthorizeDeletionEvenWithMatchingChecksum() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("photo", bytes: Data())

        let proof = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(Data()))

        XCTAssertNil(proof)
        XCTAssertEqual(fixture.api.downloads.count, 1)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testMissingOriginalAndRejectedRequestsDoNotReturnProof() async throws {
        for status in [401, 403, 404, 500] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.server.asset("photo", bytes: image)
            fixture.server.reply("/assets/photo/original", bytes: Data("{}".utf8), status: status)
            do {
                _ = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))
                XCTFail("An unavailable original must not permit deletion")
            } catch let error as APIError {
                if status == 401 {
                    guard case .unauthorized = error else { return XCTFail("Unexpected error: \(error)") }
                } else {
                    guard case .server(let actual, _) = error else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertEqual(actual, status)
                }
            }
        }
    }

    func testMetadataChangeDuringDownloadRejectsTheCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("photo", bytes: image)
        var trashed = metadata("photo", bytes: image)
        trashed["isTrashed"] = true
        fixture.server.sequence("/assets/photo", json: [metadata("photo", bytes: image), trashed])

        let verified = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: sha1(image))

        XCTAssertNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 1)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testLivePhotoRequiresBothLinkedOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("still", bytes: image, motionID: "motion")
        fixture.server.asset("motion", bytes: motion, type: "VIDEO")

        let verified = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))

        XCTAssertNotNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 2)
        XCTAssertEqual(fixture.server.requests.filter { $0.url!.path.hasSuffix("/original") }.map { $0.url!.path },
            ["/api/assets/still/original", "/api/assets/motion/original"])
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testLivePhotoWithoutItsMotionOrWithWrongMotionBytesIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("still", bytes: image)
        let missingLink = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))
        XCTAssertNil(missingLink)
        XCTAssertTrue(fixture.api.downloads.isEmpty)

        fixture.server.asset("still", bytes: image, motionID: "motion")
        fixture.server.asset("motion", bytes: motion, type: "VIDEO")
        fixture.server.reply("/assets/motion/original", bytes: Data("different motion".utf8))
        let wrongMotion = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))
        XCTAssertNil(wrongMotion)
        XCTAssertEqual(fixture.api.downloads.count, 2)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testLivePhotoPairChangedAfterDownloadIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("still", bytes: image, motionID: "motion")
        fixture.server.asset("motion", bytes: motion, type: "VIDEO")
        fixture.server.sequence("/assets/still", json: [
            metadata("still", bytes: image, motionID: "motion"),
            metadata("still", bytes: image, motionID: "new-motion"),
        ])

        let verified = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))

        XCTAssertNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 2)
    }

    func testMotionTrashedDuringDownloadRejectsTheWholeLivePhoto() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("still", bytes: image, motionID: "motion")
        fixture.server.asset("motion", bytes: motion, type: "VIDEO")
        var trashedMotion = metadata("motion", bytes: motion, type: "VIDEO")
        trashedMotion["isTrashed"] = true
        fixture.server.sequence("/assets/motion", json: [
            metadata("motion", bytes: motion, type: "VIDEO"), trashedMotion,
        ])

        let verified = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))

        XCTAssertNil(verified)
        XCTAssertEqual(fixture.api.downloads.count, 2)
        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCancellationAfterFileDownloadRemovesItAndCannotReturnProof() async throws {
        let started = expectation(description: "Original file downloaded")
        let gate = ServerFileGate(started: started)
        let fixture = try Fixture(gate: gate)
        defer { fixture.close() }
        fixture.server.asset("photo", bytes: image)
        let checksum = sha1(image)
        let verification = Task { try await fixture.verifier.verify(assetID: "photo", primaryChecksum: checksum) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.api.downloads.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.api.downloads.first).path))

        verification.cancel()
        await gate.release()
        do {
            _ = try await verification.value
            XCTFail("Canceled verification cannot authorize deletion")
        } catch is CancellationError {}

        XCTAssertTrue(fixture.api.downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFinalProofCheckRejectsCopyTrashedWhileOtherFilesWereVerified() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("first", bytes: image)
        fixture.server.asset("other", bytes: motion, type: "VIDEO")
        let firstResult = try await fixture.verifier.verify(assetID: "first", primaryChecksum: sha1(image))
        let first = try XCTUnwrap(firstResult)
        let initiallyCurrent = try await fixture.verifier.isCurrent(first)
        XCTAssertTrue(initiallyCurrent)
        var trashed = metadata("first", bytes: image)
        trashed["isTrashed"] = true
        fixture.server.reply("/assets/first", json: trashed)
        let otherResult = try await fixture.verifier.verify(
            assetID: "other", primaryChecksum: sha1(motion), primaryIsVideo: true)
        let other = try XCTUnwrap(otherResult)

        let firstStillCurrent = try await fixture.verifier.isCurrent(first)
        let otherStillCurrent = try await fixture.verifier.isCurrent(other)

        XCTAssertFalse(firstStillCurrent)
        XCTAssertTrue(otherStillCurrent)
        XCTAssertEqual(fixture.api.downloads.count, 2, "Final proof checks do not download the originals again")
    }

    func testFinalProofCheckRejectsChangedLivePhotoMotion() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.server.asset("still", bytes: image, motionID: "motion")
        fixture.server.asset("motion", bytes: motion, type: "VIDEO")
        let result = try await fixture.verifier.verify(
            assetID: "still", primaryChecksum: sha1(image), motionChecksum: sha1(motion))
        let proof = try XCTUnwrap(result)
        let initiallyCurrent = try await fixture.verifier.isCurrent(proof)
        XCTAssertTrue(initiallyCurrent)
        var changed = metadata("motion", bytes: motion, type: "VIDEO")
        changed["isOffline"] = true
        fixture.server.reply("/assets/motion", json: changed)

        let stillCurrent = try await fixture.verifier.isCurrent(proof)

        XCTAssertFalse(stillCurrent)
        XCTAssertEqual(fixture.api.downloads.count, 2)
    }

    func testInvalidFreshChecksumDoesNotMakeAnyRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let invalidPrimary = try await fixture.verifier.verify(assetID: "photo", primaryChecksum: "old-checksum")
        let invalidMotion = try await fixture.verifier.verify(
            assetID: "photo", primaryChecksum: sha1(image), motionChecksum: "unknown")
        XCTAssertNil(invalidPrimary)
        XCTAssertNil(invalidMotion)
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    private func metadata(_ id: String, bytes: Data, type: String = "IMAGE", motionID: String? = nil) -> [String: Any] {
        serverCopyMetadata(id, bytes: bytes, type: type, motionID: motionID)
    }

    private func sha1(_ bytes: Data) -> String {
        Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private final class Fixture {
        let server = ServerCopyHTTPFixture()
        let api: TrackingServerCopyAPI
        let verifier: ServerCopyVerifier

        init(gate: ServerFileGate? = nil) throws {
            let session = MockSessionManager()
            try session.setServer(server.baseURL.absoluteString)
            session.testAuthHeaders = ["Authorization": "Bearer current-token"]
            let configuration = NetworkResponseCache.configuration()
            configuration.protocolClasses = [ServerCopyURLProtocol.self]
            api = TrackingServerCopyAPI(session: session,
                urlSession: URLSession(configuration: configuration), gate: gate)
            verifier = ServerCopyVerifier(api: api)
        }

        func close() { server.close() }
    }
}

private func serverCopyMetadata(_ id: String, bytes: Data, type: String, motionID: String?) -> [String: Any] {
    var value: [String: Any] = [
        "id": id, "type": type, "isTrashed": false, "isOffline": false,
        "checksum": Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString(),
    ]
    value["livePhotoVideoId"] = motionID
    return value
}

actor ServerFileGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() {
        XCTAssertNotNil(continuation)
        continuation?.resume()
        continuation = nil
    }
}

final class TrackingServerCopyAPI: APIClient {
    private let lock = NSLock()
    private var files: [URL] = []
    private let gate: ServerFileGate?
    var downloads: [URL] { lock.withLock { files } }
    init(session: SessionManager, urlSession: URLSession, gate: ServerFileGate?) {
        self.gate = gate
        super.init(session: session, urlSession: urlSession)
    }
    override func rawFile(_ endpoint: Endpoint) async throws -> URL {
        let file = try await super.rawFile(endpoint)
        lock.withLock { files.append(file) }
        await gate?.wait()
        return file
    }
}

final class ServerCopyHTTPFixture: @unchecked Sendable {
    struct Reply {
        let status: Int
        let bytes: Data
    }
    let baseURL = URL(string: "https://server-copy-\(UUID().uuidString.lowercased()).invalid")!
    private let lock = NSLock()
    private var responses: [String: [Reply]] = [:]
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init() { ServerCopyURLProtocol.register(self) }
    func close() { ServerCopyURLProtocol.unregister(self) }
    func asset(_ id: String, bytes: Data, type: String = "IMAGE", motionID: String? = nil) {
        reply("/assets/\(id)", json: serverCopyMetadata(id, bytes: bytes, type: type, motionID: motionID))
        reply("/assets/\(id)/original", bytes: bytes)
    }
    func reply(_ path: String, json: [String: Any]) {
        reply(path, bytes: try! JSONSerialization.data(withJSONObject: json))
    }
    func reply(_ path: String, bytes: Data, status: Int = 200) {
        lock.withLock { responses["/api" + path] = [Reply(status: status, bytes: bytes)] }
    }
    func sequence(_ path: String, json: [[String: Any]]) {
        lock.withLock {
            responses["/api" + path] = json.map { Reply(status: 200, bytes: try! JSONSerialization.data(withJSONObject: $0)) }
        }
    }
    func response(for request: URLRequest) -> Reply {
        lock.withLock {
            recorded.append(request)
            let path = request.url!.path
            guard var replies = responses[path], let response = replies.first else {
                return Reply(status: 404, bytes: Data("{}".utf8))
            }
            if replies.count > 1 { replies.removeFirst(); responses[path] = replies }
            return response
        }
    }
}

final class ServerCopyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: ServerCopyHTTPFixture] = [:]
    static func register(_ fixture: ServerCopyHTTPFixture) {
        lock.withLock { servers[fixture.baseURL.host!] = fixture }
    }
    static func unregister(_ fixture: ServerCopyHTTPFixture) {
        lock.withLock { servers[fixture.baseURL.host!] = nil }
    }
    private static func server(_ request: URLRequest) -> ServerCopyHTTPFixture? {
        lock.withLock { request.url?.host.flatMap { servers[$0] } }
    }
    override class func canInit(with request: URLRequest) -> Bool { server(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server(request) else { return }
        let reply = server.response(for: request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
