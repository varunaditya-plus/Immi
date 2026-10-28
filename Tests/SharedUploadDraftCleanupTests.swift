import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class SharedUploadDraftCleanupTests: XCTestCase {
    private var directories: [URL] = []
    private let now = Date()
    private let source = Data("original shared media".utf8)

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testOldAbandonedDraftIsRemovedWhenAnotherShareStarts() async throws {
        let fixture = try fixture()
        let abandoned = try await draft(in: fixture.store)
        try age(abandoned.directory)
        let nextID = UUID()

        let next = try await fixture.store.makeDraftDirectory(id: nextID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.directory.path))
        let competitor = SharedUploadStore(rootURL: fixture.root)
        let busy = try await competitor.claimBatch(id: nextID)
        XCTAssertNil(busy, "A new draft must be claimed before its source files are imported")
        withExtendedLifetime(next.claim) {}
    }

    func testYoungDraftAndUnrelatedFilesAndOutsideDirectoryArePreserved() async throws {
        let fixture = try fixture()
        let young = try await draft(in: fixture.store)
        let unknown = fixture.root.appendingPathComponent("not-a-batch")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let unknownSource = unknown.appendingPathComponent("keep.jpg")
        try source.write(to: unknownSource)
        try age(unknown)
        let loose = fixture.root.appendingPathComponent("loose-file")
        try source.write(to: loose)
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("OutsideDraft-\(UUID())")
        directories.append(outside)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideSource = outside.appendingPathComponent("keep.jpg")
        try source.write(to: outsideSource)
        try age(outside)
        let link = fixture.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let removed = try await fixture.store.cleanupAbandonedDrafts(now: now)

        XCTAssertEqual(removed, 0)
        for url in [young.source, unknownSource, loose, outsideSource] {
            XCTAssertEqual(try Data(contentsOf: url), source)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(".processing.lock").path))
    }

    func testAnyManifestPreservesItsOriginalsIncludingMalformedUnsupportedAndOtherOwner() async throws {
        let fixture = try fixture()
        var protected: [(directory: URL, source: URL, manifest: URL, bytes: Data)] = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for kind in 0..<3 {
            let staged = try await draft(in: fixture.store)
            let manifest = staged.directory.appendingPathComponent("manifest.json")
            let bytes: Data
            if kind == 0 { bytes = Data("{ interrupted or unknown manifest".utf8) }
            else {
                var batch = batch(id: staged.id, owner: .init(server: "https://other.example/api", userID: "other-user"))
                if kind == 1 { batch.version = 900 }
                bytes = try encoder.encode(batch)
            }
            try bytes.write(to: manifest)
            try age(staged.directory)
            protected.append((staged.directory, staged.source, manifest, bytes))
        }

        let removed = try await SharedUploadStore(rootURL: fixture.root).cleanupAbandonedDrafts(now: now)

        XCTAssertEqual(removed, 0)
        for staged in protected {
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.directory.path))
            XCTAssertEqual(try Data(contentsOf: staged.source), source)
            XCTAssertEqual(try Data(contentsOf: staged.manifest), staged.bytes)
        }
    }

    func testAnOldClaimedDraftSurvivesIndependentCleanupAndExpiresAfterItsClaimIsReleased() async throws {
        let fixture = try fixture()
        let id = UUID()
        var active: (directory: URL, claim: SharedUploadBatchClaim)? = try await fixture.store.makeDraftDirectory(id: id)
        let directory = try XCTUnwrap(active?.directory)
        let original = directory.appendingPathComponent("active.jpg")
        try source.write(to: original)
        try age(directory)
        let competitor = SharedUploadStore(rootURL: fixture.root)

        let blocked = try await competitor.cleanupAbandonedDrafts(now: now)
        XCTAssertEqual(blocked, 0)
        XCTAssertEqual(try Data(contentsOf: original), source)
        withExtendedLifetime(active) {}
        active = nil
        let removed = try await competitor.cleanupAbandonedDrafts(now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAbandonedSubmissionReleasesItsDraftClaimForNextLaunchCleanup() async throws {
        let fixture = try fixture()
        var submission: SharedUploadSubmission? = SharedUploadSubmission(store: fixture.store)
        let id = try XCTUnwrap(submission?.batchID)
        let directory = try await XCTUnwrap(submission).prepareDraft()
        let original = directory.appendingPathComponent("partially-imported.jpg")
        try source.write(to: original)
        try age(directory)
        let competitor = SharedUploadStore(rootURL: fixture.root)
        let whileAlive = try await competitor.cleanupAbandonedDrafts(now: now)
        XCTAssertEqual(whileAlive, 0)
        XCTAssertEqual(try Data(contentsOf: original), source)
        submission = nil // The OS also closes this descriptor on process death.

        let removed = try await competitor.cleanupAbandonedDrafts(now: now)

        XCTAssertEqual(removed, 1)
        let remaining = try await competitor.existingBatchDirectory(id: id)
        XCTAssertNil(remaining)
    }

    func testManifestAppearingBeforeClaimIsRecheckedAndNeverDeleted() async throws {
        let files = ManifestRaceFileManager()
        let fixture = try fixture(files: files)
        let staged = try await draft(in: fixture.store)
        try age(staged.directory)
        let manifest = staged.directory.appendingPathComponent("manifest.json")
        let committed = Data("durable manifest admitted by another process".utf8)
        files.publishAfterFirstMissingCheck(path: manifest.path, bytes: committed)

        let removed = try await fixture.store.cleanupAbandonedDrafts(now: now)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(files.publications, 1, "The test must reach the admission/cleanup boundary")
        XCTAssertEqual(try Data(contentsOf: manifest), committed)
        XCTAssertEqual(try Data(contentsOf: staged.source), source)
    }

    func testCleanupFailurePreservesTheDraftAndDoesNotBlockANewShare() async throws {
        let files = DraftRemovalFileManager()
        let fixture = try fixture(files: files)
        let staged = try await draft(in: fixture.store)
        try age(staged.directory)
        files.blockedPath = staged.directory.path

        let current = try await fixture.store.makeDraftDirectory(id: UUID())

        XCTAssertEqual(try Data(contentsOf: staged.source), source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.directory.path))
        XCTAssertGreaterThan(files.removalAttempts, 0)
        files.blockedPath = nil
        let removed = try await fixture.store.cleanupAbandonedDrafts(now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.directory.path))
        withExtendedLifetime(current.claim) {}
    }

    func testMissingInboxCleanupDoesNotCreateStorage() async throws {
        let fixture = try fixture()
        let removed = try await fixture.store.cleanupAbandonedDrafts(now: now)
        XCTAssertEqual(removed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    private func fixture(files: FileManager = .default) throws -> (root: URL, store: SharedUploadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftCleanup-\(UUID())")
        directories.append(root)
        return (root, SharedUploadStore(rootURL: root, fileManager: files))
    }

    private func draft(in store: SharedUploadStore) async throws -> (id: UUID, directory: URL, source: URL) {
        let id = UUID()
        let directory = try await store.makeBatchDirectory(id: id)
        let original = directory.appendingPathComponent("shared.jpg")
        try source.write(to: original)
        return (id, directory, original)
    }

    private func age(_ directory: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-48 * 60 * 60)],
                                              ofItemAtPath: directory.path)
    }

    private func batch(id: UUID, owner: SharedUploadOwner) -> SharedUploadBatch {
        SharedUploadBatch(id: id, owner: owner, createdAt: now, items: [
            SharedUploadItem(id: UUID(), filename: "shared.jpg", relativePath: "shared.jpg", contentType: "image/jpeg",
                byteCount: Int64(source.count), createdAt: now, modifiedAt: now, state: .queued, lastError: nil),
        ])
    }
}

private final class ManifestRaceFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var target: String?
    private var manifest = Data()
    private var count = 0
    var publications: Int { lock.withLock { count } }

    func publishAfterFirstMissingCheck(path: String, bytes: Data) {
        lock.withLock { target = path; manifest = bytes }
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        do { return try super.attributesOfItem(atPath: path) }
        catch {
            let bytes: Data? = lock.withLock {
                guard target == path else { return nil }
                target = nil
                count += 1
                return manifest
            }
            if let bytes { try bytes.write(to: URL(fileURLWithPath: path)) }
            throw error
        }
    }
}

private final class DraftRemovalFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: String?
    private var attempts = 0
    var removalAttempts: Int { lock.withLock { attempts } }
    var blockedPath: String? {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    override func removeItem(at url: URL) throws {
        if lock.withLock({ blocked == url.path }) {
            lock.withLock { attempts += 1 }
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
