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

    func testAColdEmptyArrayDoesNotVerifyThatTheSharedInboxIsEmpty() async throws {
        let fixture = try fixture()
        let batch = try await fixture.seed()

        XCTAssertTrue(fixture.service.items.isEmpty)
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)

        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        XCTAssertNil(fixture.service.lastError)
    }

    func testACompletedEmptyReadEstablishesAnEmptySnapshot() async throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)

        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertTrue(fixture.service.items.isEmpty)
        XCTAssertNil(fixture.service.lastError)
    }

    func testCorruptManifestCannotCertifyAnEmptyInboxOrEraseKnownRows() async throws {
        for hasPreviousSnapshot in [false, true] {
            let fixture = try fixture()
            let batch = try await fixture.seed()
            let savedDirectory = try await fixture.store.existingBatchDirectory(id: batch.id)
            let directory = try XCTUnwrap(savedDirectory)
            let manifest = directory.appendingPathComponent("manifest.json")
            let originalManifest = try Data(contentsOf: manifest)
            let source = directory.appendingPathComponent(batch.items[0].relativePath)
            let originalSource = try Data(contentsOf: source)
            if hasPreviousSnapshot { await fixture.service.refreshPending(session: fixture.session) }
            let knownRows = fixture.service.items
            let corrupted = Data("{ incomplete manifest".utf8)
            try corrupted.write(to: manifest, options: .atomic)

            await fixture.service.refreshPending(session: fixture.session)

            XCTAssertFalse(fixture.service.hasCurrentSnapshot)
            XCTAssertNotNil(fixture.service.lastError)
            XCTAssertEqual(fixture.service.items, knownRows)
            XCTAssertEqual(try Data(contentsOf: manifest), corrupted)
            XCTAssertEqual(try Data(contentsOf: source), originalSource)

            try originalManifest.write(to: manifest, options: .atomic)
            await fixture.service.refreshPending(session: fixture.session)

            XCTAssertTrue(fixture.service.hasCurrentSnapshot)
            XCTAssertNil(fixture.service.lastError)
            XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        }
    }

    func testUnsupportedOrMismatchedManifestCannotCertifyAnEmptyInbox() async throws {
        for (field, value) in [("version", 2 as Any), ("id", UUID().uuidString as Any)] {
            let fixture = try fixture()
            let batch = try await fixture.seed()
            let savedDirectory = try await fixture.store.existingBatchDirectory(id: batch.id)
            let directory = try XCTUnwrap(savedDirectory)
            let manifest = directory.appendingPathComponent("manifest.json")
            let original = try Data(contentsOf: manifest)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            document[field] = value
            let changed = try JSONSerialization.data(withJSONObject: document)
            try changed.write(to: manifest, options: .atomic)

            await fixture.service.refreshPending(session: fixture.session)

            XCTAssertFalse(fixture.service.hasCurrentSnapshot)
            XCTAssertNotNil(fixture.service.lastError)
            XCTAssertEqual(try Data(contentsOf: manifest), changed)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shared.jpg")), Data("original".utf8))
        }
    }

    func testRefreshingInvalidatesProofBeforeListingWithoutDroppingKnownRows() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let batch = try await fixture.seed()
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        let gate = listGate()
        files.holdNextList(gate)
        let read = Task { await fixture.service.refreshPending(session: fixture.session) }
        addTeardownBlock { gate.release(); await read.value }
        await fulfillment(of: [gate.started], timeout: 2)

        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        gate.release()
        await read.value

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
    }

    func testRecoveryAdmissionInvalidatesThePreviousSnapshotSynchronously() async throws {
        let gate = FreshnessUploadGate()
        let fixture = try fixture(upload: { _, _, _, _ in await gate.wait() })
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        _ = try await fixture.seed()

        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        addTeardownBlock { await gate.release(); await work.value }
        XCTAssertFalse(fixture.service.hasCurrentSnapshot, "Recovery must revoke old proof before its task first runs")
        await fulfillment(of: [gate.started], timeout: 2)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item.state), [.uploading])
        gate.release()
        await work.value
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertTrue(fixture.service.items.isEmpty)
    }

    func testListingFailureKeepsKnownRowsButSuccessfulRefreshClearsOnlyThatError() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let batch = try await fixture.seed(state: .failed)
        await fixture.service.refreshPending(session: fixture.session)
        files.failNextList()

        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        XCTAssertNotNil(fixture.service.lastError)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
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

        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        XCTAssertNotNil(fixture.service.lastError)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
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
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertTrue(fixture.service.items.isEmpty, "The uploaded source needs cleanup, not another transfer")
        let saved = try await fixture.store.batch(id: batch.id, owner: batch.owner)
        XCTAssertEqual(saved?.items.first?.state, .uploaded)
        XCTAssertEqual(uploads, 1)
        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.lastError, processingError)
        files.failSourceRemoval = false
        let retry = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await retry.value
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertNil(fixture.service.lastError)
        XCTAssertEqual(uploads, 1, "The accepted item must only clean its original during recovery")
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCancelAndLiveSessionChangesInvalidateSnapshotProof() async throws {
        let fixture = try fixture()
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)

        fixture.session.owner = .init(server: fixture.session.owner.server, userID: "replacement")
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        fixture.session.testAuthHeaders = ["x-api-key": "replacement-token"]
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        fixture.session.isLoggedIn = false
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        fixture.session.cancelAuthentication()
        fixture.session.isLoggedIn = true
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        fixture.service.cancel()
        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
    }

    func testCanceledListingCannotRestoreSnapshotProof() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let batch = try await fixture.seed()
        await fixture.service.refreshPending(session: fixture.session)
        let gate = listGate()
        files.holdNextList(gate)
        let read = Task { await fixture.service.refreshPending(session: fixture.session) }
        addTeardownBlock { gate.release(); await read.value }
        await fulfillment(of: [gate.started], timeout: 2)
        read.cancel()
        gate.release()
        await read.value

        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        XCTAssertNil(fixture.service.lastError)
        await fixture.service.refreshPending(session: fixture.session)
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
    }

    func testAnOldAccountListingCannotCertifyTheReplacementOwnersInbox() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let oldBatch = try await fixture.seed()
        await fixture.service.refreshPending(session: fixture.session)
        let gate = listGate()
        files.holdNextList(gate)
        let oldRead = Task { await fixture.service.refreshPending(session: fixture.session) }
        addTeardownBlock { gate.release(); await oldRead.value }
        await fulfillment(of: [gate.started], timeout: 2)
        fixture.session.owner = .init(server: fixture.session.owner.server, userID: "replacement")
        gate.release()
        await oldRead.value

        XCTAssertFalse(fixture.service.hasCurrentSnapshot)
        let replacement = try await fixture.seed(state: .failed)
        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
        XCTAssertEqual(fixture.service.items.map(\.item), replacement.items)
        XCTAssertEqual(fixture.service.items.first?.owner, replacement.owner)
        let preserved = try await fixture.store.batch(id: oldBatch.id, owner: oldBatch.owner)
        XCTAssertEqual(preserved, oldBatch)
    }

    func testOlderListingCannotCertifyAnInboxWhileItsReplacementReadIsHeld() async throws {
        let files = FreshnessFiles()
        let fixture = try fixture(files: files)
        let firstGate = listGate()
        let secondGate = listGate()
        files.holdNextList(firstGate)
        files.holdNextList(secondGate)
        let first = Task { await fixture.service.refreshPending(session: fixture.session) }
        addTeardownBlock { firstGate.release(); secondGate.release(); await first.value }
        await fulfillment(of: [firstGate.started], timeout: 2)
        let launched = expectation(description: "A replacement refresh was admitted")
        let second = Task {
            launched.fulfill()
            await fixture.service.refreshPending(session: fixture.session)
        }
        addTeardownBlock { firstGate.release(); secondGate.release(); await second.value }
        await fulfillment(of: [launched], timeout: 2)
        firstGate.release()
        await fulfillment(of: [secondGate.started], timeout: 2)
        await first.value

        XCTAssertFalse(fixture.service.hasCurrentSnapshot, "The older empty result cannot certify the replacement read")
        secondGate.release()
        await second.value
        XCTAssertTrue(fixture.service.hasCurrentSnapshot)
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
