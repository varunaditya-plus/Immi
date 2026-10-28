import SwiftData
import XCTest
@testable import ImmichApp

@MainActor
final class AssetVisibilityPersistenceTests: XCTestCase {
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
