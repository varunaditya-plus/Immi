import Foundation
import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class MediaEditStoreTests: XCTestCase {
    private var directory: URL!
    private var access: MediaEditTestAccess!
    private var store: MediaEditStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-edit-store-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        access = MediaEditTestAccess()
        store = makeStore()
    }

    override func tearDown() async throws {
        store = nil
        access = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testRecipesSurviveRestartCacheClearingLogoutAndReauthenticationWithoutGenerationPaths() throws {
        let record = try recipe(0.4)
        let token = try store.capture(assetID: "device:synthetic/L0/001", sourceFingerprint: "original-v1")
        try store.save(record, using: token)
        let file = try recordFile()
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(try makeStore().read(assetID: token.assetID), record)
        let initial = try XCTUnwrap(access.value)

        LocalSnapshot.clearAll()
        access.value = .init(owner: initial.owner, requestRevision: UUID(), generation: LocalSnapshot.generation)
        XCTAssertEqual(try makeStore().read(assetID: token.assetID), record)
        access.value = nil
        XCTAssertThrowsError(try store.read(assetID: token.assetID)) { XCTAssertEqual($0 as? MediaEditStoreError, .accountUnavailable) }
        access.value = .init(owner: initial.owner, requestRevision: UUID(), generation: UUID())

        let restored = try XCTUnwrap(makeStore().read(assetID: token.assetID))
        XCTAssertEqual(try restored.decode(MediaEditTestRecipe.self, supportedSchemaVersion: 1), .init(amount: 0.4, filter: "test-filter"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try recordFile(), file, "Session generations must never namespace durable edits")
    }

    func testOwnersAndAssetPathsAreHashedAndNormalizedWithoutCrossAccountReads() throws {
        let id = "device:../private/photo?name"
        let record = try recipe(0.2)
        let initial = try XCTUnwrap(access.value)
        try store.save(record, using: store.capture(assetID: id, sourceFingerprint: "original-v1"))
        let file = try recordFile()
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent.count, 64)
        XCTAssertEqual(file.deletingPathExtension().lastPathComponent.count, 64)
        XCTAssertTrue(file.deletingLastPathComponent().lastPathComponent.allSatisfy { $0.isHexDigit })
        XCTAssertTrue(file.deletingPathExtension().lastPathComponent.allSatisfy { $0.isHexDigit })
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for field in ["Authorization", "authHeaders", "requestRevision", "generation", "userID", "server"] {
            XCTAssertFalse(text.contains(field), "Durable recipes must not retain session data")
        }
        access.value = .init(owner: .init(server: "HTTPS://EXAMPLE.invalid:443/api///", userID: initial.owner.userID),
            requestRevision: initial.requestRevision, generation: initial.generation)
        XCTAssertEqual(try store.read(assetID: id), record)
        for owner in [BackupQueueOwner(server: initial.owner.server, userID: "another-user"),
                      BackupQueueOwner(server: "https://another.invalid/api", userID: initial.owner.userID)] {
            access.value = .init(owner: owner, requestRevision: UUID(), generation: UUID())
            XCTAssertNil(try store.read(assetID: id))
            try store.save(try recipe(0.9), using: store.capture(assetID: id, sourceFingerprint: "original-v1"))
        }
        access.value = initial
        XCTAssertEqual(try store.read(assetID: id), record)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testLateWritesAndReadsRejectChangedContextAndSourceGuards() throws {
        for change in ["server", "user", "request", "generation", "logout", "source", "privacy"] {
            let initial = try XCTUnwrap(access.value)
            let id = "asset-\(change)"
            let saved = try recipe(0.1)
            try store.save(saved, using: store.capture(assetID: id, sourceFingerprint: "original-v1"))
            let token = try store.capture(assetID: id, sourceFingerprint: "original-v1")
            let before = store.revision
            switch change {
            case "server": access.value = .init(owner: .init(server: "https://other.invalid", userID: initial.owner.userID), requestRevision: initial.requestRevision, generation: initial.generation)
            case "user": access.value = .init(owner: .init(server: initial.owner.server, userID: "other"), requestRevision: initial.requestRevision, generation: initial.generation)
            case "request": access.value = .init(owner: initial.owner, requestRevision: UUID(), generation: initial.generation)
            case "generation": access.value = .init(owner: initial.owner, requestRevision: initial.requestRevision, generation: UUID())
            case "logout": access.value = nil
            default: break
            }
            if !["source", "privacy"].contains(change) { XCTAssertThrowsError(try store.read(using: token), change) }
            XCTAssertThrowsError(try store.save(try recipe(0.8, fingerprint: change == "source" ? "changed-source" : "original-v1"),
                using: token, isCurrent: { change != "privacy" }), change)
            access.value = initial
            XCTAssertEqual(store.revision, before, "Rejected work must not publish a content revision")
            XCTAssertEqual(try store.read(assetID: id), saved)
        }
    }

    func testSeparateEditorsCannotOverwriteOrRevertAChangedRecord() throws {
        let other = makeStore()
        let first = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let stale = try other.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let saved = try document(0.4)
        let reverted = try document(0)
        try store.save(saved, using: first)

        XCTAssertThrowsError(try other.save(try document(0.9), using: stale)) { XCTAssertEqual($0 as? MediaEditStoreError, .editChanged) }
        XCTAssertThrowsError(try other.save(reverted, using: stale)) { XCTAssertEqual($0 as? MediaEditStoreError, .editChanged) }
        XCTAssertEqual(try other.read(assetID: "photo"), saved)
        let reverting = try other.capture(assetID: "photo", sourceFingerprint: "original-v1")
        try other.save(reverted, using: reverting)
        let actual = try XCTUnwrap(store.read(assetID: "photo"))
        XCTAssertEqual(actual, reverted)
        XCTAssertTrue(try actual.decode(MediaEditDocument.self, supportedSchemaVersion: 1).isIdentity)
        XCTAssertThrowsError(try store.save(saved, using: first)) { XCTAssertEqual($0 as? MediaEditStoreError, .editChanged) }
    }

    func testRevertingBeforeTheFirstSaveInvalidatesAnotherEditorsEmptySnapshot() throws {
        let other = makeStore()
        let stale = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let reverting = try other.capture(assetID: "photo", sourceFingerprint: "original-v1")

        let reverted = try document(0)
        try other.save(reverted, using: reverting)

        XCTAssertEqual(try store.read(assetID: "photo"), reverted)
        XCTAssertTrue(try reverted.decode(MediaEditDocument.self, supportedSchemaVersion: 1).isIdentity)
        let bytes = try Data(contentsOf: recordFile())
        XCTAssertThrowsError(try store.save(try document(0.7), using: stale)) {
            XCTAssertEqual($0 as? MediaEditStoreError, .editChanged)
        }
        XCTAssertEqual(try Data(contentsOf: recordFile()), bytes)
    }

    func testLegacyDeletedEnvelopeRemainsReadableAndRejectsAnOlderEditorAfterReplacement() throws {
        try store.save(try document(0.4), using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        let file = try recordFile()
        let legacy = Data(#"{"formatVersion":1,"revision":"00000000-0000-0000-0000-000000000000","isDeleted":true}"#.utf8)
        try legacy.write(to: file, options: .atomic)
        XCTAssertNil(try store.read(assetID: "photo"))
        let stale = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let restored = try document(0.6)
        try store.save(restored, using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))

        XCTAssertThrowsError(try store.save(try document(0), using: stale)) {
            XCTAssertEqual($0 as? MediaEditStoreError, .editChanged)
        }
        XCTAssertEqual(try store.read(assetID: "photo"), restored)
    }

    func testCorruptAndFutureEnvelopeDataRemainUntouchedInsteadOfBecomingDefaultEdits() throws {
        for invalid in [Data("{broken".utf8), Data(#"{"formatVersion":99,"unrecognized":"future"}"#.utf8),
                        Data(#"{"formatVersion":1,"revision":"00000000-0000-0000-0000-000000000000","isDeleted":false}"#.utf8)] {
            try store.save(try recipe(0.4), using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
            let file = try recordFile()
            try invalid.write(to: file, options: .atomic)
            XCTAssertThrowsError(try store.read(assetID: "photo"))
            XCTAssertThrowsError(try store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
            XCTAssertEqual(try Data(contentsOf: file), invalid)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testFutureRecipeAndUnrecognizedTypeCannotBeDowngradedOrReverted() throws {
        for record in [try recipe(0.4, version: 9), try recipe(0.4, type: "future-media")] {
            try store.save(record, using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
            let token = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
            let file = try recordFile()
            let bytes = try Data(contentsOf: file)
            if record.schemaVersion > 1 {
                XCTAssertThrowsError(try record.decode(MediaEditTestRecipe.self, supportedSchemaVersion: 1)) {
                    XCTAssertEqual($0 as? MediaEditStoreError, .unsupportedRecord)
                }
            }
            XCTAssertThrowsError(try store.save(try recipe(0.8), using: token)) { XCTAssertEqual($0 as? MediaEditStoreError, .unsupportedRecord) }
            XCTAssertThrowsError(try store.save(try recipe(0), using: token)) { XCTAssertEqual($0 as? MediaEditStoreError, .unsupportedRecord) }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testInvalidPayloadAndUnavailableStorageDoNotPublishSuccess() throws {
        let token = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let before = store.revision
        let invalid = MediaEditRecord(type: "photo", schemaVersion: 1, sourceFingerprint: "original-v1", payload: Data("invalid JSON".utf8))
        XCTAssertThrowsError(try store.save(invalid, using: token)) { XCTAssertEqual($0 as? MediaEditStoreError, .corruptRecord) }
        XCTAssertEqual(store.revision, before)
        XCTAssertNil(try store.read(assetID: "photo"))
        let blocked = directory.appendingPathComponent("blocked")
        let blocker = Data("This is a file, not an edit directory".utf8)
        try blocker.write(to: blocked)
        let failed = makeStore(directory: blocked)
        let revision = failed.revision
        XCTAssertThrowsError(try failed.save(try recipe(0.4), using: failed.capture(assetID: "photo", sourceFingerprint: "original-v1")))
        XCTAssertEqual(failed.revision, revision)
        XCTAssertEqual(try Data(contentsOf: blocked), blocker)
    }

    func testAnAtomicWriteFailureKeepsTheExistingRecipeBytesAndRevision() throws {
        let saved = try recipe(0.2)
        try store.save(saved, using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        let token = try store.capture(assetID: "photo", sourceFingerprint: "original-v1")
        let file = try recordFile()
        let bytes = try Data(contentsOf: file)
        let revision = store.revision
        let parent = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        XCTAssertThrowsError(try store.save(try recipe(0.9), using: token))

        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try store.read(assetID: "photo"), saved)
        XCTAssertEqual(store.revision, revision)
    }

    func testRevisionTracksOwnerChangesAndAcceptedMutationsButNotIdenticalSave() throws {
        let initial = try XCTUnwrap(access.value)
        let before = store.revision
        let record = try recipe(0.4)
        try store.save(record, using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        let saved = store.revision
        XCTAssertNotEqual(saved, before)
        try store.save(record, using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        XCTAssertEqual(store.revision, saved)
        access.value = .init(owner: initial.owner, requestRevision: UUID(), generation: initial.generation)
        XCTAssertNotEqual(store.revision, saved)
        let changed = store.revision
        try store.save(try recipe(0), using: store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        XCTAssertNotEqual(store.revision, changed)
    }

    func testSessionConfigurationIsIdempotentAndDoesNotRetainTheSession() {
        var session: SessionManager? = MockSessionManager()
        let isSessionReleased = { [weak session] in session == nil }
        store.configure(session: session!)
        XCTAssertFalse(isSessionReleased())
        let revision = store.revision
        store.configure(session: session!)
        XCTAssertEqual(store.revision, revision)
        session = nil
        XCTAssertTrue(isSessionReleased())
    }

    func testCredentialBearingServerAddressesCannotCreateOwnerDirectories() throws {
        let initial = try XCTUnwrap(access.value)
        for server in ["https://user:synthetic-password@example.invalid", "https://example.invalid?token=synthetic-token"] {
            access.value = .init(owner: .init(server: server, userID: initial.owner.userID), requestRevision: UUID(), generation: UUID())
            XCTAssertThrowsError(try store.capture(assetID: "photo", sourceFingerprint: "original-v1"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func makeStore(directory supplied: URL? = nil) -> MediaEditStore {
        let access = self.access!
        return MediaEditStore(directory: supplied ?? directory, access: { access.value })
    }

    private func recipe(_ amount: Double, type: String = "photo", version: Int = 1,
                        fingerprint: String = "original-v1") throws -> MediaEditRecord {
        try MediaEditRecord(type: type, schemaVersion: version, sourceFingerprint: fingerprint,
            value: MediaEditTestRecipe(amount: amount, filter: "test-filter"))
    }

    private func document(_ exposure: Double) throws -> MediaEditRecord {
        var document = MediaEditDocument()
        document.photo[.exposure] = exposure
        return try MediaEditRecord(type: MediaEditingPipeline.recordType,
            schemaVersion: MediaEditingPipeline.schemaVersion, sourceFingerprint: "original-v1", value: document)
    }

    private func recordFile() throws -> URL {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        return try XCTUnwrap(files.first)
    }
}

private struct MediaEditTestRecipe: Codable, Equatable { let amount: Double; let filter: String }

@MainActor
@Observable
private final class MediaEditTestAccess {
    var value: MediaEditStore.Access? = .init(owner: .init(server: "https://example.invalid/api", userID: "synthetic-user"),
        requestRevision: UUID(), generation: UUID())
}
