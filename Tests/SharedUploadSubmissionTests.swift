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
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
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

        fileManager.release.signal()
        try await admission.value
        fixture.submission.finish()
        XCTAssertTrue(fixture.submission.isCommitted)
        let finalClose = try await fixture.submission.close()
        XCTAssertTrue(finalClose)
        XCTAssertEqual(try? Data(contentsOf: fixture.sourceURL), fixture.source)
        let reopened = SharedUploadStore(rootURL: fixture.rootURL)
        let batches = try await reopened.batches(for: fixture.owner)
        XCTAssertEqual(batches.first?.items, [fixture.item])
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
            _ = try await store.makeBatchDirectory(id: submission.batchID)
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
