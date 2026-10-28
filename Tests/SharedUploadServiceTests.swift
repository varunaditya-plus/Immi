import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadServiceTests: XCTestCase {
    private var directories: [URL] = []
    private let owner = SharedUploadOwner(server: "https://shared.example/api", userID: "one")

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testVisibleRowsExposeSavedErrorsForOnlyTheSignedInAccount() async throws {
        let fixture = try fixture()
        let batch = try await seed(fixture.store, states: [.failed, .queued, .uploaded, .discarded])
        _ = try await seed(fixture.store, states: [.failed],
                           owner: .init(server: owner.server, userID: "other"))

        await fixture.service.refreshPending(session: fixture.session)

        XCTAssertEqual(fixture.service.items.map(\.item.id), Array(batch.items.prefix(2)).map(\.id))
        XCTAssertEqual(fixture.service.items.first?.item.filename, "photo-0.jpg")
        XCTAssertEqual(fixture.service.items.first?.item.lastError, "HTTP 413: Original is too large")
        XCTAssertEqual(fixture.service.items.first?.owner, owner)
        XCTAssertEqual(fixture.service.items.first?.batchID, batch.id)
    }

    func testAutomaticRecoveryKeepsFailedRowsVisibleWithoutUploadingThem() async throws {
        let fixture = try fixture()
        let batch = try await seed(fixture.store, states: [.failed])
        let manifest = try await manifestBytes(fixture.store, batch: batch)

        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await work.value

        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
        let saved = try await manifestBytes(fixture.store, batch: batch)
        XCTAssertEqual(saved, manifest)
        XCTAssertNil(fixture.service.lastError)
    }

    func testSignedOutRecoveryReclaimsOnlyAnAbandonedDraftWithoutUploadingOrPublishingRows() async throws {
        let fixture = try fixture()
        let active = try await fixture.store.makeDraftDirectory(id: UUID())
        let activeSource = active.directory.appendingPathComponent("active.jpg")
        let bytes = Data("original media".utf8)
        try bytes.write(to: activeSource)
        let committed = try await seed(fixture.store, states: [.failed],
            owner: .init(server: owner.server, userID: "another-account"))
        let committedBytes = try await manifestBytes(fixture.store, batch: committed)
        let abandoned = try await fixture.store.makeBatchDirectory(id: UUID())
        try bytes.write(to: abandoned.appendingPathComponent("abandoned.jpg"))
        let old = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        for directory in [active.directory, abandoned, fixture.root.appendingPathComponent(committed.id.uuidString)] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandoned.path))
        fixture.session.isLoggedIn = false

        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await work.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: activeSource), bytes)
        let saved = try await manifestBytes(fixture.store, batch: committed)
        XCTAssertEqual(saved, committedBytes)
        let committedSource = try await fixture.store.fileURL(for: committed.items[0], batchID: committed.id)
        XCTAssertEqual(try Data(contentsOf: committedSource), bytes)
        XCTAssertTrue(fixture.service.items.isEmpty)
        XCTAssertNil(fixture.service.lastError)
        withExtendedLifetime(active.claim) {}
    }

    func testCanceledCallersCannotClearRowsOrStartARecoveryWorker() async throws {
        let fixture = try fixture()
        let batch = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let rows = fixture.service.items
        fixture.session.isLoggedIn = false
        let refresh = Task { await fixture.service.refreshPending(session: fixture.session) }
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(fixture.service.items, rows)

        fixture.session.isLoggedIn = true
        let start = Task { fixture.service.processPending(session: fixture.session) }
        start.cancel()
        let admitted = await start.value
        XCTAssertNil(admitted)
        let saved = try await fixture.store.batch(id: batch.id, owner: owner)
        XCTAssertEqual(saved, batch)
    }

    func testExplicitRetryUploadsOnlyItsSelectedFailureAndKeepsTheOtherError() async throws {
        let gate = makeGate()
        var uploaded: [UUID] = []
        let fixture = try fixture(upload: { credential, item, file, _ in
            XCTAssertEqual(credential.owner, self.owner)
            XCTAssertEqual(try Data(contentsOf: file), Data("original media".utf8))
            uploaded.append(item.id)
            await gate.wait()
        })
        let batch = try await seed(fixture.store, states: [.failed, .failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first)

        try await fixture.service.retry(entry, session: fixture.session)
        await fulfillment(of: [gate.started], timeout: 2)
        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        let stored = try await fixture.store.batch(id: batch.id, owner: owner)
        let checkpoint = try XCTUnwrap(stored)
        XCTAssertEqual(checkpoint.items[0].state, .uploading)
        XCTAssertNil(checkpoint.items[0].lastError)
        XCTAssertEqual(checkpoint.items[1], batch.items[1])
        gate.resolve()
        await work.value

        XCTAssertEqual(uploaded, [entry.item.id])
        XCTAssertEqual(fixture.service.items.map(\.item), [batch.items[1]])
        XCTAssertEqual(fixture.service.items.first?.item.lastError, batch.items[1].lastError)
    }

    func testRetryRequestedDuringAnotherBatchRunsAfterTheCurrentPass() async throws {
        let first = makeGate()
        let retried = makeGate()
        var uploaded: [UUID] = []
        let fixture = try fixture(upload: { _, item, _, _ in
            uploaded.append(item.id)
            await (uploaded.count == 1 ? first : retried).wait()
        })
        let initial = try await seed(fixture.store, states: [.queued])
        let firstWork = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await fulfillment(of: [first.started], timeout: 2)
        // This batch was not in the original recovery pass's list.
        let later = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first { $0.batchID == later.id })
        try await fixture.service.retry(entry, session: fixture.session)
        XCTAssertEqual(uploaded, [initial.items[0].id])

        first.resolve()
        await firstWork.value
        await fulfillment(of: [retried.started], timeout: 2)
        let nextWork = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        retried.resolve()
        await nextWork.value

        XCTAssertEqual(uploaded, [initial.items[0].id, later.items[0].id])
        XCTAssertTrue(fixture.service.items.isEmpty)
        let batches = try await fixture.store.batches(for: owner)
        XCTAssertTrue(batches.isEmpty)
    }

    func testFailedRetryCheckpointNeverStartsAnUpload() async throws {
        let files = ServiceFaultingFiles()
        let fixture = try fixture(files: files)
        let batch = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first)
        let before = try await manifestBytes(fixture.store, batch: batch)
        files.failWrites = true

        do {
            try await fixture.service.retry(entry, session: fixture.session)
            XCTFail("Network work requires a durable retry checkpoint")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        let after = try await manifestBytes(fixture.store, batch: batch)
        XCTAssertEqual(after, before)
        XCTAssertEqual(fixture.service.items.map(\.item), batch.items)
    }

    func testBusyBatchRejectsRetryAndRemovalWithoutChangingTheOriginal() async throws {
        let fixture = try fixture()
        let batch = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first)
        let claim = try await SharedUploadStore(rootURL: fixture.root).claimBatch(id: batch.id)
        XCTAssertNotNil(claim)
        let before = try await manifestBytes(fixture.store, batch: batch)

        do { try await fixture.service.retry(entry, session: fixture.session); XCTFail("The batch is claimed") }
        catch SharedUploadActionError.unavailable {}
        do { try await fixture.service.remove(entry, session: fixture.session); XCTFail("The batch is claimed") }
        catch SharedUploadActionError.unavailable {}

        let after = try await manifestBytes(fixture.store, batch: batch)
        XCTAssertEqual(after, before)
        let source = try await fixture.store.fileURL(for: entry.item, batchID: batch.id)
        XCTAssertEqual(try Data(contentsOf: source), Data("original media".utf8))
        withExtendedLifetime(claim) {}
    }

    func testRemovingOneFailureUpdatesVisibleRowsAndPreservesTheOtherBatch() async throws {
        let fixture = try fixture()
        let removed = try await seed(fixture.store, states: [.failed])
        let retained = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first { $0.batchID == removed.id })

        try await fixture.service.remove(entry, session: fixture.session)

        XCTAssertEqual(fixture.service.items.map(\.batchID), [retained.id])
        let gone = try await fixture.store.batch(id: removed.id, owner: owner)
        let kept = try await fixture.store.batch(id: retained.id, owner: owner)
        XCTAssertNil(gone)
        XCTAssertEqual(kept, retained)
    }

    func testStaleAccountActionsCannotRetryOrRemoveThePreviousAccountsItem() async throws {
        let fixture = try fixture()
        let batch = try await seed(fixture.store, states: [.failed])
        await fixture.service.refreshPending(session: fixture.session)
        let entry = try XCTUnwrap(fixture.service.items.first)
        fixture.session.owner = BackupQueueOwner(server: owner.server, userID: "two")
        await fixture.service.refreshPending(session: fixture.session)

        do { try await fixture.service.retry(entry, session: fixture.session); XCTFail("The owner changed") }
        catch is CancellationError {}
        do { try await fixture.service.remove(entry, session: fixture.session); XCTFail("The owner changed") }
        catch is CancellationError {}

        let saved = try await fixture.store.batch(id: batch.id, owner: owner)
        XCTAssertEqual(saved, batch)
        XCTAssertTrue(fixture.service.items.isEmpty)
    }

    func testLateAcceptedUploadCannotRestoreRowsAfterCancellationAndAccountChange() async throws {
        let gate = makeGate()
        let fixture = try fixture(upload: { _, _, _, _ in await gate.wait() })
        let old = try await seed(fixture.store, states: [.queued])
        let work = try XCTUnwrap(fixture.service.processPending(session: fixture.session))
        await fulfillment(of: [gate.started], timeout: 2)
        fixture.service.cancel()
        XCTAssertTrue(fixture.service.items.isEmpty)
        fixture.session.owner = BackupQueueOwner(server: owner.server, userID: "two")
        let nextOwner = SharedUploadOwner(server: owner.server, userID: "two")
        let next = try await seed(fixture.store, states: [.failed], owner: nextOwner)
        await fixture.service.refreshPending(session: fixture.session)

        gate.resolve()
        await work.value

        XCTAssertEqual(fixture.service.items.map(\.item), next.items)
        XCTAssertEqual(fixture.service.items.first?.owner, nextOwner)
        let completed = try await fixture.store.batch(id: old.id, owner: owner)
        XCTAssertNil(completed, "An accepted response still needs its old owner's durable success and cleanup")
    }

    private func fixture(
        files: FileManager = .default,
        upload: @escaping @MainActor (SharedUploadCredential, SharedUploadItem, URL, URL) async throws -> Void = {
            _, _, _, _ in XCTFail("This path must not start a transfer")
        }
    ) throws -> (root: URL, store: SharedUploadStore, service: SharedUploadService, session: QueueTestSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-service-\(UUID())")
        directories.append(root)
        let store = SharedUploadStore(rootURL: root, fileManager: files)
        let service = SharedUploadService(store: store, upload: upload)
        addTeardownBlock { await service.cancel() }
        let session = QueueTestSession()
        try session.setServer(owner.server)
        session.owner = BackupQueueOwner(server: owner.server, userID: owner.userID)
        session.isLoggedIn = true
        session.testAuthHeaders = ["x-api-key": "shared-test-key"]
        return (root, store, service, session)
    }

    private func seed(
        _ store: SharedUploadStore, states: [SharedUploadItemState], owner: SharedUploadOwner? = nil
    ) async throws -> SharedUploadBatch {
        let id = UUID()
        let directory = try await store.makeBatchDirectory(id: id)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = try states.enumerated().map { index, state in
            let path = "photo-\(index).jpg"
            try Data("original media".utf8).write(to: directory.appendingPathComponent(path))
            return SharedUploadItem(id: UUID(), filename: path, relativePath: path,
                contentType: "image/jpeg", byteCount: 14, createdAt: date, modifiedAt: date,
                state: state, lastError: state == .failed ? "HTTP 413: Original is too large" : nil)
        }
        let batch = SharedUploadBatch(id: id, owner: owner ?? self.owner, createdAt: date, items: items)
        try await store.save(batch)
        return batch
    }

    private func manifestBytes(_ store: SharedUploadStore, batch: SharedUploadBatch) async throws -> Data {
        let existing = try await store.existingBatchDirectory(id: batch.id)
        let directory = try XCTUnwrap(existing)
        return try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    }

    private func makeGate() -> ServiceUploadGate {
        let gate = ServiceUploadGate()
        addTeardownBlock { await gate.resolve() }
        return gate
    }
}

@MainActor
private final class QueueTestSession: MockSessionManager {
    var owner: BackupQueueOwner?
    override var backupQueueOwner: BackupQueueOwner? { owner }
}

@MainActor
private final class ServiceUploadGate {
    let started = XCTestExpectation(description: "A real recovery transfer reached its response boundary")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }

    func resolve() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ServiceFaultingFiles: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    var failWrites: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
