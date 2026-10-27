import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SyncAccountIsolationTests: XCTestCase {
    func testStreamCannotWriteOrAcknowledgeAfterAccountChanges() async throws {
        let fixture = try SyncStreamFixture()
        defer { fixture.cleanup() }
        let sync = Task { try await fixture.repository.deltaSync() }
        try await waitForInitialChunk(in: fixture)

        // The response has passed APIClient validation and its first chunk has
        // reached SwiftData. Only the remaining stream belongs to the old account.
        LocalSnapshot.clearAll()
        try fixture.dataManager.clearAllAccountData()
        try fixture.dataManager.insertOrUpdateCachedAsset(
            CachedAsset(id: "next-account-photo", assetId: "next-account-photo", type: "IMAGE"))
        fixture.transport.finishStream()

        do {
            try await sync.value
            XCTFail("The old account's stream must be canceled")
        } catch is CancellationError {
        }

        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 1)
        XCTAssertEqual(fixture.dataManager.timelineAssets().map(\.asset.id), ["next-account-photo"])
        XCTAssertNil(fixture.dataManager.getSyncState().lastFullSyncAt)
        XCTAssertNil(fixture.dataManager.getSyncState().lastDeltaSyncAt)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 0)
    }

    func testCurrentStreamFinishesWritesAndAcknowledgesCheckpoint() async throws {
        let fixture = try SyncStreamFixture()
        defer { fixture.cleanup() }
        let sync = Task { try await fixture.repository.deltaSync() }
        try await waitForInitialChunk(in: fixture)

        fixture.transport.finishStream()
        try await sync.value

        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 501)
        XCTAssertTrue(fixture.dataManager.timelineAssets().contains { $0.asset.id == "stream-500" })
        XCTAssertNotNil(fixture.dataManager.getSyncState().lastFullSyncAt)
        XCTAssertNotNil(fixture.dataManager.getSyncState().lastDeltaSyncAt)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
        XCTAssertEqual(fixture.dataManager.getSyncState().totalAssets, 501)
    }

    private func waitForInitialChunk(in fixture: SyncStreamFixture) async throws {
        let deadline = Date().addingTimeInterval(5)
        while fixture.dataManager.cachedAssetCount() < 500, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.dataManager.cachedAssetCount(), 500,
                       "The test must reach a partially applied live stream")
        guard fixture.dataManager.cachedAssetCount() == 500 else {
            throw SyncStreamTestError.initialChunkNotApplied
        }
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 0)
        XCTAssertNil(fixture.dataManager.getSyncState().lastDeltaSyncAt)
    }
}

private enum SyncStreamTestError: Error {
    case initialChunkNotApplied
}

@MainActor
private final class SyncStreamFixture {
    let directory: URL
    let dataManager: SwiftDataManager
    let repository: SyncRepository
    let transport = HeldSyncStreamTransport()
    private let urlSession: URLSession

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-account-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dataManager = SwiftDataManager(
            storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        let session = MockSessionManager()
        try session.setServer(transport.baseURL.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSyncStreamURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
        repository = SyncRepository(
            api: APIClient(session: session, urlSession: urlSession), dataManager: dataManager)
    }

    func cleanup() {
        urlSession.invalidateAndCancel()
        transport.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class HeldSyncStreamTransport: @unchecked Sendable {
    let baseURL = URL(string: "https://sync-\(UUID().uuidString.lowercased()).invalid")!
    private let lock = NSLock()
    private var heldStream: HeldSyncStreamURLProtocol?
    private var acknowledgments = 0

    init() { HeldSyncStreamURLProtocol.register(self) }

    var acknowledgmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acknowledgments
    }

    func receive(_ request: HeldSyncStreamURLProtocol) {
        let url = request.request.url!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/api/sync/stream" {
            lock.lock()
            heldStream = request
            lock.unlock()
            let firstChunk = (0..<500).map(Self.assetLine).joined()
            request.client?.urlProtocol(request, didLoad: Data(firstChunk.utf8))
        } else if url.path == "/api/sync/ack" {
            lock.lock()
            acknowledgments += 1
            lock.unlock()
            request.client?.urlProtocol(request, didLoad: Data("{}".utf8))
            request.client?.urlProtocolDidFinishLoading(request)
        } else {
            request.client?.urlProtocol(request, didFailWithError: URLError(.badURL))
        }
    }

    func finishStream() {
        lock.lock()
        let stream = heldStream
        heldStream = nil
        lock.unlock()
        XCTAssertNotNil(stream, "The initial stream must remain open")
        guard let stream else { return }
        stream.client?.urlProtocol(stream, didLoad: Data(Self.assetLine(500).utf8))
        stream.client?.urlProtocolDidFinishLoading(stream)
    }

    private static func assetLine(_ index: Int) -> String {
        #"{"type":"AssetV2","ack":"AssetV2|\#(index)","data":{"id":"stream-\#(index)","ownerId":"stream-owner","originalFileName":"photo.jpg","checksum":"YWJj","type":"IMAGE","visibility":"timeline","isFavorite":false,"isEdited":false,"fileCreatedAt":"2026-01-01T00:00:00Z"}}"# + "\n"
    }

    func close() {
        HeldSyncStreamURLProtocol.unregister(self)
        lock.lock()
        let stream = heldStream
        heldStream = nil
        lock.unlock()
        if let stream {
            stream.client?.urlProtocol(stream, didFailWithError: URLError(.cancelled))
        }
    }
}

private final class HeldSyncStreamURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var transports: [String: HeldSyncStreamTransport] = [:]

    static func register(_ transport: HeldSyncStreamTransport) {
        lock.lock()
        transports[transport.baseURL.host!] = transport
        lock.unlock()
    }

    static func unregister(_ transport: HeldSyncStreamTransport) {
        lock.lock()
        transports.removeValue(forKey: transport.baseURL.host!)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transports[request.url?.host ?? ""] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let transport = Self.transports[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let transport else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        transport.receive(self)
    }

    override func stopLoading() {}
}
