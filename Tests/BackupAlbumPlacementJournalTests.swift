import Foundation
import XCTest
@testable import ImmichApp

@MainActor
final class BackupAlbumPlacementJournalTests: XCTestCase {
    private var directories: [URL] = []
    private let initial = Date(timeIntervalSince1970: 100)
    private let owner = BackupQueueOwner(server: "https://backup.example/api", userID: "first")
    private let placement = BackupAlbumPlacement(
        localIdentifier: "photo", assetID: "server-photo", albumName: "Summer")

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testSuccessfulUploadAndAlbumIntentSurviveTogetherAcrossRelaunch() throws {
        let fixture = try fixture()
        try prepareUpload(fixture.queue)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let unrelated = fixture.queue.item(id: "other")
        let writes = fixture.fileManager.writeAttempts
        // A split completion/checkpoint would fail its second write.
        fixture.fileManager.failOnAttempt = writes + 2

        try fixture.queue.markCompleted("photo", albumPlacement: placement)
        XCTAssertEqual(fixture.fileManager.writeAttempts, writes + 1)
        fixture.fileManager.failOnAttempt = nil

        let reopened = fixture.reopen()
        XCTAssertNil(reopened.item(id: "photo"))
        XCTAssertEqual(reopened.item(id: "other"), unrelated)
        XCTAssertEqual(reopened.snapshot.completed, 1)
        XCTAssertTrue(reopened.snapshot.completionNotificationPending)
        XCTAssertEqual(reopened.pendingAlbumPlacements, [placement])
        XCTAssertEqual(reopened.ownership, ownership)

        try reopened.markCompleted("other")
        try reopened.enqueue(["next-run"], now: initial)
        XCTAssertEqual(reopened.snapshot.completed, 0)
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [placement])
    }

    func testFailedCompletionKeepsUploadAndSourceAlbumUntilCheckpointCanBeSaved() throws {
        let fixture = try fixture()
        try prepareUpload(fixture.queue)
        let originalItems = fixture.queue.items
        let originalSnapshot = fixture.queue.snapshot
        let ownership = fixture.queue.ownership
        let originalData = try Data(contentsOf: fixture.url)

        fixture.fileManager.failWrites = true
        XCTAssertThrowsError(try fixture.queue.markCompleted("photo", albumPlacement: placement))

        XCTAssertEqual(fixture.queue.items, originalItems)
        XCTAssertEqual(fixture.queue.item(id: "photo")?.sourceAlbumName, "Summer")
        XCTAssertEqual(fixture.queue.snapshot, originalSnapshot)
        XCTAssertTrue(fixture.queue.pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(fixture.queue.ownership, ownership)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalData)
        XCTAssertEqual(fixture.reopen().items, originalItems)

        fixture.fileManager.failWrites = false
        try fixture.queue.markCompleted("photo", albumPlacement: placement)
        let reopened = fixture.reopen()
        XCTAssertNil(reopened.item(id: "photo"))
        XCTAssertEqual(reopened.snapshot.completed, 1)
        XCTAssertEqual(reopened.pendingAlbumPlacements, [placement])
    }

    func testReplayAfterRecordedUploadSavesPlacementWithoutCountingUploadAgain() throws {
        let fixture = try fixture()
        try prepareUpload(fixture.queue)
        try fixture.queue.markCompleted("photo")

        try fixture.queue.markCompleted("photo", albumPlacement: placement)
        let savedData = try Data(contentsOf: fixture.url)
        fixture.fileManager.failWrites = true
        XCTAssertNoThrow(try fixture.queue.markCompleted("photo", albumPlacement: placement))

        let reopened = fixture.reopen()
        XCTAssertEqual(reopened.snapshot.completed, 1)
        XCTAssertEqual(reopened.items.map(\.id), ["other"])
        XCTAssertEqual(reopened.pendingAlbumPlacements, [placement])
        XCTAssertEqual(try Data(contentsOf: fixture.url), savedData)
    }

    func testAlreadyRecordedPhotoCanCheckpointPlacementWithoutChangingUploadProgress() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        try fixture.queue.enqueue(["other"], now: initial)
        let progress = fixture.queue.snapshot

        try fixture.queue.recordAlbumPlacement(placement)
        fixture.fileManager.failWrites = true
        XCTAssertNoThrow(try fixture.queue.recordAlbumPlacement(placement))

        let reopened = fixture.reopen()
        XCTAssertEqual(reopened.snapshot, progress)
        XCTAssertEqual(reopened.pendingAlbumPlacements, [placement])
        XCTAssertEqual(reopened.items.map(\.id), ["other"])
    }

    func testStalePlacementAcknowledgementCannotDiscardNewerIntentOrAnotherPhoto() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        let neighbor = BackupAlbumPlacement(
            localIdentifier: "neighbor", assetID: "server-neighbor", albumName: "Summer")
        let replacement = BackupAlbumPlacement(
            localIdentifier: "photo", assetID: "replacement-photo", albumName: "Autumn")
        try fixture.queue.recordAlbumPlacement(placement)
        try fixture.queue.recordAlbumPlacement(neighbor)
        try fixture.queue.recordAlbumPlacement(replacement)

        fixture.fileManager.failWrites = true
        XCTAssertNoThrow(try fixture.queue.completeAlbumPlacement(placement))
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [replacement, neighbor])

        fixture.fileManager.failWrites = false
        try fixture.queue.completeAlbumPlacement(replacement)
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [neighbor])
        try fixture.queue.completeAlbumPlacement(neighbor)
        XCTAssertTrue(fixture.reopen().pendingAlbumPlacements.isEmpty)
    }

    func testFailedPlacementWritesKeepThePreviousDurableIntent() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        try fixture.queue.recordAlbumPlacement(placement)
        let replacement = BackupAlbumPlacement(
            localIdentifier: "photo", assetID: "replacement-photo", albumName: "Autumn")
        let savedData = try Data(contentsOf: fixture.url)

        fixture.fileManager.failWrites = true
        XCTAssertThrowsError(try fixture.queue.recordAlbumPlacement(replacement))
        XCTAssertEqual(fixture.queue.pendingAlbumPlacements, [placement])
        XCTAssertEqual(try Data(contentsOf: fixture.url), savedData)
        XCTAssertThrowsError(try fixture.queue.completeAlbumPlacement(placement))
        XCTAssertEqual(fixture.queue.pendingAlbumPlacements, [placement])
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [placement])
        XCTAssertEqual(try Data(contentsOf: fixture.url), savedData)

        fixture.fileManager.failWrites = false
        try fixture.queue.recordAlbumPlacement(replacement)
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [replacement])
        try fixture.queue.completeAlbumPlacement(replacement)
        XCTAssertTrue(fixture.reopen().pendingAlbumPlacements.isEmpty)
    }

    func testMismatchedCompletionCannotRemoveUploadOrAttachAnotherPhotosAlbum() throws {
        let fixture = try fixture()
        try prepareUpload(fixture.queue)
        let originalItems = fixture.queue.items
        let savedData = try Data(contentsOf: fixture.url)

        XCTAssertThrowsError(try fixture.queue.markCompleted("other", albumPlacement: placement)) { error in
            guard case BackupQueueStoreError.invalidTransition = error else {
                return XCTFail("Expected a mismatched upload to be rejected: \(error)")
            }
        }

        XCTAssertEqual(fixture.queue.items, originalItems)
        XCTAssertTrue(fixture.queue.pendingAlbumPlacements.isEmpty)
        XCTAssertEqual(fixture.queue.snapshot.completed, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url), savedData)
    }

    func testOwnerBindingRetainsOwnPlacementsAndClearsThemOnAccountChangeOrLogout() throws {
        let fixture = try fixture()
        try fixture.queue.bind(to: owner)
        try fixture.queue.recordAlbumPlacement(placement)
        let ownership = try XCTUnwrap(fixture.queue.ownership)
        let replacement = BackupQueueOwner(server: owner.server, userID: "second")
        let savedData = try Data(contentsOf: fixture.url)

        XCTAssertFalse(try fixture.queue.bind(to: owner))
        XCTAssertEqual(fixture.queue.ownership, ownership)
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [placement])

        fixture.fileManager.failWrites = true
        XCTAssertThrowsError(try fixture.queue.bind(to: replacement))
        XCTAssertEqual(fixture.queue.ownership, ownership)
        XCTAssertEqual(fixture.queue.pendingAlbumPlacements, [placement])
        XCTAssertEqual(try Data(contentsOf: fixture.url), savedData)

        fixture.fileManager.failWrites = false
        XCTAssertTrue(try fixture.queue.bind(to: replacement))
        XCTAssertEqual(fixture.reopen().owner, replacement)
        XCTAssertNotEqual(fixture.queue.ownership?.generation, ownership.generation)
        XCTAssertTrue(fixture.reopen().pendingAlbumPlacements.isEmpty)

        try fixture.queue.recordAlbumPlacement(placement)
        try fixture.queue.clear()
        let loggedOut = fixture.reopen()
        XCTAssertNil(loggedOut.ownership)
        XCTAssertNil(loggedOut.owner)
        XCTAssertTrue(loggedOut.pendingAlbumPlacements.isEmpty)
    }

    func testFirstAccountCannotAdoptAnUnownedAlbumPlacement() throws {
        let fixture = try fixture()
        try fixture.queue.recordAlbumPlacement(placement)

        XCTAssertTrue(try fixture.queue.bind(to: owner))

        XCTAssertEqual(fixture.reopen().owner, owner)
        XCTAssertTrue(fixture.reopen().pendingAlbumPlacements.isEmpty)
    }

    func testLegacyQueueWithoutJournalFieldPreservesItsUploadAndOwnership() throws {
        let fixture = try fixture()
        try prepareUpload(fixture.queue)
        try fixture.queue.recordAlbumPlacement(placement)
        let originalItems = fixture.queue.items
        let ownership = fixture.queue.ownership
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        XCTAssertNotNil(legacy.removeValue(forKey: "pendingAlbumPlacements"))
        try JSONSerialization.data(withJSONObject: legacy).write(to: fixture.url)

        let reopened = fixture.reopen()

        XCTAssertNil(reopened.persistenceWarning)
        XCTAssertEqual(reopened.items, originalItems)
        XCTAssertEqual(reopened.ownership, ownership)
        XCTAssertTrue(reopened.pendingAlbumPlacements.isEmpty)
        try reopened.markCompleted("photo", albumPlacement: placement)
        XCTAssertEqual(fixture.reopen().pendingAlbumPlacements, [placement])
        XCTAssertEqual(fixture.reopen().items.map(\.id), ["other"])
    }

    private func prepareUpload(_ queue: BackupQueueStore) throws {
        try queue.bind(to: owner)
        try queue.enqueue(["photo", "other"], intent: .manualUpload, now: initial)
        try queue.markPreparing("photo", phase: .primaryAsset, sourceAlbumName: "Summer", now: initial)
        try queue.markUploading(
            "photo", phase: .primaryAsset, checksum: "checksum", taskIdentifier: 7, now: initial)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-album-journal-\(UUID())", isDirectory: true)
        directories.append(directory)
        return Fixture(url: directory.appendingPathComponent("queue.json"))
    }

    @MainActor
    private struct Fixture {
        let url: URL
        let fileManager = AlbumJournalFileManager()
        let queue: BackupQueueStore

        init(url: URL) {
            self.url = url
            queue = BackupQueueStore(fileURL: url, fileManager: fileManager)
        }

        func reopen() -> BackupQueueStore { BackupQueueStore(fileURL: url, fileManager: fileManager) }
    }
}

private final class AlbumJournalFileManager: FileManager, @unchecked Sendable {
    var failWrites = false
    var failOnAttempt: Int?
    private(set) var writeAttempts = 0

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        writeAttempts += 1
        if failWrites || writeAttempts == failOnAttempt { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
