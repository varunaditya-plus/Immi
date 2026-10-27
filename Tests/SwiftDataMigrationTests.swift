import Foundation
import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class SwiftDataMigrationTests: XCTestCase {
    func testOpensUnversionedCurrentProductionStore() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let legacySchema = Schema([
            CachedAsset.self,
            BackupRecord.self,
            SyncState.self,
            LocalAssetChecksum.self,
        ])
        let legacyConfiguration = ModelConfiguration(
            schema: legacySchema,
            url: fixture.storeURL,
            cloudKitDatabase: .none)
        let legacyContainer = try ModelContainer(
            for: legacySchema,
            configurations: [legacyConfiguration])
        let legacyContext = ModelContext(legacyContainer)
        legacyContext.insert(BackupRecord(
            id: "unversioned-record",
            assetId: "server-current",
            deviceAssetId: "checksum-current",
            localIdentifier: "local-current"))
        try legacyContext.save()

        let migrated = SwiftDataManager(
            storeURL: fixture.storeURL,
            backupJournalURL: fixture.journalURL)
        XCTAssertEqual(migrated.uploadedLocalIdentifiers(), ["local-current"])
        XCTAssertEqual(migrated.startupState, .ready)
    }

    func testMigratesOriginalV1StoreWithoutLosingBackupRecord() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        try createV1Store(at: fixture.storeURL)
        let container = try openCurrentStore(at: fixture.storeURL)
        let context = ModelContext(container)

        let records = try context.fetch(FetchDescriptor<BackupRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "backup-v1")
        XCTAssertEqual(records.first?.assetId, "server-v1")
        XCTAssertEqual(records.first?.deviceAssetId, "checksum-v1")
        XCTAssertEqual(records.first?.localIdentifier, "")

        let assets = try context.fetch(FetchDescriptor<CachedAsset>())
        XCTAssertEqual(assets.first?.id, "cached-v1")
        XCTAssertNil(assets.first?.duration)
        XCTAssertNil(assets.first?.livePhotoVideoId)
        XCTAssertEqual(assets.first?.monthKey, "")
    }

    func testMigratesV2StoreAndKeepsExistingMediaMetadata() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        try createV2Store(at: fixture.storeURL)
        let container = try openCurrentStore(at: fixture.storeURL)
        let context = ModelContext(container)

        let records = try context.fetch(FetchDescriptor<BackupRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.assetId, "server-v2")
        XCTAssertEqual(records.first?.localIdentifier, "")

        let assets = try context.fetch(FetchDescriptor<CachedAsset>())
        XCTAssertEqual(assets.first?.duration, 4.25)
        XCTAssertEqual(assets.first?.livePhotoVideoId, "motion-v2")
        XCTAssertEqual(assets.first?.monthKey, "2026-08")

        context.insert(LocalAssetChecksum(
            localIdentifier: "local-v2",
            checksum: "sha1-v2"))
        try context.save()
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<LocalAssetChecksum>()).count,
            1)
    }

    func testMigratesV3StoreWithoutTreatingLegacyArchivedFlagsAsPublicArchives() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        do {
            let schema = Schema(versionedSchema: LocalStoreSchemaV3.self)
            let configuration = ModelConfiguration(schema: schema, url: fixture.storeURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(CachedAsset(id: "old-private", assetId: "old-private", type: "IMAGE",
                isArchived: true, duration: 4.25, livePhotoVideoId: "motion-v3", ratio: 1.5))
            context.insert(BackupRecord(id: "backup-v3", assetId: "old-private",
                deviceAssetId: "checksum-v3", localIdentifier: "device-v3"))
            try context.save()
        }

        let migrated = SwiftDataManager(storeURL: fixture.storeURL, backupJournalURL: fixture.journalURL)

        XCTAssertEqual(migrated.startupState, .ready)
        XCTAssertEqual(migrated.privateAssetIDs, ["old-private"])
        XCTAssertTrue(migrated.archivedAssetIDs.isEmpty)
        XCTAssertEqual(migrated.uploadedLocalIdentifiers(), ["device-v3"])
        let asset = try XCTUnwrap(migrated.getCachedAsset(id: "old-private"))
        XCTAssertEqual(asset.duration, 4.25)
        XCTAssertEqual(asset.livePhotoVideoId, "motion-v3")
        XCTAssertEqual(asset.ratio, 1.5)
        try migrated.setAssetVisibility(["old-private"], to: "archive")
        XCTAssertEqual(migrated.archivedAssetIDs, ["old-private"])
        XCTAssertTrue(migrated.privateAssetIDs.isEmpty)
    }

    func testCorruptCacheIsQuarantinedAndBackupMappingIsRestored() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        try seedProtectedBackupRecord(in: fixture)
        try Data("not-a-sqlite-store".utf8).write(
            to: fixture.storeURL,
            options: .atomic)

        let recovered = SwiftDataManager(
            storeURL: fixture.storeURL,
            backupJournalURL: fixture.journalURL)

        guard case let .recovered(quarantineURL, restoredCount, _) = recovered.startupState else {
            return XCTFail("Expected startup recovery, got \(recovered.startupState)")
        }
        XCTAssertEqual(restoredCount, 1)
        XCTAssertNotNil(quarantineURL)
        XCTAssertTrue(recovered.isPersistentStoreAvailable)
        XCTAssertEqual(recovered.uploadedLocalIdentifiers(), ["photo-local-id"])
        XCTAssertEqual(
            recovered.serverAssetIDsByLocalIdentifier()["photo-local-id"],
            "server-asset-id")
    }

    func testLogoutClearsProtectedBackupJournal() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        try seedProtectedBackupRecord(in: fixture)
        let manager = SwiftDataManager(
            storeURL: fixture.storeURL,
            backupJournalURL: fixture.journalURL)
        try manager.clearAllAccountData()

        XCTAssertTrue(manager.uploadedLocalIdentifiers().isEmpty)
        let journalJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.journalURL)) as? [String: Any]
        XCTAssertEqual((journalJSON?["records"] as? [Any])?.count, 0)
    }

    func testBackgroundCompletionIsIdempotentForSameLocalAsset() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let manager = SwiftDataManager(
            storeURL: fixture.storeURL,
            backupJournalURL: fixture.journalURL)

        try manager.upsertBackupRecord(
            assetID: "server-first",
            checksum: "checksum-first",
            localIdentifier: "local-repeat")
        try manager.upsertBackupRecord(
            assetID: "server-final",
            checksum: "checksum-final",
            localIdentifier: "local-repeat")

        XCTAssertEqual(manager.uploadedLocalIdentifiers(), ["local-repeat"])
        XCTAssertEqual(
            manager.serverAssetIDsByLocalIdentifier()["local-repeat"],
            "server-final")
        XCTAssertEqual(manager.getBackupRecord(deviceAssetId: "checksum-final")?.assetId, "server-final")
    }

    private func createV1Store(at url: URL) throws {
        let schema = Schema(versionedSchema: LocalStoreSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalStoreSchemaV1.CachedAsset(
            id: "cached-v1",
            assetId: "server-v1",
            type: "IMAGE",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        context.insert(LocalStoreSchemaV1.BackupRecord(
            id: "backup-v1",
            assetId: "server-v1",
            deviceAssetId: "checksum-v1"))
        context.insert(LocalStoreSchemaV1.SyncState())
        try context.save()
    }

    private func createV2Store(at url: URL) throws {
        let schema = Schema(versionedSchema: LocalStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalStoreSchemaV2.CachedAsset(
            id: "cached-v2",
            assetId: "server-v2",
            type: "IMAGE",
            duration: 4.25,
            livePhotoVideoId: "motion-v2",
            monthKey: "2026-08"))
        context.insert(LocalStoreSchemaV2.BackupRecord(
            id: "backup-v2",
            assetId: "server-v2",
            deviceAssetId: "checksum-v2"))
        try context.save()
    }

    private func openCurrentStore(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LocalStoreSchemaV4.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema,
            migrationPlan: LocalStoreMigrationPlan.self,
            configurations: [configuration])
    }

    private func seedProtectedBackupRecord(in fixture: StoreFixture) throws {
        let manager = SwiftDataManager(
            storeURL: fixture.storeURL,
            backupJournalURL: fixture.journalURL)
        try manager.insertBackupRecord(BackupRecord(
            id: "protected-record",
            assetId: "server-asset-id",
            deviceAssetId: "checksum",
            localIdentifier: "photo-local-id"))
    }
}

private struct StoreFixture {
    let directory: URL
    let storeURL: URL
    let journalURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftdata-migration-\(UUID().uuidString)", isDirectory: true)
        storeURL = directory.appendingPathComponent("test.store")
        journalURL = directory.appendingPathComponent("backup-records.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
