import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadSubmissionTests: XCTestCase {
    func testClosingAnUncommittedDraftDeletesItsFilesAndKeepsAnotherBatch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let otherID = UUID()
        let otherDirectory = try await fixture.store.makeBatchDirectory(id: otherID)
        let otherFile = otherDirectory.appendingPathComponent("other.jpg")
        try Data("other source".utf8).write(to: otherFile)

        let closed = try await fixture.submission.close()

        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertEqual(try? Data(contentsOf: otherFile), Data("other source".utf8))
        XCTAssertTrue(fixture.submission.isClosing)
        XCTAssertFalse(fixture.submission.begin())
        XCTAssertFalse(fixture.submission.canEdit)
        let repeatedClose = try await fixture.submission.close()
        XCTAssertFalse(repeatedClose)
    }

    func testClosingACommittedSubmissionPreservesItsManifestAndSourcesExactly() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.submission.begin())
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        fixture.submission.finish()
        let manifest = try Data(contentsOf: fixture.manifestURL)

        XCTAssertTrue(fixture.submission.isCommitted)
        XCTAssertFalse(fixture.submission.canEdit)
        XCTAssertFalse(fixture.submission.begin(), "Committed files belong to recovery and cannot be resubmitted as a draft")
        let closed = try await fixture.submission.close()

        XCTAssertTrue(closed)
        XCTAssertEqual(try? Data(contentsOf: fixture.manifestURL), manifest)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let batches = try await reopened.batches(for: fixture.owner)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.id, fixture.submission.batchID)
        XCTAssertEqual(batches.first?.items, [fixture.item])
    }

    func testAdmissionReclaimsUnselectedOriginalsWhilePreservingFailedSelectedWork() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let unselected = fixture.directory.appendingPathComponent("unselected.mov")
        try Data("unselected original".utf8).write(to: unselected)
        let otherID = UUID()
        let otherDirectory = try await fixture.store.makeBatchDirectory(id: otherID)
        let otherFile = otherDirectory.appendingPathComponent("other.jpg")
        let otherSource = Data("other source".utf8)
        try otherSource.write(to: otherFile)

        XCTAssertTrue(fixture.submission.begin())
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unselected.path),
            "An imported original that was not selected has no durable upload intent")
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)

        let outcome = try await SharedUploadProcessor(store: fixture.store).process(
            batchID: fixture.submission.batchID, owner: fixture.owner,
            upload: { _, _, _ in throw SharedUploadClientError.server(status: 400, message: "Rejected photo") })
        guard case .finished(let remaining) = outcome else {
            return XCTFail("The released draft claim must allow processing")
        }
        XCTAssertEqual(remaining, 1)
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let saved = try await reopened.batch(id: fixture.submission.batchID, owner: fixture.owner)
        let batch = try XCTUnwrap(saved)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(batch.items.first?.id, fixture.item.id)
        XCTAssertEqual(batch.items.first?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertEqual(try Data(contentsOf: otherFile), otherSource)
        let closed = try await fixture.submission.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
    }

    func testAdmissionPreservesDirectoriesSymlinksAndLockFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let nested = fixture.directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("nested.jpg")
        try Data("nested source".utf8).write(to: nestedFile)
        let outside = fixture.rootURL.appendingPathComponent("outside.jpg")
        try Data("outside source".utf8).write(to: outside)
        let link = fixture.directory.appendingPathComponent("outside-link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let lock = fixture.directory.appendingPathComponent(".other.lock")
        try Data("lock file".utf8).write(to: lock)

        XCTAssertTrue(fixture.submission.begin())
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        fixture.submission.finish()

        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertEqual(try Data(contentsOf: nestedFile), Data("nested source".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside source".utf8))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: lock), Data("lock file".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".processing.lock").path))
    }

    func testFailedUnselectedCleanupRecoversWithoutRetryingATerminalUpload() async throws {
        let files = FaultingFileManager()
        let fixture = try await Fixture(fileManager: files)
        defer { fixture.cleanup() }
        let unselected = fixture.directory.appendingPathComponent("unselected.mov")
        try Data("unselected source".utf8).write(to: unselected)
        XCTAssertTrue(fixture.submission.begin())
        files.failure = .remove
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))

        do {
            _ = try await SharedUploadProcessor(store: fixture.store).process(
                batchID: fixture.submission.batchID, owner: fixture.owner,
                upload: { _, _, _ in throw SharedUploadClientError.server(status: 400, message: "Rejected") })
            XCTFail("Failed file cleanup must remain visible after the upload checkpoint")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
        let failed = try await fixture.store.batch(id: fixture.submission.batchID, owner: fixture.owner)
        XCTAssertEqual(failed?.items.first?.state, .failed)

        files.failure = nil
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let outcome = try await SharedUploadProcessor(store: reopened).process(
            batchID: fixture.submission.batchID, owner: fixture.owner,
            upload: { _, _, _ in XCTFail("Cleaning unused originals must not retry a terminal upload") })

        XCTAssertEqual(outcome, .finished(remaining: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unselected.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
        let retained = try await reopened.batch(id: fixture.submission.batchID, owner: fixture.owner)
        XCTAssertEqual(retained, failed)
    }

    func testUnselectedCleanupKeepsTheAdmissionClaimUntilFilesAreRemoved() async throws {
        let files = HeldRemoveFileManager()
        let fixture = try await Fixture(fileManager: files)
        defer { fixture.cleanup() }
        let unselected = fixture.directory.appendingPathComponent("unselected.mov")
        try Data("unselected source".utf8).write(to: unselected)
        XCTAssertTrue(fixture.submission.begin())
        files.holdNextRemove()
        let admission = Task { try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item]) }
        await fulfillment(of: [files.started], timeout: 2)
        defer { files.release.signal() }
        let competitor = SharedUploadStore(rootURL: fixture.rootURL)
        let whileCleaning = try await competitor.claimBatch(id: fixture.submission.batchID)
        XCTAssertNil(whileCleaning, "Another processor must not create upload bodies while admission is pruning files")
        XCTAssertTrue(fixture.submission.isCommitted)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)

        files.release.signal()
        try await admission.value
        fixture.submission.finish()
        let afterCleaning = try await competitor.claimBatch(id: fixture.submission.batchID)
        XCTAssertNotNil(afterCleaning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unselected.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.source)
        withExtendedLifetime(afterCleaning) {}
    }

    func testSynchronousBeginRejectsAnotherSubmitAndCloseUntilProcessingFinishes() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.submission.canEdit)
        XCTAssertTrue(fixture.submission.begin())

        XCTAssertTrue(fixture.submission.isProcessing)
        XCTAssertFalse(fixture.submission.begin())
        XCTAssertFalse(fixture.submission.canEdit)
        let closedWhileProcessing = try await fixture.submission.close()
        XCTAssertFalse(closedWhileProcessing)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        fixture.submission.finish()
        XCTAssertFalse(fixture.submission.isProcessing)
        XCTAssertTrue(fixture.submission.canEdit)
        XCTAssertTrue(fixture.submission.begin(), "A pre-admission failure should leave a retryable draft")
        fixture.submission.finish()
        let closedAfterFinishing = try await fixture.submission.close()
        XCTAssertTrue(closedAfterFinishing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testFailedInitialAdmissionLeavesADraftThatCanBeDiscarded() async throws {
        let fileManager = FaultingFileManager()
        let fixture = try await Fixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        let unselected = fixture.directory.appendingPathComponent("unselected.mov")
        try Data("unselected source".utf8).write(to: unselected)
        XCTAssertTrue(fixture.submission.begin())
        fileManager.failure = .create

        do {
            try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
            XCTFail("Admission must report the failed manifest write")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        fixture.submission.finish()
        XCTAssertFalse(fixture.submission.isCommitted)
        XCTAssertTrue(fixture.submission.canEdit)
        let competitor = SharedUploadStore(rootURL: fixture.rootURL)
        let stillClaimed = try await competitor.claimBatch(id: fixture.submission.batchID)
        XCTAssertNil(stillClaimed, "A failed admission must remain protected as an active draft")
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertEqual(try Data(contentsOf: unselected), Data("unselected source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        fileManager.failure = nil
        let closed = try await fixture.submission.close()
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testCheckpointFailureAfterAdmissionCannotMakeCloseDeleteCommittedWork() async throws {
        let fileManager = FaultingFileManager()
        let fixture = try await Fixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.submission.begin())
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        let manifest = try Data(contentsOf: fixture.manifestURL)
        var batches = try await fixture.store.batches(for: fixture.owner)
        var batch = try XCTUnwrap(batches.popLast())
        batch.items[0].state = .uploading
        fileManager.failure = .create

        do {
            try await fixture.store.save(batch)
            XCTFail("A failed checkpoint must not replace the committed manifest")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        XCTAssertFalse(fixture.submission.canEdit)
        let closed = try await fixture.submission.close()

        XCTAssertTrue(closed)
        XCTAssertEqual(try? Data(contentsOf: fixture.manifestURL), manifest)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
    }

    func testFailedDraftCleanupRestoresTheCloseAndSubmitGates() async throws {
        let fileManager = FaultingFileManager()
        let fixture = try await Fixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        fileManager.failure = .remove

        do {
            _ = try await fixture.submission.close()
            XCTFail("Failed cleanup must leave the draft open")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertFalse(fixture.submission.isClosing)
        XCTAssertTrue(fixture.submission.canEdit)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertTrue(fixture.submission.begin())
        fixture.submission.finish()
        fileManager.failure = nil
        let closed = try await fixture.submission.close()
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testAdmissionWithoutBeginCannotCommitFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
            XCTFail("An unclaimed submission cannot enter the inbox")
        } catch SharedUploadSubmissionError.invalidState {
            // The production admission gate rejected the call.
        }

        XCTAssertFalse(fixture.submission.isCommitted)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        XCTAssertTrue(fixture.submission.begin())
        try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let batches = try await reopened.batches(for: fixture.owner)
        XCTAssertEqual(batches.first?.items, [fixture.item])
    }

    func testPendingDraftPreparationRejectsSubmitAndCloseUntilItsClaimIsOwned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftPreparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = HeldCreateFileManager()
        let store = SharedUploadStore(rootURL: root, fileManager: files)
        let submission = SharedUploadSubmission(store: store)
        files.holdNextCreate()
        let preparing = Task { try await submission.prepareDraft() }
        await fulfillment(of: [files.started], timeout: 2)
        defer { files.release.signal() }

        XCTAssertTrue(submission.isProcessing)
        XCTAssertFalse(submission.begin())
        XCTAssertFalse(submission.canEdit)
        let closedWhilePreparing = try await submission.close()
        XCTAssertFalse(closedWhilePreparing)
        files.release.signal()
        let directory = try await preparing.value
        XCTAssertEqual(directory.lastPathComponent, submission.batchID.uuidString)
        XCTAssertTrue(submission.canEdit)
        let competitor = SharedUploadStore(rootURL: root)
        let protected = try await competitor.claimBatch(id: submission.batchID)
        XCTAssertNil(protected)

        let closed = try await submission.close()
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPendingAdmissionRejectsDoubleSubmitAndCloseBeforeItsWriteCompletes() async throws {
        let fileManager = HeldCreateFileManager()
        let fixture = try await Fixture(fileManager: fileManager)
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.submission.begin())
        fileManager.holdNextCreate()
        let admission = Task {
            try await fixture.submission.admit(owner: fixture.owner, items: [fixture.item])
        }
        await fulfillment(of: [fileManager.started], timeout: 2)
        defer { fileManager.release.signal() }

        XCTAssertTrue(fixture.submission.isProcessing)
        XCTAssertFalse(fixture.submission.isCommitted, "The manifest write is still held")
        XCTAssertFalse(fixture.submission.begin())
        XCTAssertFalse(fixture.submission.canEdit)
        let closed = try await fixture.submission.close()
        XCTAssertFalse(closed)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        let competitor = SharedUploadStore(rootURL: fixture.rootURL)
        let heldClaim = try await competitor.claimBatch(id: fixture.submission.batchID)
        XCTAssertNil(heldClaim, "The initial claim must cover the held manifest write")

        fileManager.release.signal()
        try await admission.value
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        let admittedClaim = try await competitor.claimBatch(id: fixture.submission.batchID)
        XCTAssertNotNil(admittedClaim, "Durable admission releases the draft to the recovery processor")
        let finalClose = try await fixture.submission.close()
        XCTAssertTrue(finalClose)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let batches = try await reopened.batches(for: fixture.owner)
        XCTAssertEqual(batches.first?.items, [fixture.item])
        withExtendedLifetime(admittedClaim) {}
    }

    @MainActor
    private final class Fixture {
        let rootURL: URL
        let directory: URL
        let sourceURL: URL
        let manifestURL: URL
        let source = Data("image".utf8)
        let owner = SharedUploadOwner(server: "https://share.example/api", userID: "user")
        let store: SharedUploadStore
        let submission: SharedUploadSubmission
        let item: SharedUploadItem

        init(fileManager: FileManager = .default) async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShareSubmission-\(UUID().uuidString)", isDirectory: true)
            let store = SharedUploadStore(rootURL: rootURL, fileManager: fileManager)
            let submission = SharedUploadSubmission(store: store)
            let directory = rootURL.appendingPathComponent(submission.batchID.uuidString, isDirectory: true)
            self.rootURL = rootURL
            self.store = store
            self.submission = submission
            self.directory = directory
            sourceURL = directory.appendingPathComponent("shared.jpg")
            manifestURL = directory.appendingPathComponent("manifest.json")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            item = SharedUploadItem(id: UUID(), filename: "shared.jpg", relativePath: "shared.jpg",
                contentType: "image/jpeg", byteCount: 5, createdAt: now, modifiedAt: now,
                state: .queued, lastError: nil)
            _ = try await submission.prepareDraft()
            try source.write(to: sourceURL)
        }

        func cleanup() { try? FileManager.default.removeItem(at: rootURL) }
    }
}

private final class FaultingFileManager: FileManager, @unchecked Sendable {
    enum Operation { case create, remove }
    private let lock = NSLock()
    private var operation: Operation?
    var failure: Operation? {
        get { lock.withLock { operation } }
        set { lock.withLock { operation = newValue } }
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failure == .create { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func removeItem(at URL: URL) throws {
        if failure == .remove { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}

private final class HeldCreateFileManager: FileManager, @unchecked Sendable {
    let started = XCTestExpectation(description: "The real store is waiting to write admission")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldHold = false

    func holdNextCreate() { lock.withLock { shouldHold = true } }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        let held = lock.withLock {
            let held = shouldHold
            shouldHold = false
            return held
        }
        if held {
            started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class HeldRemoveFileManager: FileManager, @unchecked Sendable {
    let started = XCTestExpectation(description: "The committed draft is pruning an unselected original")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldHold = false

    func holdNextRemove() { lock.withLock { shouldHold = true } }

    override func removeItem(at url: URL) throws {
        let held = lock.withLock {
            let held = shouldHold
            shouldHold = false
            return held
        }
        if held {
            started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
        try super.removeItem(at: url)
    }
}
