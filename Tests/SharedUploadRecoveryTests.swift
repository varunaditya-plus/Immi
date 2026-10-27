import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadRecoveryTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testSuccessIsDurableBeforeTheSourceIsRemoved() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued])
        let item = batch.items[0]
        fixture.files.observeDeletion(of: fixture.source(item, batch: batch), manifest: fixture.manifest(batch), itemID: item.id)
        var uploaded: [UUID] = []

        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { current, source, bodyDirectory in
            uploaded.append(current.id)
            let saved = try await fixture.reloadedBatch(batch)
            XCTAssertEqual(saved.items[0].state, .uploading)
            XCTAssertNil(saved.items[0].lastError)
            XCTAssertEqual(try? Data(contentsOf: source), fixture.bytes(item))
            XCTAssertEqual(bodyDirectory, fixture.directory(batch))
        })

        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertEqual(uploaded, [item.id])
        XCTAssertEqual(fixture.files.statesAtDeletion, [.uploaded])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFailureToPersistUploadingDoesNotStartTheNetworkOrDeleteTheSource() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued])
        fixture.files.failDirectoryWrites = true
        var calls = 0

        do {
            _ = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in calls += 1 })
            XCTFail("An upload must not start without a durable uploading checkpoint")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        XCTAssertEqual(calls, 0)
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved, batch)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(batch.items[0], batch: batch)), fixture.bytes(batch.items[0]))
    }

    func testFailureToPersistSuccessRetainsTheSourceAndTheInterruptedCheckpoint() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .queued])
        var uploaded: [UUID] = []

        do {
            _ = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
                uploaded.append(item.id)
                fixture.files.failDirectoryWrites = true
            })
            XCTFail("A failed completion checkpoint must stop cleanup and later uploads")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        XCTAssertEqual(uploaded, [batch.items[0].id])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploading, .queued])
        for item in batch.items {
            XCTAssertEqual(try? Data(contentsOf: fixture.source(item, batch: batch)), fixture.bytes(item))
        }
        fixture.files.failDirectoryWrites = false
        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, source, _ in
            uploaded.append(item.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        })
        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertEqual(uploaded, [batch.items[0].id, batch.items[0].id, batch.items[1].id])
    }

    func testCleanupFailureLeavesDurableSuccessAndRecoveryDoesNotUploadItAgain() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued])
        let source = fixture.source(batch.items[0], batch: batch)
        fixture.files.observeDeletion(of: source, manifest: fixture.manifest(batch), itemID: batch.items[0].id)
        fixture.files.blockRemoval(of: source)
        var uploads = 0

        do {
            _ = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in uploads += 1 })
            XCTFail("Cleanup failures must leave the completed manifest for a later pass")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(fixture.files.statesAtDeletion, [.uploaded])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items[0].state, .uploaded)
        XCTAssertEqual(try? Data(contentsOf: source), fixture.bytes(batch.items[0]))

        fixture.files.blockRemoval(of: nil)
        let reopened = SharedUploadProcessor(store: SharedUploadStore(rootURL: fixture.root))
        let result = try await reopened.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("A durable success needs cleanup only")
        })
        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCompletedRecordsWithMissingSourcesAreCleanupOnly() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.uploaded, .uploaded], missingSources: [0])
        var uploads = 0

        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in uploads += 1 })

        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertEqual(uploads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFailedCleanupOfACompletedItemDoesNotStarveAPendingUpload() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.uploaded, .queued])
        let retainedSource = fixture.source(batch.items[0], batch: batch)
        let pendingSource = fixture.source(batch.items[1], batch: batch)
        fixture.files.blockRemoval(of: retainedSource)
        var uploaded: [UUID] = []

        do {
            _ = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, source, _ in
                uploaded.append(item.id)
                XCTAssertEqual(try? Data(contentsOf: source), fixture.bytes(item))
            })
            XCTFail("An incomplete cleanup must remain visible after pending uploads finish")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertEqual(uploaded, [batch.items[1].id])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploaded, .uploaded])
        XCTAssertEqual(try? Data(contentsOf: retainedSource), fixture.bytes(batch.items[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingSource.path))

        fixture.files.blockRemoval(of: nil)
        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("Both accepted items need cleanup only on the next pass")
        })
        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory(batch).path))
    }

    func testMixedRecoveryRetriesOnlyIncompleteEntriesAndKeepsAcceptedReceipts() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.uploaded, .queued, .uploading], missingSources: [0])
        var uploaded: [UUID] = []
        var progress: [String] = []

        let first = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, source, _ in
            uploaded.append(item.id)
            XCTAssertEqual(try? Data(contentsOf: source), fixture.bytes(item))
            if item.id == batch.items[1].id { throw URLError(.notConnectedToInternet) }
        }, progress: { current, total in progress.append("\(current)/\(total)") })

        XCTAssertEqual(first, .finished(remaining: 1))
        XCTAssertEqual(uploaded, [batch.items[1].id, batch.items[2].id])
        XCTAssertEqual(progress, ["1/2", "2/2"])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploaded, .queued, .uploaded])
        XCTAssertNotNil(saved.items[1].lastError)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(batch.items[1], batch: batch)), fixture.bytes(batch.items[1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source(batch.items[2], batch: batch).path))

        uploaded.removeAll()
        progress.removeAll()
        let second = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
            uploaded.append(item.id)
            let checkpoint = try await fixture.reloadedBatch(batch)
            XCTAssertEqual(checkpoint.items[1].state, .uploading)
            XCTAssertNil(checkpoint.items[1].lastError)
        }, progress: { current, total in progress.append("\(current)/\(total)") })
        XCTAssertEqual(second, .finished(remaining: 0))
        XCTAssertEqual(uploaded, [batch.items[1].id])
        XCTAssertEqual(progress, ["1/1"])
        let remaining = try await fixture.store.batches(for: batch.owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFailureToPersistAnUploadErrorStopsThePassWithoutLosingSources() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .queued])
        var uploaded: [UUID] = []

        do {
            _ = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
                uploaded.append(item.id)
                fixture.files.failDirectoryWrites = true
                throw URLError(.timedOut)
            })
            XCTFail("An unsaved retry must not be reported as safely queued")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        XCTAssertEqual(uploaded, [batch.items[0].id])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploading, .queued])
        for item in batch.items {
            XCTAssertEqual(try? Data(contentsOf: fixture.source(item, batch: batch)), fixture.bytes(item))
        }
    }

    func testAnActiveProcessorPreventsAnotherStoreFromUploadingTheSameBatch() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued])
        let held = HeldSharedUpload()
        var uploads = 0
        let first = Task {
            try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
                uploads += 1
                try await held.value()
            })
        }
        defer { first.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        let before = try await fixture.reloadedBatch(batch)
        let contender = SharedUploadProcessor(store: SharedUploadStore(rootURL: fixture.root))
        var progressCalls = 0

        let result = try await contender.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in
            XCTFail("The extension and app must not upload the same claimed batch")
        }, progress: { _, _ in progressCalls += 1 })

        XCTAssertEqual(result, .busy)
        XCTAssertEqual(progressCalls, 0)
        let after = try await fixture.store.batch(id: batch.id, owner: batch.owner)
        XCTAssertEqual(after, before)
        held.finish()
        let completed = try await first.value
        XCTAssertEqual(completed, .finished(remaining: 0))
        XCTAssertEqual(uploads, 1)
    }

    func testCancelBeforeAdmissionDoesNotChangeTheManifestOrStartAnUpload() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued])
        var uploads = 0
        let work = Task {
            try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { _, _, _ in uploads += 1 })
        }
        work.cancel()

        do {
            _ = try await work.value
            XCTFail("A canceled pass must stop before claiming work")
        } catch is CancellationError {
            // Expected; no checkpoint or network work was admitted.
        }
        XCTAssertEqual(uploads, 0)
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved, batch)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(batch.items[0], batch: batch)), fixture.bytes(batch.items[0]))
    }

    func testAcceptedSuccessIsCheckpointedWhenCancellationArrivesDuringUpload() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .queued])
        let held = HeldSharedUpload()
        var uploaded: [UUID] = []
        let work = Task {
            try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
                uploaded.append(item.id)
                try await held.value()
            })
        }
        defer { work.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        work.cancel()
        held.finish()
        do {
            _ = try await work.value
            XCTFail("Cancellation must prevent the next item from starting")
        } catch is CancellationError {
            // The server response still requires a durable success receipt.
        }

        XCTAssertEqual(uploaded, [batch.items[0].id])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.uploaded, .queued])
        XCTAssertEqual(try? Data(contentsOf: fixture.source(batch.items[1], batch: batch)), fixture.bytes(batch.items[1]))
        uploaded.removeAll()
        let result = try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
            uploaded.append(item.id)
        })
        XCTAssertEqual(result, .finished(remaining: 0))
        XCTAssertEqual(uploaded, [batch.items[1].id])
    }

    func testCanceledUploadFailureIsSavedWithoutStartingTheNextItem() async throws {
        let fixture = try fixture()
        let batch = try await fixture.batch(states: [.queued, .queued])
        let held = HeldSharedUpload()
        var uploaded: [UUID] = []
        let work = Task {
            try await fixture.processor.process(batchID: batch.id, owner: batch.owner, upload: { item, _, _ in
                uploaded.append(item.id)
                try await held.value()
            })
        }
        defer { work.cancel(); held.cancelIfWaiting() }
        await fulfillment(of: [held.started], timeout: 2)
        work.cancel()
        held.finish(error: URLError(.cancelled))
        do {
            _ = try await work.value
            XCTFail("A canceled upload must stop the pass")
        } catch is CancellationError {
            // The interrupted item remains a durable retry.
        }

        XCTAssertEqual(uploaded, [batch.items[0].id])
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved.items.map(\.state), [.queued, .queued])
        XCTAssertNotNil(saved.items[0].lastError)
        XCTAssertEqual(saved.items[1], batch.items[1])
        for item in batch.items {
            XCTAssertEqual(try? Data(contentsOf: fixture.source(item, batch: batch)), fixture.bytes(item))
        }
    }

    func testMissingAndOtherOwnerBatchesCannotBeRecreatedOrUploaded() async throws {
        let fixture = try fixture()
        let missingID = UUID()
        let batch = try await fixture.batch(states: [.queued])
        let other = SharedUploadOwner(server: batch.owner.server, userID: "other-account")

        for (id, owner) in [(missingID, batch.owner), (batch.id, other)] {
            let result = try await fixture.processor.process(batchID: id, owner: owner, upload: { _, _, _ in
                XCTFail("A missing or differently owned manifest cannot authorize an upload")
            })
            XCTAssertEqual(result, .finished(remaining: 0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(missingID.uuidString).path))
        let saved = try await fixture.reloadedBatch(batch)
        XCTAssertEqual(saved, batch)
        XCTAssertEqual(try? Data(contentsOf: fixture.source(batch.items[0], batch: batch)), fixture.bytes(batch.items[0]))
    }

    private func fixture() throws -> RecoveryFixture {
        let fixture = try RecoveryFixture()
        directories.append(fixture.root)
        return fixture
    }
}

