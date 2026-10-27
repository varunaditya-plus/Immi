import Observation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupMappingObservationTests: XCTestCase {
    func testUploadPublishesItsMappingAfterTheDatabaseCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let changed = expectation(description: "Committed upload mapping is observable")
        let observed = MappingObservation()
        withObservationTracking {
            _ = fixture.manager.backupMappingRevision
        } onChange: {
            MainActor.assumeIsolated {
                observed.mapping = fixture.manager.serverAssetIDsByLocalIdentifier()
                changed.fulfill()
            }
        }

        try fixture.manager.upsertBackupRecord(assetID: "uploaded-server", checksum: "checksum", localIdentifier: "device-photo")
        await fulfillment(of: [changed], timeout: 2)

        XCTAssertEqual(observed.mapping, ["device-photo": "uploaded-server"])
        XCTAssertEqual(fixture.reopen().serverAssetIDsByLocalIdentifier(), observed.mapping)
    }

    func testMatchingAndUnlinkingPublishActualOriginChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = fixture.manager.backupMappingRevision
        try fixture.manager.linkDeviceAsset(localIdentifier: "device-photo", to: "existing-server")
        let linked = fixture.manager.backupMappingRevision
        XCTAssertNotEqual(before, linked)
        XCTAssertEqual(fixture.manager.serverAssetIDsByLocalIdentifier()["device-photo"], "existing-server")

        try fixture.manager.linkDeviceAsset(localIdentifier: "device-photo", to: "uncommitted-replacement")
        XCTAssertEqual(fixture.manager.backupMappingRevision, linked, "Ignored relinking must not claim a new mapping")

        try fixture.manager.unlinkDeviceAsset(localIdentifier: "device-photo")

        XCTAssertNotEqual(fixture.manager.backupMappingRevision, linked)
        XCTAssertNil(fixture.reopen().serverAssetIDsByLocalIdentifier()["device-photo"])
    }

    func testCacheAndChecksumWritesDoNotClaimAnUploadCompleted() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = fixture.manager.backupMappingRevision

        try fixture.manager.storeChecksums([(localIdentifier: "device-photo", checksum: "hashed-but-not-uploaded")])
        try fixture.manager.clearAllCache()
        try fixture.manager.resetSyncDatabase()

        XCTAssertEqual(fixture.manager.backupMappingRevision, before)
        XCTAssertTrue(fixture.manager.serverAssetIDsByLocalIdentifier().isEmpty)
    }

    func testJournalFailureStillPublishesTheSavedUpload() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try FileManager.default.removeItem(at: fixture.journalURL)
        try FileManager.default.createDirectory(at: fixture.journalURL, withIntermediateDirectories: true)
        let before = fixture.manager.backupMappingRevision

        try fixture.manager.upsertBackupRecord(assetID: "committed-server", checksum: "checksum", localIdentifier: "device-photo")

        XCTAssertNotEqual(fixture.manager.backupMappingRevision, before)
        XCTAssertEqual(fixture.reopen().serverAssetIDsByLocalIdentifier()["device-photo"], "committed-server")
        guard case .protectionUnavailable = fixture.manager.startupState else {
            return XCTFail("The journal error must still be reported independently of the committed mapping")
        }
    }

    func testSuccessfulAccountCleanupPublishesMappingRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.manager.upsertBackupRecord(assetID: "server", checksum: "checksum", localIdentifier: "device")
        let before = fixture.manager.backupMappingRevision

        try fixture.manager.clearAllAccountData()

        XCTAssertNotEqual(fixture.manager.backupMappingRevision, before)
        XCTAssertTrue(fixture.reopen().serverAssetIDsByLocalIdentifier().isEmpty)
    }

    func testFailedCleanupDoesNotPublishOrRemoveTheExistingMapping() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.manager.upsertBackupRecord(assetID: "server", checksum: "checksum", localIdentifier: "device")
        try FileManager.default.removeItem(at: fixture.journalURL)
        try FileManager.default.createDirectory(at: fixture.journalURL, withIntermediateDirectories: true)
        let before = fixture.manager.backupMappingRevision

        XCTAssertThrowsError(try fixture.manager.clearAllAccountData())

        XCTAssertEqual(fixture.manager.backupMappingRevision, before)
        XCTAssertEqual(fixture.manager.serverAssetIDsByLocalIdentifier(), ["device": "server"])
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        private var retainedManager: SwiftDataManager?
        var manager: SwiftDataManager { retainedManager! }
        let storeURL: URL
        let journalURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-mapping-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appendingPathComponent("test.store")
            journalURL = directory.appendingPathComponent("backup.json")
            retainedManager = SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL)
            XCTAssertTrue(manager.isPersistentStoreAvailable)
        }

        func reopen() -> SwiftDataManager { SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL) }
        func close() {
            retainedManager = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
private final class MappingObservation { var mapping: [String: String] = [:] }
