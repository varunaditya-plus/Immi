import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SyncPrivacyIsolationTests: XCTestCase {
    func testPreLockStreamCannotRestorePublicVisibilityOrAcknowledgeBufferedRows() async throws {
        let fixture = try PrivacySyncFixture()
        defer { fixture.cleanup() }
        let sync = Task { try await fixture.repository.deltaSync() }
        try await waitForInitialChunk(in: fixture)
        try fixture.store.linkDeviceAsset(localIdentifier: "private-device", to: "stream-250")

        // The old response has already passed transport validation and applied
        // 500 rows. Its next row still describes this now-locked photo as public.
        try fixture.store.setTimelineVisibility(["stream-250"], inTimeline: false)
        fixture.transport.finishStream()
        await assertCancelled(sync)

        let photo = try XCTUnwrap(fixture.store.getCachedAsset(id: "stream-250"))
        XCTAssertTrue(photo.isArchived)
        XCTAssertFalse(photo.isFavorite)
        XCTAssertEqual(photo.ratio, 1)
        XCTAssertTrue(fixture.store.nonTimelineAssetIDs.contains("stream-250"))
        XCTAssertFalse(fixture.store.timelineAssets().contains { $0.asset.id == "stream-250" })
        XCTAssertEqual(fixture.store.getBackupRecord(localIdentifier: "private-device")?.assetId, "stream-250")
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 0)
        XCTAssertNil(fixture.store.getSyncState().lastFullSyncAt)
        XCTAssertNil(fixture.store.getSyncState().lastDeltaSyncAt)
        let restored = fixture.reopenStore()
        XCTAssertTrue(restored.nonTimelineAssetIDs.contains("stream-250"))
        XCTAssertTrue(try XCTUnwrap(restored.getCachedAsset(id: "stream-250")).isArchived)
    }

    func testFreshStreamCanConfirmPublicVisibilityAndSaveItsCheckpoint() async throws {
        let fixture = try PrivacySyncFixture()
        defer { fixture.cleanup() }
        try fixture.store.setTimelineVisibility(["stream-250"], inTimeline: false)
        let sync = Task { try await fixture.repository.deltaSync() }
        try await waitForInitialChunk(in: fixture)

        fixture.transport.finishStream()
        try await sync.value

        let photo = try XCTUnwrap(fixture.store.getCachedAsset(id: "stream-250"))
        XCTAssertFalse(photo.isArchived)
        XCTAssertTrue(photo.isFavorite)
        XCTAssertEqual(photo.ratio, 3)
        XCTAssertFalse(fixture.store.nonTimelineAssetIDs.contains("stream-250"))
        XCTAssertTrue(fixture.store.timelineAssets().contains { $0.asset.id == "stream-250" })
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1)
        XCTAssertNotNil(fixture.store.getSyncState().lastFullSyncAt)
        XCTAssertNotNil(fixture.store.getSyncState().lastDeltaSyncAt)
        XCTAssertEqual(fixture.store.getSyncState().totalAssets, 500)
        XCTAssertFalse(fixture.reopenStore().nonTimelineAssetIDs.contains("stream-250"))
    }

    func testLockDuringAcknowledgmentPreventsOldCheckpointFromBeingSaved() async throws {
        let acknowledgmentStarted = expectation(description: "Server acknowledgment is in flight")
        let fixture = try PrivacySyncFixture(acknowledgmentStarted: acknowledgmentStarted)
        defer { fixture.cleanup() }
        let sync = Task { try await fixture.repository.deltaSync() }
        try await waitForInitialChunk(in: fixture)
        fixture.transport.finishStream()
        await fulfillment(of: [acknowledgmentStarted], timeout: 2)

        try fixture.store.setTimelineVisibility(["stream-250"], inTimeline: false)
        fixture.transport.finishAcknowledgment()
        await assertCancelled(sync)

        XCTAssertTrue(try XCTUnwrap(fixture.store.getCachedAsset(id: "stream-250")).isArchived)
        XCTAssertTrue(fixture.store.nonTimelineAssetIDs.contains("stream-250"))
        XCTAssertNil(fixture.store.getSyncState().lastFullSyncAt)
        XCTAssertNil(fixture.store.getSyncState().lastDeltaSyncAt)
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 1,
            "This acknowledgment had already been sent before the local lock")
    }

    private func assertCancelled(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            XCTFail("The stream predates a local visibility change and must be rejected")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func waitForInitialChunk(in fixture: PrivacySyncFixture) async throws {
        let deadline = Date().addingTimeInterval(5)
        while fixture.store.cachedAssetCount() < 500, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.store.cachedAssetCount(), 500,
            "The test must reach a live stream whose first chunk was persisted")
        guard fixture.store.cachedAssetCount() == 500 else {
            throw PrivacySyncTestError.initialChunkNotApplied
        }
        XCTAssertEqual(fixture.transport.acknowledgmentCount, 0)
        XCTAssertNil(fixture.store.getSyncState().lastDeltaSyncAt)
    }
}

