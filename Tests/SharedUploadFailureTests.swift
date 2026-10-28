import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadFailureTests: XCTestCase {
    func testHTTPRejectionsPersistAsFailedAndAutomaticRecoveryStillUploadsTheNeighbor() async throws {
        for status in [400, 413, 403, 422] {
            let message = "Rejected source \(status)"
            let fixture = try await SharedFailureFixture(replies: [
                .http(status, message), .success("neighbor-asset"),
            ], count: 2)
            defer { fixture.close() }
            var progress: [String] = []

            let outcome = try await fixture.process { progress.append("\($0)/\($1)") }

            XCTAssertEqual(outcome, .finished(remaining: 1))
            XCTAssertEqual(progress, ["1/2", "2/2"])
            guard let saved = try await fixture.reopenedBatch() else {
                XCTFail("A rejected file must retain its durable recovery manifest")
                continue
            }
            XCTAssertEqual(saved.items.map(\.state), [.failed, .uploaded])
            XCTAssertTrue(saved.items[0].lastError?.contains("HTTP \(status)") == true)
            XCTAssertTrue(saved.items[0].lastError?.contains(message) == true)
            XCTAssertNil(saved.items[1].lastError)
            XCTAssertEqual(saved.owner, fixture.batch.owner)
            XCTAssertEqual(saved.items[0].id, fixture.batch.items[0].id)
            XCTAssertEqual(saved.items[0].filename, fixture.batch.items[0].filename)
            XCTAssertEqual(saved.items[0].byteCount, fixture.batch.items[0].byteCount)
            XCTAssertEqual(saved.items[0].createdAt, fixture.batch.items[0].createdAt)
            XCTAssertEqual(try? Data(contentsOf: fixture.source(0)), fixture.bytes(0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source(1).path))
            XCTAssertEqual(fixture.transport.captures.count, 2)
            for (index, capture) in fixture.transport.captures.enumerated() {
                fixture.assertMultipart(capture, item: index)
            }
            fixture.assertNoMultipartFiles()
            let manifest = try Data(contentsOf: fixture.manifest)
            progress.removeAll()

            let automaticRetry = try await fixture.process { progress.append("\($0)/\($1)") }

            XCTAssertEqual(automaticRetry, .finished(remaining: 1))
            XCTAssertEqual(fixture.transport.captures.count, 2, "Failed sources must not issue another POST")
            XCTAssertTrue(progress.isEmpty, "A failed item is excluded from automatic upload progress")
            XCTAssertEqual(try? Data(contentsOf: fixture.manifest), manifest)
            XCTAssertEqual(try? Data(contentsOf: fixture.source(0)), fixture.bytes(0))
            fixture.assertNoMultipartFiles()
        }
    }

    func testTransientHTTPFailuresKeepTheirSourceAndRetrySuccessfullyAfterReopening() async throws {
        for status in [401, 408, 425, 429, 503] {
            let message = "Try again \(status)"
            let fixture = try await SharedFailureFixture(replies: [
                .http(status, message), .success("recovered-asset"),
            ])
            defer { fixture.close() }

            let first = try await fixture.process()

            XCTAssertEqual(first, .finished(remaining: 1))
            guard let saved = try await fixture.reopenedBatch() else {
                XCTFail("A transient failure must retain its recovery manifest")
                continue
            }
            XCTAssertEqual(saved.items[0].state, .queued)
            XCTAssertTrue(saved.items[0].lastError?.contains("HTTP \(status)") == true)
            XCTAssertTrue(saved.items[0].lastError?.contains(message) == true)
            XCTAssertEqual(try? Data(contentsOf: fixture.source(0)), fixture.bytes(0))
            XCTAssertEqual(fixture.transport.captures.count, 1)
            fixture.assertNoMultipartFiles()
            var progress: [String] = []

            let second = try await fixture.process { progress.append("\($0)/\($1)") }

            XCTAssertEqual(second, .finished(remaining: 0))
            XCTAssertEqual(progress, ["1/1"])
            XCTAssertEqual(fixture.transport.captures.count, 2)
            for capture in fixture.transport.captures { fixture.assertMultipart(capture, item: 0) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
            let batches = try await SharedUploadStore(rootURL: fixture.root).batches(for: fixture.batch.owner)
            XCTAssertTrue(batches.isEmpty)
        }
    }

    func testMalformedSuccessResponseKeepsTheOriginalForAReadableResponseOnRetry() async throws {
        let fixture = try await SharedFailureFixture(replies: [
            .http(201, #"{"unexpected":"missing asset id"}"#), .success("readable-asset"),
        ])
        defer { fixture.close() }

        let first = try await fixture.process()

        XCTAssertEqual(first, .finished(remaining: 1))
        let saved = try await fixture.reopenedBatch()
        XCTAssertEqual(saved?.items.first?.state, .queued)
        XCTAssertFalse(saved?.items.first?.lastError?.isEmpty ?? true)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(0)), fixture.bytes(0))
        fixture.assertNoMultipartFiles()
        let recovered = try await fixture.process()
        XCTAssertEqual(recovered, .finished(remaining: 0))
        XCTAssertEqual(fixture.transport.captures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testTransportTimeoutKeepsTheOriginalAndDoesNotBecomeATerminalFailure() async throws {
        let fixture = try await SharedFailureFixture(replies: [
            .transport(URLError(.timedOut)), .success("after-timeout"),
        ])
        defer { fixture.close() }

        let first = try await fixture.process()

        XCTAssertEqual(first, .finished(remaining: 1))
        let saved = try await fixture.reopenedBatch()
        XCTAssertEqual(saved?.items.first?.state, .queued)
        XCTAssertFalse(saved?.items.first?.lastError?.isEmpty ?? true)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(0)), fixture.bytes(0))
        fixture.assertNoMultipartFiles()
        let recovered = try await fixture.process()
        XCTAssertEqual(recovered, .finished(remaining: 0))
        XCTAssertEqual(fixture.transport.captures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }
}

@MainActor
private final class SharedFailureFixture {
    let root: URL
    let directory: URL
    let manifest: URL
    let batch: SharedUploadBatch
    let transport: SharedFailureTransport
    private let session: URLSession
    private let client: SharedUploadClient
    private let endpoint: URL

    init(replies: [SharedFailureTransport.Reply], count: Int = 1) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-http-failure-\(UUID())")
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        endpoint = URL(string: "https://shared-failure-\(id.uuidString.lowercased()).example/api")!
        let owner = SharedUploadOwner(server: endpoint.absoluteString, userID: "shared-http-owner")
        batch = SharedUploadBatch(id: id, owner: owner, createdAt: date, items: (0..<count).map { index in
            SharedUploadItem(id: UUID(), filename: "source-\(index).jpg", relativePath: "source-\(index).jpg",
                contentType: "image/jpeg", byteCount: 9, createdAt: date, modifiedAt: date,
                state: .queued, lastError: nil)
        })
        let store = SharedUploadStore(rootURL: root)
        directory = try await store.makeBatchDirectory(id: id)
        manifest = directory.appendingPathComponent("manifest.json")
        transport = SharedFailureTransport(host: endpoint.host!, directory: directory, replies: replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedFailureURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration)
        client = SharedUploadClient(credential: .init(apiURL: endpoint, owner: owner,
            authHeaders: ["Authorization": "Bearer shared-http-test-token"]), session: session)
        for index in batch.items.indices { try bytes(index).write(to: source(index)) }
        try await store.save(batch)
    }

    func process(progress: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> SharedUploadProcessor.Outcome {
        try await SharedUploadProcessor(store: SharedUploadStore(rootURL: root)).process(
            batchID: batch.id, owner: batch.owner, upload: { item, source, directory in
                _ = try await self.client.upload(item: item, fileURL: source, bodyDirectory: directory)
            }, progress: progress)
    }

    func reopenedBatch() async throws -> SharedUploadBatch? {
        try await SharedUploadStore(rootURL: root).batch(id: batch.id, owner: batch.owner)
    }

    func bytes(_ index: Int) -> Data { Data([0, 1, 2, 13, 10, 255, 34, 92, UInt8(index)]) }
    func source(_ index: Int) -> URL { directory.appendingPathComponent(batch.items[index].relativePath) }

    func assertMultipart(_ capture: SharedFailureTransport.Capture, item index: Int,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(capture.request.url, endpoint.appendingPathComponent("assets"), file: file, line: line)
        XCTAssertEqual(capture.request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(capture.request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer shared-http-test-token", file: file, line: line)
        let checksum = index == 0 ? "3cf287d41fc18c3543c49aa74439a6722b62e679" : "3c30ae0d3c60b8d6bc0f63b0b5cf57aaccd0fb2b"
        XCTAssertEqual(capture.request.value(forHTTPHeaderField: "x-immich-checksum"), checksum, file: file, line: line)
        guard let body = capture.multipart, let boundary = capture.boundary else {
            return XCTFail("The HTTP request must use a readable completed multipart file", file: file, line: line)
        }
        XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\n".utf8)), file: file, line: line)
        let ending = Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertTrue(body.suffix(ending.count).elementsEqual(ending), file: file, line: line)
        XCTAssertNotNil(body.range(of: bytes(index)), file: file, line: line)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"deviceAssetId\"\r\n\r\nshare-\(batch.items[index].id.uuidString)"), file: file, line: line)
        XCTAssertTrue(text.contains("name=\"assetData\"; filename=\"\(batch.items[index].filename)\""), file: file, line: line)
        XCTAssertTrue(text.contains("Content-Type: image/jpeg\r\n"), file: file, line: line)
    }

    func assertNoMultipartFiles(file: StaticString = #filePath, line: UInt = #line) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(files.filter { $0.pathExtension == "multipart" }.isEmpty,
                          "The request's temporary body must be removed after success or failure", file: file, line: line)
        } catch {
            XCTFail("The upload directory could not be inspected: \(error)", file: file, line: line)
        }
    }

    func close() {
        session.invalidateAndCancel()
        transport.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SharedFailureTransport: @unchecked Sendable {
    enum Reply {
        case http(Int, String)
        case transport(URLError)
        static func success(_ id: String) -> Self { .http(201, "{\"id\":\"\(id)\"}") }
    }
    struct Capture {
        let request: URLRequest
        let boundary: String?
        let multipart: Data?
    }
    private static let registryLock = NSLock()
    private static var registry: [String: SharedFailureTransport] = [:]
    private let lock = NSLock()
    private let host: String
    private let directory: URL
    private var replies: [Reply]
    private var recorded: [Capture] = []
    var captures: [Capture] { lock.withLock { recorded } }

    init(host: String, directory: URL, replies: [Reply]) {
        self.host = host
        self.directory = directory
        self.replies = replies
        Self.registryLock.withLock { Self.registry[host] = self }
    }
    static func registered(for request: URLRequest) -> SharedFailureTransport? {
        guard let host = request.url?.host else { return nil }
        return registryLock.withLock { registry[host] }
    }
    func close() { Self.registryLock.withLock { _ = Self.registry.removeValue(forKey: host) } }

    func receive(_ loading: SharedFailureURLProtocol) {
        let request = loading.request
        let prefix = "multipart/form-data; boundary="
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = contentType.hasPrefix(prefix) ? String(contentType.dropFirst(prefix.count)) : nil
        let body = boundary.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0 + ".multipart")) }
        let reply: Reply = lock.withLock {
            recorded.append(Capture(request: request, boundary: boundary, multipart: body))
            return replies.isEmpty ? .http(500, "Unexpected extra upload") : replies.removeFirst()
        }
        switch reply {
        case .transport(let error): loading.client?.urlProtocol(loading, didFailWithError: error)
        case .http(let status, let body):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                loading.client?.urlProtocol(loading, didFailWithError: URLError(.badServerResponse))
                return
            }
            loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            loading.client?.urlProtocol(loading, didLoad: Data(body.utf8))
            loading.client?.urlProtocolDidFinishLoading(loading)
        }
    }
}

private final class SharedFailureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { SharedFailureTransport.registered(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let transport = SharedFailureTransport.registered(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        transport.receive(self)
    }
    override func stopLoading() {}
}
