import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadQueueActionTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testExplicitRetryChangesOnlyTheFailedItemAndItsNextUploadHasADurableCheckpoint() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed, .failed])
        let target = batch.items[0]
        let retried = try await fixture.store.retryFailedItem(id: target.id, batchID: batch.id, owner: batch.owner)
        XCTAssertTrue(retried)
        var expected = batch
        expected.items[0].state = .queued
        expected.items[0].lastError = nil
        let queued = try await fixture.saved(batch)
        XCTAssertEqual(queued, expected)
        for item in batch.items { XCTAssertEqual(try Data(contentsOf: fixture.source(item, in: batch)), fixture.bytes(item)) }
        var uploads: [UUID] = []

        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, file, _ in
            uploads.append(item.id)
            XCTAssertEqual(item.id, target.id)
            let checkpoint = try await fixture.saved(batch)
            XCTAssertEqual(checkpoint.items[0].state, .uploading)
            XCTAssertNil(checkpoint.items[0].lastError)
            XCTAssertEqual(checkpoint.items[1], batch.items[1])
            XCTAssertEqual(try Data(contentsOf: file), fixture.bytes(target))
        })

        XCTAssertEqual(result, .finished(remaining: 1))
        XCTAssertEqual(uploads, [target.id])
        let saved = try await fixture.saved(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploaded, .failed])
        XCTAssertEqual(saved.items[1], batch.items[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source(target, in: batch).path))
        XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[1], in: batch)), fixture.bytes(batch.items[1]))
    }

    func testRetryAndDiscardCannotChangeABatchWhileItsProcessorOwnsTheClaim() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .failed])
        let gate = QueueActionUploadGate()
        defer { gate.finish(error: CancellationError()) }
        let processing = Task {
            try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
                try await gate.wait()
            })
        }
        await fulfillment(of: [gate.started], timeout: 2)
        let manifest = try Data(contentsOf: fixture.manifest(batch))
        let competing = SharedUploadStore(rootURL: fixture.root)

        let retried = try await competing.retryFailedItem(id: batch.items[1].id, batchID: batch.id, owner: batch.owner)
        let discarded = try await competing.discardFailedItem(id: batch.items[1].id, batchID: batch.id, owner: batch.owner)

        XCTAssertFalse(retried)
        XCTAssertFalse(discarded)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), manifest)
        for item in batch.items { XCTAssertEqual(try Data(contentsOf: fixture.source(item, in: batch)), fixture.bytes(item)) }
        gate.finish(error: URLError(.notConnectedToInternet))
        let result = try await processing.value
        XCTAssertEqual(result, .finished(remaining: 2))
        let saved = try await fixture.saved(batch)
        XCTAssertEqual(saved.items[1], batch.items[1])
        let afterRelease = try await competing.retryFailedItem(id: batch.items[1].id, batchID: batch.id, owner: batch.owner)
        XCTAssertTrue(afterRelease, "A completed worker must release the claim for an explicit retry")
    }

    func testActionsRequireExactOwnerBatchItemAndSupportedManifestVersion() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed])
        let original = try Data(contentsOf: fixture.manifest(batch))
        let wrongUser = SharedUploadOwner(server: batch.owner.server, userID: "another-user")
        let wrongServer = SharedUploadOwner(server: "https://another.example/api", userID: batch.owner.userID)
        let missingBatch = UUID()
        for (id, batchID, owner) in [
            (batch.items[0].id, batch.id, wrongUser),
            (batch.items[0].id, batch.id, wrongServer),
            (UUID(), batch.id, batch.owner),
            (batch.items[0].id, missingBatch, batch.owner),
        ] {
            let retried = try await fixture.store.retryFailedItem(id: id, batchID: batchID, owner: owner)
            let discarded = try await fixture.store.discardFailedItem(id: id, batchID: batchID, owner: owner)
            XCTAssertFalse(retried)
            XCTAssertFalse(discarded)
            XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), original)
            XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[0], in: batch)), fixture.bytes(batch.items[0]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(missingBatch.uuidString).path))
        for mismatch in ["version", "batch ID"] {
            var unsupported = batch
            if mismatch == "version" { unsupported.version = 900 }
            else { unsupported = SharedUploadBatch(id: UUID(), owner: batch.owner, createdAt: batch.createdAt, items: batch.items) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(unsupported)
            try data.write(to: fixture.manifest(batch))

            let retried = try await fixture.store.retryFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
            let discarded = try await fixture.store.discardFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)

            XCTAssertFalse(retried, mismatch)
            XCTAssertFalse(discarded, mismatch)
            XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), data)
            XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[0], in: batch)), fixture.bytes(batch.items[0]))
        }
        try original.write(to: fixture.manifest(batch))
        let validRetry = try await fixture.store.retryFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
        XCTAssertTrue(validRetry, "A matching restored manifest must still be actionable")
    }

    func testQueuedUploadingUploadedAndDiscardedRowsCannotBeRetriedOrDiscardedAsFailures() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .uploading, .uploaded, .discarded])
        let original = try Data(contentsOf: fixture.manifest(batch))
        for item in batch.items {
            let retried = try await fixture.store.retryFailedItem(id: item.id, batchID: batch.id, owner: batch.owner)
            let discarded = try await fixture.store.discardFailedItem(id: item.id, batchID: batch.id, owner: batch.owner)
            XCTAssertFalse(retried)
            XCTAssertFalse(discarded)
            XCTAssertEqual(try Data(contentsOf: fixture.source(item, in: batch)), fixture.bytes(item))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), original)
    }

    func testDiscardIsDurableBeforeDeletingItsSourceAndKeepsAnotherFailureAndNeighborBatch() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed, .failed])
        let neighbor = try await fixture.batch(states: [.failed])
        let neighborManifest = try Data(contentsOf: fixture.manifest(neighbor))
        let target = batch.items[0]
        fixture.files.observe(source: fixture.source(target, in: batch), manifest: fixture.manifest(batch), itemID: target.id)

        let discarded = try await fixture.store.discardFailedItem(id: target.id, batchID: batch.id, owner: batch.owner)

        XCTAssertTrue(discarded)
        XCTAssertEqual(fixture.files.statesAtRemoval, [.discarded])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source(target, in: batch).path))
        let saved = try await fixture.saved(batch)
        XCTAssertEqual(saved.items.map(\.state), [.discarded, .failed])
        XCTAssertNil(saved.items[0].lastError)
        XCTAssertEqual(saved.items[1], batch.items[1])
        XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[1], in: batch)), fixture.bytes(batch.items[1]))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(neighbor)), neighborManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.source(neighbor.items[0], in: neighbor)), fixture.bytes(neighbor.items[0]))

        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("Discarded and failed rows cannot create a network request")
        })
        XCTAssertEqual(result, .finished(remaining: 1))
        let afterRecovery = try await fixture.saved(batch)
        XCTAssertEqual(afterRecovery, saved)
    }

    func testDiscardingLastFailureCleansCompletedBatchWithoutTouchingNeighbor() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed, .uploaded])
        let neighbor = try await fixture.batch(states: [.failed])
        let neighborManifest = try Data(contentsOf: fixture.manifest(neighbor))
        fixture.files.observe(source: fixture.source(batch.items[0], in: batch), manifest: fixture.manifest(batch), itemID: batch.items[0].id)

        let discarded = try await fixture.store.discardFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)

        XCTAssertTrue(discarded)
        XCTAssertEqual(fixture.files.statesAtRemoval, [.discarded])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(neighbor)), neighborManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.source(neighbor.items[0], in: neighbor)), fixture.bytes(neighbor.items[0]))
        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("A removed completed batch cannot upload")
        })
        XCTAssertEqual(result, .finished(remaining: 0))
    }

    func testFailedRetryCheckpointLeavesFailureAndSourceUnchangedAndBlocksNetworkUntilRetryPersists() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed])
        let original = try Data(contentsOf: fixture.manifest(batch))
        fixture.files.failWrites = true
        do {
            _ = try await fixture.store.retryFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
            XCTFail("A failed queued checkpoint cannot authorize another upload")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), original)
        XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[0], in: batch)), fixture.bytes(batch.items[0]))
        let blocked = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("The unchanged failed row must not upload automatically")
        })
        XCTAssertEqual(blocked, .finished(remaining: 1))
        fixture.files.failWrites = false
        let retried = try await fixture.store.retryFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
        XCTAssertTrue(retried)
        var uploads = 0
        let completed = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, file, _ in
            uploads += 1
            XCTAssertEqual(try Data(contentsOf: file), fixture.bytes(batch.items[0]))
        })
        XCTAssertEqual(completed, .finished(remaining: 0))
        XCTAssertEqual(uploads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
    }

    func testFailedDiscardCheckpointCannotDeleteTheSourceAndSuccessfulRetryStillWorks() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.failed])
        let original = try Data(contentsOf: fixture.manifest(batch))
        fixture.files.observe(source: fixture.source(batch.items[0], in: batch), manifest: fixture.manifest(batch), itemID: batch.items[0].id)
        fixture.files.failWrites = true
        do {
            _ = try await fixture.store.discardFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
            XCTFail("Discard must be durable before any source is removed")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(batch)), original)
        XCTAssertEqual(try Data(contentsOf: fixture.source(batch.items[0], in: batch)), fixture.bytes(batch.items[0]))
        XCTAssertTrue(fixture.files.statesAtRemoval.isEmpty)
        let blocked = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("A failed discard cannot accidentally requeue an upload")
        })
        XCTAssertEqual(blocked, .finished(remaining: 1))
        fixture.files.failWrites = false
        let discarded = try await fixture.store.discardFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
        XCTAssertTrue(discarded)
        XCTAssertEqual(fixture.files.statesAtRemoval, [.discarded])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
    }

    func testFailedSourceOrBatchCleanupLeavesADiscardReceiptAndReopenedProcessorNeverUploadsIt() async throws {
        for blockDirectory in [false, true] {
            let fixture = try fixture()
            let batch = try await fixture.batch(states: [.failed])
            let source = fixture.source(batch.items[0], in: batch)
            fixture.files.observe(source: source, manifest: fixture.manifest(batch), itemID: batch.items[0].id)
            fixture.files.blockedRemoval = blockDirectory ? fixture.directory(batch) : source
            do {
                _ = try await fixture.store.discardFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
                XCTFail("The configured source or batch cleanup must fail")
            } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
            XCTAssertEqual(fixture.files.statesAtRemoval, [.discarded])
            let saved = try await fixture.saved(batch)
            XCTAssertEqual(saved.items[0].state, .discarded)
            XCTAssertNil(saved.items[0].lastError)
            XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), !blockDirectory)
            if !blockDirectory { XCTAssertEqual(try Data(contentsOf: source), fixture.bytes(batch.items[0])) }
            let rejectedRetry = try await fixture.store.retryFailedItem(id: batch.items[0].id, batchID: batch.id, owner: batch.owner)
            XCTAssertFalse(rejectedRetry, "A durable discard cannot be converted back into an upload")
            fixture.files.blockedRemoval = nil
            let reopened = SharedUploadProcessor(store: SharedUploadStore(rootURL: fixture.root, fileManager: fixture.files))

            let result = try await reopened.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
                XCTFail("A durable discard is cleanup-only, including after relaunch")
            })

            XCTAssertEqual(result, .finished(remaining: 0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
        }
    }

    private func fixture() throws -> QueueActionFixture {
        let fixture = try QueueActionFixture()
        directories.append(fixture.root)
        return fixture
    }
}

