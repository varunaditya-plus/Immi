import SQLite3
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AssetVisibilityPersistenceTests: XCTestCase {
    func testMissingPrimaryPrivacyTableCannotExposeAnUnmappedLockFromAnOlderJournal() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString
        try {
            let files = VisibilityJournalFileManager()
            let store = fixture.open(fileManager: files)
            try store.setAssetVisibility([id], to: "timeline")
            files.rejectWrites = true
            XCTAssertThrowsError(try store.setAssetVisibility([id], to: "locked"))
            XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id), [id])
            XCTAssertTrue(store.serverAssetIDsByLocalIdentifier().isEmpty)
        }()
        let journal = try Data(contentsOf: fixture.journalURL)
        try {
            var handle: OpaquePointer?
            let opened = sqlite3_open_v2(fixture.storeURL.path, &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            defer { if let handle { sqlite3_close(handle) } }
            XCTAssertEqual(opened, SQLITE_OK)
            let database = try XCTUnwrap(handle)
            var table: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database,
                "SELECT name FROM sqlite_master WHERE type='table' AND name='ZPRIVATEASSETRECORD'",
                -1, &table, nil), SQLITE_OK)
            defer { sqlite3_finalize(table) }
            XCTAssertEqual(sqlite3_step(table), SQLITE_ROW)
            let name = try XCTUnwrap(sqlite3_column_text(table, 0))
            XCTAssertEqual(String(cString: name), "ZPRIVATEASSETRECORD")
            sqlite3_finalize(table)
            table = nil
            XCTAssertEqual(sqlite3_exec(database, "DROP TABLE ZPRIVATEASSETRECORD", nil, nil, nil), SQLITE_OK)
        }()

        let reopened = fixture.open()

        guard case .recovered = reopened.startupState else {
            return XCTFail("An unreadable privacy table must rebuild the persistent cache")
        }
        XCTAssertTrue(reopened.isPersistentStoreAvailable)
        XCTAssertFalse(reopened.isVisibilityStateAvailable)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), journal)
        let policy = AssetVisibilityPolicy(dataManager: reopened, removed: RemovedAssets())
        XCTAssertFalse(policy.allows(id: id), "Losing the primary privacy table must not certify an unmapped old snapshot as public")
        XCTAssertTrue(policy.filter([AssetLite(makeTestAsset(id: id))]).isEmpty)
        XCTAssertFalse(fixture.open().isVisibilityStateAvailable)

        let snapshot = try FullSyncStaging()
        try snapshot.append(CachedAsset(id: id, assetId: id, type: "IMAGE", isArchived: true), visibility: "locked")
        try snapshot.append(CachedAsset(id: "public", assetId: "public", type: "IMAGE"), visibility: "timeline")
        try reopened.replaceSyncCache(with: snapshot,
            expectedVisibilityRevision: reopened.visibilityMutationRevision,
            expectedAssetRevision: reopened.assetMutationRevision)

        XCTAssertTrue(reopened.isVisibilityStateAvailable)
        let recovered = fixture.open()
        XCTAssertTrue(recovered.isVisibilityStateAvailable)
        XCTAssertEqual(try recovered.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id), [id])
        XCTAssertFalse(AssetVisibilityPolicy(dataManager: recovered).allows(id: id))
        XCTAssertTrue(AssetVisibilityPolicy(dataManager: recovered).allows(id: "public"))
    }

    func testRawSyncVisibilityDistinguishesArchivesFromPrivateAndUnknownAssets() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.open()
        let visibility = ["archive": "archive", "locked": "locked", "hidden": "hidden",
            "unknown": "future-visibility", "public": "timeline"]

        try store.applySyncBatch(upserts: visibility.map { id, value in
            CachedAsset(id: id, assetId: id, type: "IMAGE", isArchived: value != "timeline")
        }, deletedIds: [], visibilityByID: visibility)

        XCTAssertEqual(store.nonTimelineAssetIDs, ["archive", "locked", "hidden", "unknown"])
        XCTAssertEqual(store.archivedAssetIDs, ["archive"])
        XCTAssertEqual(store.privateAssetIDs, ["locked", "hidden", "unknown"])
        let privateRecords = try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>())
        XCTAssertEqual(Set(privateRecords.map(\.id)), ["locked", "hidden", "unknown"])
        try store.resetSyncDatabase()
        let reopened = fixture.open()
        XCTAssertEqual(reopened.cachedAssetCount(), 0)
        XCTAssertEqual(reopened.nonTimelineAssetIDs, store.nonTimelineAssetIDs)
        XCTAssertEqual(reopened.archivedAssetIDs, ["archive"])
        XCTAssertEqual(reopened.privateAssetIDs, ["locked", "hidden", "unknown"])
    }

    func testBooleanPrivateVisibilityCannotCreateOrKeepAnArchiveException() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.open()
        try store.setAssetVisibility(["photo"], to: "archive")
        XCTAssertEqual(store.archivedAssetIDs, ["photo"])

        try store.setTimelineVisibility(["photo"], inTimeline: false)

        XCTAssertEqual(store.privateAssetIDs, ["photo"])
        XCTAssertTrue(store.archivedAssetIDs.isEmpty)
        XCTAssertEqual(fixture.open().privateAssetIDs, ["photo"])
    }

    func testMemoryFallbackRetainsReadableJournalPrivacyWithoutRewritingIt() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.open()
        let prefix = UUID().uuidString
        let privateID = "\(prefix)-private"
        let archiveID = "\(prefix)-archive"
        let publicID = "\(prefix)-public"
        for id in [privateID, archiveID, publicID] {
            try store.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
        }
        try store.setAssetVisibility([privateID], to: "locked")
        try store.setAssetVisibility([archiveID], to: "archive")
        let persistentCollection = AssetVisibilityPolicy(dataManager: store, removed: RemovedAssets())
        XCTAssertTrue(persistentCollection.allows(id: archiveID))
        XCTAssertTrue(persistentCollection.allows(id: publicID))
        let originalJournal = try Data(contentsOf: fixture.journalURL)
        let blockedParent = fixture.directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)

        let fallback = SwiftDataManager(storeURL: blockedParent.appendingPathComponent("test.store"),
            backupJournalURL: fixture.journalURL)
        let collection = AssetVisibilityPolicy(dataManager: fallback, removed: RemovedAssets())
        let timeline = AssetVisibilityPolicy(scope: .timeline, dataManager: fallback, removed: RemovedAssets())

        guard case .persistentStoreUnavailable = fallback.startupState else {
            return XCTFail("The blocked store must use the memory fallback")
        }
        XCTAssertFalse(fallback.isPersistentStoreAvailable)
        let ids = [privateID, archiveID, publicID].flatMap { [$0, "device:local-\($0)"] }
            + ["device:unmapped-\(prefix)"]
        for id in ids {
            XCTAssertFalse(collection.allows(id: id))
            XCTAssertFalse(timeline.allows(id: id))
        }
        let assets = ids.map { AssetLite(makeTestAsset(id: $0)) }
        XCTAssertTrue(collection.filter(assets).isEmpty)
        XCTAssertTrue(timeline.filter(assets).isEmpty)
        let unlocked = AssetVisibilityPolicy(scope: .locked, dataManager: fallback, removed: RemovedAssets())
        XCTAssertTrue(unlocked.allows(id: privateID))
        XCTAssertEqual(unlocked.filter([assets[0]]).map(\.id), [privateID])
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalJournal)
        XCTAssertThrowsError(try fallback.unlinkDeviceAsset(localIdentifier: "local-\(privateID)"))
        XCTAssertNoThrow(try fallback.recordServerVisibility([makeTestAsset(id: publicID)]))
        var observedPrivate = makeTestAsset(id: privateID)
        observedPrivate.visibility = "locked"
        XCTAssertThrowsError(try fallback.recordServerVisibility([observedPrivate]))
        XCTAssertThrowsError(try fallback.setAssetVisibility([privateID], to: "timeline"))
        let replacement = try FullSyncStaging()
        XCTAssertThrowsError(try fallback.replaceSyncCache(with: replacement,
            expectedVisibilityRevision: fallback.visibilityMutationRevision,
            expectedAssetRevision: fallback.assetMutationRevision))
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalJournal)
    }

    func testMemoryFallbackCannotTrustArchiveOrTimelineJournalAfterFailedLockWrite() throws {
        for previousVisibility in ["archive", "timeline"] {
            let fixture = try VisibilityStoreFixture()
            defer { fixture.cleanup() }
            let fileManager = VisibilityJournalFileManager()
            let store = fixture.open(fileManager: fileManager)
            let id = UUID().uuidString
            try store.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
            try store.setAssetVisibility([id], to: previousVisibility)
            let originalJournal = try Data(contentsOf: fixture.journalURL)
            fileManager.rejectWrites = true
            XCTAssertThrowsError(try store.setAssetVisibility([id], to: "locked"))
            XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id), [id])
            XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalJournal)
            let blockedParent = fixture.directory.appendingPathComponent("not-a-directory")
            try Data("blocked".utf8).write(to: blockedParent)

            let fallback = SwiftDataManager(storeURL: blockedParent.appendingPathComponent("test.store"),
                backupJournalURL: fixture.journalURL)
            let policy = AssetVisibilityPolicy(dataManager: fallback, removed: RemovedAssets())

            XCTAssertFalse(fallback.isPersistentStoreAvailable)
            XCTAssertFalse(policy.allows(id: id))
            XCTAssertFalse(policy.allows(id: "device:local-\(id)"))
            XCTAssertTrue(policy.filter([AssetLite(makeTestAsset(id: id)),
                AssetLite(makeTestAsset(id: "device:local-\(id)"))]).isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalJournal)
        }
    }

    func testCorruptPrimaryRecoveryCannotExposeALockMissingFromAnOlderJournal() throws {
        for previousVisibility in ["archive", "timeline"] {
            let fixture = try VisibilityStoreFixture()
            defer { fixture.cleanup() }
            let id = UUID().uuidString
            let unmappedID = UUID().uuidString
            try {
                let fileManager = VisibilityJournalFileManager()
                let store = fixture.open(fileManager: fileManager)
                try store.linkDeviceAsset(localIdentifier: "local-\(id)", to: id)
                try store.setAssetVisibility([id, unmappedID], to: previousVisibility)
                let journal = try Data(contentsOf: fixture.journalURL)
                fileManager.rejectWrites = true
                XCTAssertThrowsError(try store.setAssetVisibility([id, unmappedID], to: "locked"))
                XCTAssertEqual(Set(try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id)),
                    [id, unmappedID])
                XCTAssertEqual(try Data(contentsOf: fixture.journalURL), journal)
            }()
            try Data("not a SQLite database".utf8).write(to: fixture.storeURL, options: .atomic)

            let recovered = fixture.open()

            guard case .recovered(let quarantine, let restoredCount, _) = recovered.startupState else {
                return XCTFail("The corrupt primary must be quarantined and rebuilt")
            }
            XCTAssertNotNil(quarantine)
            XCTAssertEqual(restoredCount, 1)
            XCTAssertTrue(recovered.isPersistentStoreAvailable)
            XCTAssertFalse(recovered.isVisibilityStateAvailable)
            XCTAssertEqual(recovered.serverAssetIDsByLocalIdentifier()["local-\(id)"], id)
            let policy = AssetVisibilityPolicy(dataManager: recovered, removed: RemovedAssets())
            XCTAssertFalse(policy.allows(id: id), previousVisibility)
            XCTAssertFalse(policy.allows(id: "device:local-\(id)"), previousVisibility)
            XCTAssertFalse(policy.allows(id: unmappedID), previousVisibility)
            XCTAssertFalse(policy.allows(id: "device:unmapped-\(unmappedID)"), previousVisibility)
            XCTAssertTrue(policy.filter([AssetLite(makeTestAsset(id: id)),
                AssetLite(makeTestAsset(id: "device:local-\(id)")),
                AssetLite(makeTestAsset(id: unmappedID))]).isEmpty, previousVisibility)
            let reopened = fixture.open()
            XCTAssertTrue(reopened.isPersistentStoreAvailable)
            XCTAssertFalse(reopened.isVisibilityStateAvailable)
            XCTAssertFalse(AssetVisibilityPolicy(dataManager: reopened).allows(id: unmappedID))
        }
    }

    func testFailedRecoveryMarkerCreationPreservesTheCorruptPrimaryAndJournal() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        try {
            let store = fixture.open()
            try store.linkDeviceAsset(localIdentifier: "local", to: "server")
        }()
        let journal = try Data(contentsOf: fixture.journalURL)
        let corrupt = Data("not a SQLite database".utf8)
        try corrupt.write(to: fixture.storeURL, options: .atomic)
        let files = VisibilityMarkerFileManager(blockedParent: fixture.directory)

        let fallback = fixture.open(fileManager: files)

        XCTAssertFalse(fallback.isPersistentStoreAvailable)
        XCTAssertFalse(fallback.isVisibilityStateAvailable)
        XCTAssertEqual(try Data(contentsOf: fixture.storeURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), journal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("RecoveredStores").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.appendingPathExtension("visibility-recovery").path))
    }

    func testConfirmedLockOverridesOlderArchiveJournalWhenJournalWriteFails() throws {
        for cached in [false, true] {
            let fixture = try VisibilityStoreFixture()
            defer { fixture.cleanup() }
            let fileManager = VisibilityJournalFileManager()
            let store = fixture.open(fileManager: fileManager)
            if cached {
                try store.insertOrUpdateCachedAsset(CachedAsset(id: "photo", assetId: "photo", type: "IMAGE"))
            }
            try store.setAssetVisibility(["photo"], to: "archive")
            let oldJournal = try Data(contentsOf: fixture.journalURL)
            XCTAssertEqual(fixture.open().archivedAssetIDs, ["photo"])
            fileManager.rejectWrites = true

            XCTAssertThrowsError(try store.setAssetVisibility(["photo"], to: "locked"))

            XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal,
                "The older archive exception must still be present for this regression")
            XCTAssertEqual(store.privateAssetIDs, ["photo"])
            let records = try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>())
            XCTAssertEqual(records.map(\.id), ["photo"], "The primary store independently protects an uncached photo")
            let reopened = fixture.open()
            XCTAssertEqual(reopened.privateAssetIDs, ["photo"])
            XCTAssertTrue(reopened.archivedAssetIDs.isEmpty)
            XCTAssertEqual(reopened.cachedAssetCount(), cached ? 1 : 0)
        }
    }

    func testPrivateSyncOverridesOlderArchiveJournalWhenJournalWriteFails() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let fileManager = VisibilityJournalFileManager()
        let store = fixture.open(fileManager: fileManager)
        try store.setAssetVisibility(["photo"], to: "archive")
        let oldJournal = try Data(contentsOf: fixture.journalURL)
        fileManager.rejectWrites = true

        XCTAssertThrowsError(try store.applySyncBatch(
            upserts: [CachedAsset(id: "photo", assetId: "photo", type: "IMAGE", isArchived: true)],
            deletedIds: [], visibilityByID: ["photo": "hidden"]))

        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal)
        XCTAssertEqual(store.privateAssetIDs, ["photo"])
        let reopened = fixture.open()
        XCTAssertEqual(reopened.privateAssetIDs, ["photo"])
        XCTAssertTrue(reopened.archivedAssetIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(reopened.getCachedAsset(id: "photo")).isArchived)
    }

    func testFailedVisibilityReleaseRetainsConservativeInMemoryAndRestoredState() throws {
        for visibility in ["archive", "timeline"] {
            let fixture = try VisibilityStoreFixture()
            defer { fixture.cleanup() }
            let fileManager = VisibilityJournalFileManager()
            let store = fixture.open(fileManager: fileManager)
            try store.setAssetVisibility(["photo"], to: "locked")
            let oldJournal = try Data(contentsOf: fixture.journalURL)
            fileManager.rejectWrites = true

            XCTAssertThrowsError(try store.setAssetVisibility(["photo"], to: visibility))

            XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal)
            XCTAssertEqual(store.privateAssetIDs, ["photo"])
            XCTAssertTrue(store.archivedAssetIDs.isEmpty)
            XCTAssertEqual(fixture.open().privateAssetIDs, ["photo"])
        }
    }

    func testSuccessfulReleaseAndLogoutRemovePrimaryPrivateProtection() throws {
        let fixture = try VisibilityStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.open()
        try store.setAssetVisibility(["archive", "public", "other-private"], to: "locked")

        try store.setAssetVisibility(["archive"], to: "archive")
        try store.setAssetVisibility(["public"], to: "timeline")

        let reopened = fixture.open()
        XCTAssertEqual(reopened.privateAssetIDs, ["other-private"])
        XCTAssertEqual(reopened.archivedAssetIDs, ["archive"])
        XCTAssertEqual(reopened.nonTimelineAssetIDs, ["archive", "other-private"])
        XCTAssertEqual(try reopened.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id), ["other-private"])
        try reopened.clearAllAccountData()
        let loggedOut = fixture.open()
        XCTAssertTrue(loggedOut.nonTimelineAssetIDs.isEmpty)
        XCTAssertTrue(loggedOut.archivedAssetIDs.isEmpty)
        XCTAssertTrue(loggedOut.privateAssetIDs.isEmpty)
        XCTAssertTrue(try loggedOut.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).isEmpty)
    }

    func testRepeatingAnUnchangedVisibilityAfterFailureRepairsTheOlderArchiveJournal() throws {
        for fromMetadata in [false, true] {
            let fixture = try VisibilityStoreFixture()
            defer { fixture.cleanup() }
            let fileManager = VisibilityJournalFileManager()
            let store = fixture.open(fileManager: fileManager)
            try store.setAssetVisibility(["photo"], to: "archive")
            let oldJournal = try Data(contentsOf: fixture.journalURL)
            var locked = makeTestAsset(id: "photo")
            locked.visibility = "locked"
            fileManager.rejectWrites = true
            if fromMetadata {
                XCTAssertThrowsError(try store.recordServerVisibility([locked]))
            } else {
                XCTAssertThrowsError(try store.setAssetVisibility(["photo"], to: "locked"))
            }
            XCTAssertEqual(try Data(contentsOf: fixture.journalURL), oldJournal)
            XCTAssertEqual(store.privateAssetIDs, ["photo"])
            fileManager.rejectWrites = false

            if fromMetadata { try store.recordServerVisibility([locked]) }
            else { try store.setAssetVisibility(["photo"], to: "locked") }

            let repaired = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.journalURL)) as? [String: Any])
            XCTAssertEqual(repaired["nonTimelineAssetIDs"] as? [String], ["photo"])
            XCTAssertEqual(repaired["archivedAssetIDs"] as? [String], [],
                "A retry must repair the stale archive exception rather than rely forever on one durable copy")
            XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<PrivateAssetRecord>()).map(\.id), ["photo"])
            XCTAssertEqual(fixture.open().privateAssetIDs, ["photo"])
        }
    }
}

@MainActor
private struct VisibilityStoreFixture {
    let directory: URL
    var storeURL: URL { directory.appendingPathComponent("test.store") }
    var journalURL: URL { directory.appendingPathComponent("backup.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("asset-visibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func open(fileManager: FileManager = .default) -> SwiftDataManager {
        SwiftDataManager(storeURL: storeURL, backupJournalURL: journalURL, fileManager: fileManager)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class VisibilityJournalFileManager: FileManager, @unchecked Sendable {
    var rejectWrites = false

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes)
    }
}

private final class VisibilityMarkerFileManager: FileManager, @unchecked Sendable {
    let blockedParent: URL

    init(blockedParent: URL) { self.blockedParent = blockedParent }

    override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                 attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.standardizedFileURL == blockedParent.standardizedFileURL { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }
}