@MainActor
private final class RecoveryFixture {
    let root: URL
    let files = RecoveryFileManager()
    let store: SharedUploadStore
    let processor: SharedUploadProcessor
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-recovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SharedUploadStore(rootURL: root, fileManager: files)
        processor = SharedUploadProcessor(store: store)
    }

    func batch(states: [SharedUploadItemState], missingSources: Set<Int> = []) async throws -> SharedUploadBatch {
        let batch = SharedUploadBatch(id: UUID(),
            owner: SharedUploadOwner(server: "https://shared-recovery.example/api", userID: "share-user"),
            createdAt: now, items: states.enumerated().map { index, state in
                let id = UUID()
                return SharedUploadItem(id: id, filename: "shared-\(index).jpg", relativePath: "source-\(index).jpg",
                    contentType: "image/jpeg", byteCount: Int64("original-\(id.uuidString)".utf8.count), createdAt: now, modifiedAt: now,
                    state: state, lastError: state == .queued ? "Previous failure" : nil)
            })
        _ = try await store.makeBatchDirectory(id: batch.id)
        for (index, item) in batch.items.enumerated() where !missingSources.contains(index) {
            try bytes(item).write(to: source(item, batch: batch))
        }
        try await store.save(batch)
        return batch
    }

    func bytes(_ item: SharedUploadItem) -> Data { Data("original-\(item.id.uuidString)".utf8) }
    func directory(_ batch: SharedUploadBatch) -> URL { root.appendingPathComponent(batch.id.uuidString, isDirectory: true) }
    func manifest(_ batch: SharedUploadBatch) -> URL { directory(batch).appendingPathComponent("manifest.json") }
    func source(_ item: SharedUploadItem, batch: SharedUploadBatch) -> URL { directory(batch).appendingPathComponent(item.relativePath) }
    func reloadedBatch(_ batch: SharedUploadBatch) async throws -> SharedUploadBatch {
        let saved = try await SharedUploadStore(rootURL: root).batch(id: batch.id, owner: batch.owner)
        return try XCTUnwrap(saved, "The durable recovery manifest must still exist")
    }
}