private enum PrivacySyncTestError: Error {
    case initialChunkNotApplied
}

@MainActor
private final class PrivacySyncFixture {
    let directory: URL
    let store: SwiftDataManager
    let repository: SyncRepository
    let transport: PrivacySyncTransport
    private let urlSession: URLSession

    init(acknowledgmentStarted: XCTestExpectation? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-privacy-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
        transport = PrivacySyncTransport(acknowledgmentStarted: acknowledgmentStarted)
        let session = MockSessionManager()
        try session.setServer(transport.baseURL.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacySyncURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
        repository = SyncRepository(api: APIClient(session: session, urlSession: urlSession), dataManager: store)
    }

    func reopenStore() -> SwiftDataManager {
        SwiftDataManager(storeURL: directory.appendingPathComponent("test.store"),
            backupJournalURL: directory.appendingPathComponent("backup.json"))
    }

    func cleanup() {
        urlSession.invalidateAndCancel()
        transport.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PrivacySyncTransport: @unchecked Sendable {
    let baseURL = URL(string: "https://sync-privacy-\(UUID().uuidString.lowercased()).invalid")!
    private let lock = NSLock()
    private var heldStream: PrivacySyncURLProtocol?
    private var heldAcknowledgment: PrivacySyncURLProtocol?
    private var acknowledgments = 0
    private let acknowledgmentStarted: XCTestExpectation?

    init(acknowledgmentStarted: XCTestExpectation?) {
        self.acknowledgmentStarted = acknowledgmentStarted
        PrivacySyncURLProtocol.register(self)
    }

    var acknowledgmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acknowledgments
    }

    func receive(_ request: PrivacySyncURLProtocol) {
        let url = request.request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/api/sync/stream" {
            lock.lock()
            heldStream = request
            lock.unlock()
            let firstChunk = (0..<500).map { Self.assetLine($0) }.joined()
            request.client?.urlProtocol(request, didLoad: Data(firstChunk.utf8))
        } else if url.path == "/api/sync/ack" {
            lock.lock()
            acknowledgments += 1
            if acknowledgmentStarted != nil { heldAcknowledgment = request }
            lock.unlock()
            if let acknowledgmentStarted {
                acknowledgmentStarted.fulfill()
            } else {
                finish(request)
            }
        } else {
            request.client?.urlProtocol(request, didFailWithError: URLError(.badURL))
        }
    }

    func finishStream() {
        lock.lock()
        let stream = heldStream
        heldStream = nil
        lock.unlock()
        XCTAssertNotNil(stream, "The first chunk must leave the real HTTP stream open")
        guard let stream else { return }
        stream.client?.urlProtocol(stream, didLoad: Data(Self.assetLine(250, favorite: true, width: 300, ack: 500).utf8))
        stream.client?.urlProtocolDidFinishLoading(stream)
    }

    func finishAcknowledgment() {
        lock.lock()
        let request = heldAcknowledgment
        heldAcknowledgment = nil
        lock.unlock()
        XCTAssertNotNil(request, "The acknowledgment must be waiting for its response")
        if let request { finish(request) }
    }

    private func finish(_ request: PrivacySyncURLProtocol) {
        request.client?.urlProtocol(request, didLoad: Data("{}".utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }

    private static func assetLine(_ index: Int, favorite: Bool = false, width: Int = 100, ack: Int? = nil) -> String {
        #"{"type":"AssetV2","ack":"AssetV2|\#(ack ?? index)","data":{"id":"stream-\#(index)","ownerId":"stream-owner","originalFileName":"photo.jpg","checksum":"YWJj","type":"IMAGE","visibility":"timeline","isFavorite":\#(favorite),"isEdited":false,"width":\#(width),"height":100,"fileCreatedAt":"2026-01-01T00:00:00Z"}}"# + "\n"
    }

    func close() {
        PrivacySyncURLProtocol.unregister(self)
        lock.lock()
        let requests = [heldStream, heldAcknowledgment].compactMap { $0 }
        heldStream = nil
        heldAcknowledgment = nil
        lock.unlock()
        for request in requests {
            request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled))
        }
    }
}

private final class PrivacySyncURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var transports: [String: PrivacySyncTransport] = [:]

    static func register(_ transport: PrivacySyncTransport) {
        lock.lock()
        transports[transport.baseURL.host!] = transport
        lock.unlock()
    }

    static func unregister(_ transport: PrivacySyncTransport) {
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