@MainActor
private final class QueueActionFixture {
    let root: URL
    let files = QueueActionFileManager()
    let store: SharedUploadStore
    let processor: SharedUploadProcessor
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let owner = SharedUploadOwner(server: "https://queue-actions.example/api", userID: "queue-user")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedQueueActions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SharedUploadStore(rootURL: root, fileManager: files)
        processor = SharedUploadProcessor(store: store)
    }

    func batch(states: [SharedUploadItemState]) async throws -> SharedUploadBatch {
        let batch = SharedUploadBatch(id: UUID(), owner: owner, createdAt: now, items: states.enumerated().map { index, state in
            let id = UUID()
            return SharedUploadItem(id: id, filename: "source-\(index).jpg", relativePath: "source-\(index).jpg",
                contentType: "image/jpeg", byteCount: Int64("source-\(id.uuidString)".utf8.count),
                createdAt: now, modifiedAt: now, state: state, lastError: "saved-error-\(index)")
        })
        _ = try await store.makeBatchDirectory(id: batch.id)
        for item in batch.items { try bytes(item).write(to: source(item, in: batch)) }
        try await store.save(batch)
        return batch
    }
    func directory(_ batch: SharedUploadBatch) -> URL { root.appendingPathComponent(batch.id.uuidString) }
    func manifest(_ batch: SharedUploadBatch) -> URL { directory(batch).appendingPathComponent("manifest.json") }
    func source(_ item: SharedUploadItem, in batch: SharedUploadBatch) -> URL { directory(batch).appendingPathComponent(item.relativePath) }
    func bytes(_ item: SharedUploadItem) -> Data { Data("source-\(item.id.uuidString)".utf8) }
    func saved(_ batch: SharedUploadBatch) async throws -> SharedUploadBatch {
        let value = try await SharedUploadStore(rootURL: root).batch(id: batch.id, owner: batch.owner)
        return try XCTUnwrap(value)
    }
}

private final class QueueActionFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var writesBlocked = false
    private var removal: URL?
    private var observed: (source: URL, manifest: URL, itemID: UUID)?
    private var recorded: [SharedUploadItemState?] = []

    var failWrites: Bool {
        get { lock.withLock { writesBlocked } }
        set { lock.withLock { writesBlocked = newValue } }
    }
    var blockedRemoval: URL? {
        get { lock.withLock { removal } }
        set { lock.withLock { removal = newValue } }
    }
    var statesAtRemoval: [SharedUploadItemState?] { lock.withLock { recorded } }
    func observe(source: URL, manifest: URL, itemID: UUID) {
        lock.withLock { observed = (source, manifest, itemID) }
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    override func removeItem(at url: URL) throws {
        let observation = lock.withLock { observed }
        if let observation, url == observation.source {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try? decoder.decode(SharedUploadBatch.self, from: Data(contentsOf: observation.manifest))
            lock.withLock { recorded.append(value?.items.first { $0.id == observation.itemID }?.state) }
        }
        if blockedRemoval == url { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

@MainActor
private final class QueueActionUploadGate {
    let started = XCTestExpectation(description: "Shared upload owns its batch claim")
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        started.fulfill()
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(error: Error) {
        result = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
