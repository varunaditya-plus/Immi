import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadStatusFreshnessTests: XCTestCase {
    private var fixtures: [FreshnessFixture] = []
    private var listGates: [FreshnessListGate] = []

    override func tearDown() async throws {
        for gate in listGates { gate.release() }
        listGates.removeAll()
        for fixture in fixtures { fixture.close() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    func testListingFailureKeepsKnownRowsButSuccessfulRefreshClearsOnlyThatError() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let batch = try await fixture.seed(state: .failed)
        await fixture.service.refreshPending(session: fixture.session)
        files.failNextList()

        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertNotNil(fixture.service.lastError)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertNil(fixture.service.lastError)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        XCTAssertEqual(fixture.service.items.first?.item.lastError, "HTTP 413: Too large")
    }

    func testInitialRecoveryListingFailureCanBeClearedByAPlainRefresh() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        // The cleanup pass enumerates once before recovery enumerates batches.
        files.failList(number: 2)

        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await work.value

        XCTAssertNotNil(fixture.service.lastError)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertNil(fixture.service.lastError)
    }

    func testSuccessfulListingDoesNotEraseARealProcessingCleanupFailure() async throws {
        let files = FreshnessFiles()
        var uploads = 0
        let fixture = try fixture(files: files, upload: { _, _, _, _ in uploads += 1 })
        let batch = try await fixture.seed()
        files.failSourceRemoval = true

        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await work.value

        let processingError = try XCTUnwrap(fixture.service.lastError)
        XCTAssertEqual(processingError, CocoaError(.fileWriteNoPermission).localizedDescription)
        XCTAssertTrue(fixture.service.items.isEmpty, "The uploaded source needs cleanup, not another transfer")
        let saved = try await fixture.store.batch(id: batch.id, owner: batch.owner)
        XCTAssertEqual(saved?.items.first?.state, .uploaded)
        XCTAssertEqual(uploads, 1)
        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertEqual(fixture.service.lastError, processingError)
        files.failSourceRemoval = false
        let retry = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await retry.value
        XCTAssertNil(fixture.service.lastError)
        XCTAssertEqual(uploads, 1, "The accepted item must only clean its original during recovery")
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    private func fixture(
        files: FreshnessFiles = FreshnessFiles(),
        upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void = {
            _, _, _, _ in XCTFail("Listing must not start an upload")
        }
    ) throws -> FreshnessFixture {
        let fixture = try FreshnessFixture(files: files, upload: upload)
        fixtures.append(fixture)
        return fixture
    }

    private func listGate() -> FreshnessListGate {
        let gate = FreshnessListGate()
        listGates.append(gate)
        return gate
    }
}

@MainActor
private final class FreshnessFixture {
    let root: URL
    let store: SharedUploadStore
    let service: SharedUploadService
    let session: FreshnessSession
    let files: FreshnessFiles

    init(files: FreshnessFiles,
         upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void) throws {
        self.files = files
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-freshness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SharedUploadStore(rootURL: root, fileManager: files)
        service = SharedUploadService(store: store, upload: upload)
        session = FreshnessSession()
        try session.setServer("https://shared-freshness.example")
        session.testAuthHeaders = ["x-api-key": "freshness-test"]
        session.isLoggedIn = true
    }

    func seed(state: SharedUploadItemState = .queued) async throws -> SharedUploadBatch {
        let id = UUID()
        let directory = try await store.makeBatchDirectory(id: id)
        try Data("original".utf8).write(to: directory.appendingPathComponent("shared.jpg"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let batch = SharedUploadBatch(id: id,
            owner: .init(server: session.owner.server, userID: session.owner.userID), createdAt: date, items: [
                .init(id: UUID(), filename: "shared.jpg", relativePath: "shared.jpg", contentType: "image/jpeg",
                    byteCount: 8, createdAt: date, modifiedAt: date, state: state,
                    lastError: state == .failed ? "HTTP 413: Too large" : nil)
            ])
        try await store.save(batch)
        return batch
    }

    func close() {
        service.cancel()
        files.failSourceRemoval = false
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class FreshnessSession: MockSessionManager {
    var owner = BackupQueueOwner(server: "https://shared-freshness.example/api", userID: "owner")
    override var backupQueueOwner: BackupQueueOwner? { owner }
}

private final class FreshnessFiles: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [FreshnessListGate] = []
    private var listCount = 0
    private var failAtList: Int?
    private var removalFailure = false

    var failSourceRemoval: Bool {
        get { lock.withLock { removalFailure } }
        set { lock.withLock { removalFailure = newValue } }
    }

    func holdNextList(_ gate: FreshnessListGate) { lock.withLock { gates.append(gate) } }
    func failNextList() { lock.withLock { failAtList = listCount + 1 } }
    func failList(number: Int) { lock.withLock { failAtList = number } }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let action: (Bool, FreshnessListGate?) = lock.withLock {
            listCount += 1
            return (listCount == failAtList, gates.isEmpty ? nil : gates.removeFirst())
        }
        if action.0 { throw CocoaError(.fileReadNoPermission) }
        let result = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        action.1?.wait()
        return result
    }

    override func removeItem(at url: URL) throws {
        if failSourceRemoval, url.lastPathComponent == "shared.jpg" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class FreshnessListGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "A shared inbox listing is held")
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        started.fulfill()
        let deadline = Date(timeIntervalSinceNow: 10)
        while !released {
            guard condition.wait(until: deadline) else {
                XCTFail("The listing gate was not released")
                return
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class FreshnessUploadGate {
    let started = XCTestExpectation(description: "A recovery upload reached its response boundary")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