private final class RecoveryFileManager: FileManager, @unchecked Sendable {
    private let stateLock = NSLock()
    private var failWrites = false
    private var blockedRemoval: URL?
    private var observedFile: URL?
    private var observedManifest: URL?
    private var observedItemID: UUID?
    private var deletionStates: [SharedUploadItemState?] = []

    var failDirectoryWrites: Bool {
        get { stateLock.withLock { failWrites } }
        set { stateLock.withLock { failWrites = newValue } }
    }
    var statesAtDeletion: [SharedUploadItemState?] { stateLock.withLock { deletionStates } }

    func blockRemoval(of url: URL?) { stateLock.withLock { blockedRemoval = url } }
    func observeDeletion(of source: URL, manifest: URL, itemID: UUID) {
        stateLock.withLock {
            observedFile = source
            observedManifest = manifest
            observedItemID = itemID
        }
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failDirectoryWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func removeItem(at url: URL) throws {
        let observed = stateLock.withLock { (observedFile, observedManifest, observedItemID, blockedRemoval) }
        if url == observed.0, let manifest = observed.1, let itemID = observed.2 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let batch = try? decoder.decode(SharedUploadBatch.self, from: Data(contentsOf: manifest))
            stateLock.withLock { deletionStates.append(batch?.items.first(where: { $0.id == itemID })?.state) }
        }
        if url == observed.3 { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

@MainActor
private final class HeldSharedUpload {
    let started = XCTestExpectation(description: "The production shared processor is awaiting an upload")
    private var continuation: CheckedContinuation<Void, Error>?

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(error: Error? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation else {
            return XCTFail("The upload did not reach its held boundary", file: file, line: line)
        }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func cancelIfWaiting() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
